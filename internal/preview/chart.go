package preview

// Note data for the sample window, read out of the simfile the audio came from.
//
// The browser plays a twenty-second sample; this is what the chart is doing
// during those twenty seconds, so the screen can show it being played rather
// than just describe it. It costs nothing extra to produce: the simfile has
// already been read out of the archive for the sample window and the tempo, so
// this is parsing bytes that are in hand.
//
// It is a preview, not a player. Warps and negative BPMs are not modelled, and
// a .ssc chart carrying its own timing is read against the song's -- both are
// rare, and being a few milliseconds out on a picture that exists to look like
// the song is not worth the machinery.

import (
	"math"
	"sort"
	"strconv"
	"strings"
)

// Note is one moment in a chart: when it lands, and where.
type Note struct {
	T    float64 `json:"t"` // seconds from the start of the sample window
	Cols int     `json:"c"` // one bit per column, lowest bit leftmost
	Q    int     `json:"q"` // quantization: 0=4th 1=8th 2=12th 3=16th 4=24th 5=32nd 6=48th 7=other
}

// quantize says what kind of note a row is, from where it falls inside its
// measure. A measure is 192 rows however many lines were written for it, so
// the divisor a row lands on is what names it -- and that is what decides an
// arrow's colour on every StepMania screen there has ever been.
func quantize(index, rows int) int {
	if rows <= 0 {
		return 7
	}
	row := index * 192 / rows
	for kind, every := range []int{48, 24, 16, 12, 8, 6, 4} {
		if row%every == 0 {
			return kind
		}
	}
	return 7
}

// how much of a chart is worth sending: a twenty-second window of a dense
// stamina chart is a few hundred notes, and this is well clear of that
const maxNotes = 900

type bpmSeg struct{ beat, value float64 }

// parseSegs reads a "beat=value,beat=value" tag into segments, in beat order.
func parseSegs(text, tag string) []bpmSeg {
	raw, ok := tagString(text, tag)
	if !ok {
		return nil
	}
	var out []bpmSeg
	for _, pair := range strings.Split(raw, ",") {
		eq := strings.IndexByte(pair, '=')
		if eq < 0 {
			continue
		}
		beat, err1 := strconv.ParseFloat(strings.TrimSpace(pair[:eq]), 64)
		value, err2 := strconv.ParseFloat(strings.TrimSpace(pair[eq+1:]), 64)
		if err1 != nil || err2 != nil || !finite(beat) || !finite(value) {
			continue
		}
		out = append(out, bpmSeg{beat: beat, value: value})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].beat < out[j].beat })
	return out
}

// timing turns a beat into a time in the audio file.
type timing struct {
	offset float64
	bpms   []bpmSeg
	stops  []bpmSeg
}

func readTiming(text string) timing {
	t := timing{bpms: parseSegs(text, "BPMS"), stops: parseSegs(text, "STOPS")}
	if v, ok := tagFloat(text, "OFFSET"); ok && finite(v) {
		t.offset = v
	}
	// Nothing usable is nothing at all: a file with no tempo comes back as the
	// zero value rather than as an offset with no clock to apply it to.
	if !t.ok() {
		return timing{}
	}
	return t
}

// finite rejects what a text field can say that a number cannot mean. "nan"
// and "inf" both parse as float64s, sail past every "is it positive" test, and
// end up in a JSON response that will not encode -- which reaches the caller
// as an empty 200 with nothing to explain it.
func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

// A chart can only be placed in time if something in it moves. A file whose
// every BPM is zero or negative has no tempo, whatever it wrote in the tag,
// and would otherwise stack the entire chart on one instant.
func (t timing) ok() bool {
	for _, seg := range t.bpms {
		if seg.value > 0 && finite(seg.value) && finite(seg.beat) {
			return true
		}
	}
	return false
}

// at returns the moment in the audio file that a beat lands on. #OFFSET is how
// far the audio leads the chart, so beat zero sits at -OFFSET.
func (t timing) at(beat float64) float64 {
	seconds := -t.offset
	cur, rate := 0.0, t.bpms[0].value
	for i := 1; i < len(t.bpms) && t.bpms[i].beat < beat; i++ {
		if rate > 0 {
			seconds += (t.bpms[i].beat - cur) * 60 / rate
		}
		cur, rate = t.bpms[i].beat, t.bpms[i].value
	}
	if rate > 0 {
		seconds += (beat - cur) * 60 / rate
	}
	for _, s := range t.stops {
		// A negative stop is a warp. StepMania plays them; a preview cannot,
		// because it would hand the browser notes that arrive out of order and
		// the window walks them forward only. Skipping one costs a few frames
		// of drift on a file that uses them, which is the smaller wrong.
		if s.beat < beat && s.value > 0 {
			seconds += s.value
		}
	}
	return seconds
}

// chart is one playable difficulty out of a simfile.
type chart struct {
	style string // dance-single, dance-double, ...
	diff  string // Beginner | Easy | Medium | Hard | Challenge | Edit
	meter int    // the number on the wheel
	notes string // the measure data, commas and all
}

// ChartData is one difficulty of the previewed song: what it is, and what it
// does during the sample window. All of them go back together, so the browser
// can let somebody look at another difficulty without asking again -- the
// simfile has been read either way, and the notes for twenty seconds of one
// chart are a few kilobytes.
type ChartData struct {
	Style string `json:"style"`
	Diff  string `json:"diff"`
	Meter int    `json:"meter"`
	Lanes int    `json:"lanes"`
	Notes []Note `json:"notes,omitempty"`
}

// There is deliberately no cap across all the charts together. One existed,
// and it meant the difficulties that happened to be sorted last came back
// empty -- which is indistinguishable from a window that is genuinely silent,
// so the screen would have said "this chart does nothing here" about a wall of
// arrows. The per-chart cap is enough: twenty seconds cannot hold 900 notes.

// The order the wheel puts them in, easiest first. This is a difficulty
// order, not a preference: it decides how the charts are sorted, so Hard has
// to come before Challenge and Edit has to come last.
var difficultyOrder = map[string]int{
	"beginner": 0, "easy": 1, "medium": 2, "hard": 3, "challenge": 4, "edit": 5,
}

func rankOf(diff string) int {
	if r, ok := difficultyOrder[strings.ToLower(strings.TrimSpace(diff))]; ok {
		return r
	}
	return 6
}

// lanesFor is how many columns a style plays on. Everything else is left out:
// the window draws four or eight arrows and nothing else.
func lanesFor(style string) int {
	switch strings.ToLower(strings.TrimSpace(style)) {
	case "dance-single":
		return 4
	case "dance-double":
		return 8
	}
	return 0
}

// stripComments removes // to end-of-line, the way the engine's own MsdFile
// reader does, and it has to happen before anything is split.
//
// A comment can contain a comma or a semicolon, and both of those are
// structure here: a ';' ends a #NOTES block and a ',' ends a measure. Left in,
// a note to a fellow charter -- "// bpm change here, watch out" -- silently
// shifts every measure after it two seconds late, or truncates the chart
// entirely. Nothing this reads (#BPMS, #STOPS, #OFFSET, #STEPSTYPE,
// #DIFFICULTY, #METER, the note rows) can legitimately contain "//".
func stripComments(text string) string {
	if !strings.Contains(text, "//") {
		return text
	}
	var out strings.Builder
	out.Grow(len(text))
	for _, line := range strings.SplitAfter(text, "\n") {
		if at := strings.Index(line, "//"); at >= 0 {
			// keep the newline the comment was sitting on
			tail := ""
			if strings.HasSuffix(line, "\n") {
				tail = "\n"
			}
			out.WriteString(line[:at])
			out.WriteString(tail)
			continue
		}
		out.WriteString(line)
	}
	return out.String()
}

// charts finds every dance chart in a simfile, in either format.
//
// .sm keeps five colon-separated header fields after #NOTES: and then the
// measures; .ssc splits the same information into its own tags ahead of a
// #NOTES: that holds only measures. Both end at the first semicolon after the
// data, which is why neither can be found by splitting on ';' first.
func charts(text string) []chart {
	var out []chart

	// ---- .ssc: a #NOTEDATA: block per chart -------------------------------
	if blocks := strings.Split(text, "#NOTEDATA:"); len(blocks) > 1 {
		for _, block := range blocks[1:] {
			style, _ := tagString(block, "STEPSTYPE")
			diff, _ := tagString(block, "DIFFICULTY")
			at := strings.Index(block, "#NOTES:")
			if at < 0 {
				at = strings.Index(block, "#NOTES2:")
			}
			if at < 0 || lanesFor(style) == 0 {
				continue
			}
			body := block[at:]
			body = body[strings.IndexByte(body, ':')+1:]
			if end := strings.IndexByte(body, ';'); end >= 0 {
				body = body[:end]
			}
			meter := 0
			if raw, ok := tagString(block, "METER"); ok {
				if v, err := strconv.Atoi(strings.TrimSpace(raw)); err == nil {
					meter = v
				}
			}
			out = append(out, chart{style: style, diff: diff, meter: meter, notes: body})
		}
		if len(out) > 0 {
			return out
		}
	}

	// ---- .sm: #NOTES: then five fields then the measures ------------------
	rest := text
	for {
		at := strings.Index(rest, "#NOTES:")
		if at < 0 {
			break
		}
		rest = rest[at+len("#NOTES:"):]
		// A file truncated mid-chart has no closing ';'. Taking what is there
		// beats dropping it: the window is twenty seconds near the start, and
		// that much of the chart is usually present.
		end := strings.IndexByte(rest, ';')
		var block string
		if end < 0 {
			block, rest = rest, ""
		} else {
			block, rest = rest[:end], rest[end:]
		}

		// Counted from the END, not the start.
		//
		// The five header fields are type, description, difficulty, meter,
		// radar -- and the description is free text somebody typed. One colon
		// in it ("K. Ito: Remix") shifts a SplitN(_, ":", 6) by a field: the
		// difficulty becomes the second half of the name, the meter becomes
		// zero, and the radar values get read as note rows, inventing arrows
		// out of "0.9,1.8,0.7". Only the description can carry extra colons,
		// so counting back from the note data is right whatever it says.
		fields := strings.Split(block, ":")
		if len(fields) < 6 {
			continue
		}
		last := len(fields) - 1
		style := strings.TrimSpace(fields[0])
		if lanesFor(style) == 0 {
			continue
		}
		meter, _ := strconv.Atoi(strings.TrimSpace(fields[last-2]))
		out = append(out, chart{
			style: style,
			diff:  strings.TrimSpace(fields[last-3]),
			meter: meter,
			notes: fields[last],
		})
	}
	return out
}

// measureNotes walks the measure data and calls emit for every row that has
// something to step on. Taps, hold heads and roll heads all count; mines and
// lifts do not, because neither is a thing arriving at the receptor.
func measureNotes(data string, lanes int, emit func(beat float64, cols, quant int)) {
	for measure, block := range strings.Split(data, ",") {
		rows := make([]string, 0, 16)
		for _, line := range strings.Split(block, "\n") {
			line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
			if line == "" || strings.HasPrefix(line, "//") {
				continue
			}
			rows = append(rows, line)
		}
		if len(rows) == 0 {
			continue
		}
		for index, row := range rows {
			cols := 0
			for lane := 0; lane < lanes && lane < len(row); lane++ {
				switch row[lane] {
				case '1', '2', '4':
					cols |= 1 << uint(lane)
				}
			}
			if cols == 0 {
				continue
			}
			beat := float64(measure)*4 + float64(index)*4/float64(len(rows))
			emit(beat, cols, quantize(index, len(rows)))
		}
	}
}

// chartsForWindow returns every dance chart in the simfile with what it does
// during the sample window, timed from the start of that window. It returns
// nothing rather than something wrong: a simfile with no tempo, or no dance
// chart at all, simply has nothing to show.
//
// A chart whose window landed somewhere silent -- a lead-in, or a break --
// still comes back, with no notes in it. That is what the song is doing there,
// and the screen can draw the receptors standing empty and say so.
func chartsForWindow(text string, from, length float64) []ChartData {
	if length <= 0 || !finite(from) || !finite(length) {
		return nil
	}
	text = stripComments(text)
	timing := readTiming(text)
	if !timing.ok() {
		return nil
	}

	until := from + length
	var out []ChartData
	for _, c := range charts(text) {
		lanes := lanesFor(c.style)
		if lanes == 0 || strings.TrimSpace(c.notes) == "" {
			continue
		}
		var notes []Note
		measureNotes(c.notes, lanes, func(beat float64, cols, quant int) {
			if len(notes) >= maxNotes {
				return
			}
			at := timing.at(beat)
			if at < from || at > until {
				return
			}
			notes = append(notes, Note{T: at - from, Cols: cols, Q: quant})
		})
		out = append(out, ChartData{
			Style: c.style, Diff: c.diff, Meter: c.meter,
			Lanes: lanes, Notes: notes,
		})
	}

	// easiest first, singles before doubles: the order somebody would read
	// them in on the wheel
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Lanes != out[j].Lanes {
			return out[i].Lanes < out[j].Lanes
		}
		if out[i].Meter != out[j].Meter {
			return out[i].Meter < out[j].Meter
		}
		return rankOf(out[i].Diff) < rankOf(out[j].Diff)
	})
	return out
}
