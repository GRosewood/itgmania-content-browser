package preview

// Tests for the simfile note parser in chart.go.
//
// Everything here is table-driven and self-contained except the last test,
// which runs the parser over whatever simfiles happen to be installed on the
// machine and checks invariants rather than values.

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// How an author declares a dance chart in each format, used by the test over
// the installed songs to check that no chart went missing.
var (
	sscStyleTag = regexp.MustCompile(`(?m)^#STEPSTYPE:\s*dance-(single|double)\s*;`)
	smStyleLine = regexp.MustCompile(`(?m)^\s*dance-(single|double)\s*:\s*$`)
)

const eps = 1e-9

func nearly(a, b float64) bool { return math.Abs(a-b) < eps }

// ------------------------------------------------------------------- timing

func TestChartReadTimingOK(t *testing.T) {
	for _, tc := range []struct {
		name string
		text string
		want bool
	}{
		{"one bpm", "#OFFSET:0.000;\n#BPMS:0.000=120.000;\n", true},
		{"several bpms", "#BPMS:0.000=120.000,16.000=180.000;\n", true},
		{"no bpms tag at all", "#OFFSET:0.010;\n#TITLE:x;\n", false},
		{"empty bpms tag", "#OFFSET:0.010;\n#BPMS:;\n", false},
		{"unparseable bpms", "#BPMS:nonsense;\n", false},
		{"empty file", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := readTiming(tc.text).ok(); got != tc.want {
				t.Errorf("readTiming(%q).ok() = %v, want %v", tc.text, got, tc.want)
			}
		})
	}

	// A file with no tempo must not smuggle its offset through either: the
	// zero timing is what says "this cannot be placed in time at all".
	if got := readTiming("#OFFSET:1.500;\n"); got.offset != 0 || len(got.bpms) != 0 {
		t.Errorf("timing without BPMS = %+v, want the zero value", got)
	}
}

func TestChartTimingAt(t *testing.T) {
	const (
		plain    = "#OFFSET:0.000;\n#BPMS:0.000=120.000;\n"
		lead     = "#OFFSET:0.500;\n#BPMS:0.000=120.000;\n" // audio leads the chart
		lag      = "#OFFSET:-0.500;\n#BPMS:0.000=120.000;\n"
		twoBPMs  = "#OFFSET:0.000;\n#BPMS:0.000=120.000,\n4.000=240.000;\n"
		threeBPM = "#OFFSET:0.000;\n#BPMS:0.000=60.000,2.000=120.000,6.000=240.000;\n"
		stopped  = "#OFFSET:0.000;\n#BPMS:0.000=120.000;\n#STOPS:4.000=1.500;\n"
		stops2   = "#OFFSET:0.000;\n#BPMS:0.000=120.000;\n#STOPS:2.000=1.000,\n4.000=0.500;\n"
		offStop  = "#OFFSET:0.100;\n#BPMS:0.000=120.000;\n#STOPS:2.000=1.000;\n"
	)
	for _, tc := range []struct {
		name string
		text string
		beat float64
		want float64
	}{
		// 120bpm: a beat is half a second.
		{"single bpm, beat 0", plain, 0, 0},
		{"single bpm, beat 1", plain, 1, 0.5},
		{"single bpm, beat 4", plain, 4, 2},
		{"single bpm, fractional beat", plain, 0.25, 0.125},

		// #OFFSET is how far the audio leads the chart, so beat 0 is at -OFFSET.
		{"positive offset moves beat 0 earlier", lead, 0, -0.5},
		{"positive offset shifts every beat", lead, 4, 1.5},
		{"negative offset moves beat 0 later", lag, 0, 0.5},
		{"negative offset shifts every beat", lag, 4, 2.5},

		// 120bpm until beat 4, then 240bpm: quarter-second beats after that.
		{"two segments, inside the first", twoBPMs, 2, 1},
		{"two segments, on the boundary", twoBPMs, 4, 2},
		{"two segments, inside the second", twoBPMs, 8, 3},
		{"two segments, well past", twoBPMs, 12, 4},

		// 60bpm to beat 2 (2s), 120bpm to beat 6 (2s more), then 240bpm.
		{"three segments, first", threeBPM, 1, 1},
		{"three segments, second boundary", threeBPM, 2, 2},
		{"three segments, mid second", threeBPM, 4, 3},
		{"three segments, third boundary", threeBPM, 6, 4},
		{"three segments, third", threeBPM, 10, 5},

		// A stop counts once the chart is past the beat it sits on.
		{"stop not yet reached", stopped, 2, 1},
		{"stop on its own beat does not count", stopped, 4, 2},
		{"stop counted after its beat", stopped, 5, 4},
		{"stops accumulate", stops2, 5, 4},
		{"only the stops passed count", stops2, 3, 2.5},
		{"offset and stop together", offStop, 4, 2.9},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tm := readTiming(tc.text)
			if !tm.ok() {
				t.Fatalf("readTiming(%q) is not ok", tc.text)
			}
			if got := tm.at(tc.beat); !nearly(got, tc.want) {
				t.Errorf("at(%v) = %v, want %v", tc.beat, got, tc.want)
			}
		})
	}
}

func TestChartTimingSegmentsAreSorted(t *testing.T) {
	// Simfiles in the wild are not always written in beat order.
	shuffled := readTiming("#OFFSET:0.000;\n#BPMS:4.000=240.000,0.000=120.000;\n")
	inOrder := readTiming("#OFFSET:0.000;\n#BPMS:0.000=120.000,4.000=240.000;\n")
	for _, beat := range []float64{0, 2, 4, 8, 12} {
		if got, want := shuffled.at(beat), inOrder.at(beat); !nearly(got, want) {
			t.Errorf("at(%v) with shuffled BPMS = %v, want %v", beat, got, want)
		}
	}
}

// --------------------------------------------------------------- quantize

func TestChartQuantize(t *testing.T) {
	// 0=4th 1=8th 2=12th 3=16th 4=24th 5=32nd 6=48th 7=other
	for _, tc := range []struct {
		rows, index, want int
	}{
		{0, 0, 7},  // no rows at all
		{-4, 0, 7}, // nonsense row count

		{4, 0, 0}, {4, 1, 0}, {4, 2, 0}, {4, 3, 0},

		{8, 0, 0}, {8, 1, 1}, {8, 2, 0}, {8, 3, 1}, {8, 6, 0},

		{12, 0, 0}, {12, 1, 2}, {12, 2, 2}, {12, 3, 0}, {12, 4, 2}, {12, 6, 0},

		{16, 0, 0}, {16, 1, 3}, {16, 2, 1}, {16, 3, 3}, {16, 4, 0}, {16, 6, 1},

		{24, 0, 0}, {24, 1, 4}, {24, 2, 2}, {24, 3, 1}, {24, 4, 2}, {24, 6, 0},

		{32, 0, 0}, {32, 1, 5}, {32, 2, 3}, {32, 4, 1}, {32, 8, 0},

		{48, 0, 0}, {48, 1, 6}, {48, 2, 4}, {48, 3, 3}, {48, 4, 2},
		{48, 6, 1}, {48, 12, 0},

		// 64ths and 192nds have no colour of their own; the rows inside such a
		// measure that land on a coarser division still do.
		{64, 1, 7}, {64, 2, 5}, {64, 3, 7}, {64, 4, 3},
		{192, 1, 7}, {192, 2, 7}, {192, 4, 6},

		// row counts that are not a measure division at all
		{5, 1, 7}, {7, 1, 7},
	} {
		t.Run(fmt.Sprintf("%d_of_%d", tc.index, tc.rows), func(t *testing.T) {
			if got := quantize(tc.index, tc.rows); got != tc.want {
				t.Errorf("quantize(%d, %d) = %d, want %d", tc.index, tc.rows, got, tc.want)
			}
		})
	}
}

func TestChartQuantizeFirstRowIsAlwaysAQuarter(t *testing.T) {
	for _, rows := range []int{4, 8, 12, 16, 24, 32, 48, 64, 192} {
		if got := quantize(0, rows); got != 0 {
			t.Errorf("quantize(0, %d) = %d, want 0", rows, got)
		}
	}
}

// ----------------------------------------------------------------- charts

// A .sm chart: five colon-separated fields after #NOTES:, then the measures.
// The description field is deliberately a number that is not the meter, so a
// test can tell field 1 from field 3.
func smChart(style, diff, meter, body string) string {
	return "//--------------- " + style + " ----------------\n" +
		"#NOTES:\n" +
		"     " + style + ":\n" +
		"     11:\n" +
		"     " + diff + ":\n" +
		"     " + meter + ":\n" +
		"     0.111,0.222,0.333,0,0:\n" +
		body + "\n;\n"
}

// A .ssc chart: the same information in its own tags, then a #NOTES: that
// holds nothing but measures. #CHARTNAME and #DESCRIPTION carry numbers so a
// test can tell them from #METER.
func sscChart(style, diff, meter, body string) string {
	return "//--------------- " + style + " ----------------\n" +
		"#NOTEDATA:;\n" +
		"#CHARTNAME:77;\n" +
		"#STEPSTYPE:" + style + ";\n" +
		"#DESCRIPTION:11;\n" +
		"#DIFFICULTY:" + diff + ";\n" +
		"#METER:" + meter + ";\n" +
		"#RADARVALUES:0.111,0.222,0.333,0,0;\n" +
		"#NOTES:\n" + body + "\n;\n"
}

const simHeader = "#TITLE:Test Song;\n#MUSIC:test.ogg;\n#OFFSET:0.000;\n" +
	"#SAMPLESTART:12.000;\n#SAMPLELENGTH:20.000;\n#BPMS:0.000=120.000;\n#STOPS:;\n"

const fourTaps = "1000\n0100\n0010\n0001"

func TestChartsParsesSM(t *testing.T) {
	text := simHeader +
		smChart("dance-single", "Medium", "7", fourTaps) +
		smChart("pump-single", "Hard", "12", "00000\n00000\n00000\n00000") +
		smChart("dance-double", "Challenge", "13", "10000000\n00000001\n00000000\n00010000") +
		smChart("dance-solo", "Hard", "9", "000000\n000000\n000000\n000000")

	got := charts(text)
	if len(got) != 2 {
		t.Fatalf("charts() found %d charts, want 2 (only the dance-single and dance-double): %+v", len(got), got)
	}
	want := []chart{
		{style: "dance-single", diff: "Medium", meter: 7},
		{style: "dance-double", diff: "Challenge", meter: 13},
	}
	for i, w := range want {
		if got[i].style != w.style || got[i].diff != w.diff || got[i].meter != w.meter {
			t.Errorf("chart %d = {%q %q %d}, want {%q %q %d}",
				i, got[i].style, got[i].diff, got[i].meter, w.style, w.diff, w.meter)
		}
	}
	if !strings.Contains(got[0].notes, "0100") {
		t.Errorf("chart 0 notes = %q, want the measure data", got[0].notes)
	}
	// The radar field must not have leaked into the note data.
	if strings.Contains(got[0].notes, "0.111") {
		t.Errorf("chart 0 notes = %q, want the radar values left behind", got[0].notes)
	}
	// The note data stops at the semicolon, not at the next chart.
	if strings.Contains(got[0].notes, "dance-double") {
		t.Errorf("chart 0 notes ran into the next chart: %q", got[0].notes)
	}
}

func TestChartsParsesSSC(t *testing.T) {
	text := simHeader +
		sscChart("dance-single", "Challenge", "9", fourTaps) +
		sscChart("pump-double", "Hard", "12", "0000000000\n0000000000\n0000000000\n0000000000") +
		sscChart("dance-double", "Hard", "8", "10000000\n00000001\n00000000\n00010000")

	got := charts(text)
	if len(got) != 2 {
		t.Fatalf("charts() found %d charts, want 2 (the pump chart should be skipped): %+v", len(got), got)
	}
	want := []chart{
		{style: "dance-single", diff: "Challenge", meter: 9},
		{style: "dance-double", diff: "Hard", meter: 8},
	}
	for i, w := range want {
		if got[i].style != w.style || got[i].diff != w.diff || got[i].meter != w.meter {
			t.Errorf("chart %d = {%q %q %d}, want {%q %q %d}",
				i, got[i].style, got[i].diff, got[i].meter, w.style, w.diff, w.meter)
		}
	}
	if !strings.Contains(got[0].notes, "0100") {
		t.Errorf("chart 0 notes = %q, want the measure data", got[0].notes)
	}
	// Each block's note data has to end at its own semicolon.
	if strings.Contains(got[0].notes, "STEPSTYPE") || strings.Contains(got[0].notes, "10000000") {
		t.Errorf("chart 0 notes ran into the next block: %q", got[0].notes)
	}
}

// A .sm chart header is read by counting colons, so a colon inside the
// description field shifts every field after it: the difficulty becomes the
// tail of the description, the meter stops being a number, and the radar
// values fall into the note data as five empty measures, which puts every note
// twenty beats late. StepMania writes such a description escaped (\:), which
// this would not help with either. No installed simfile does it, so this is a
// case waiting to happen rather than one that has.
func TestChartsParsesSMDescriptionWithAColon(t *testing.T) {
	text := simHeader + "#NOTES:\n     dance-single:\n     Blame\\: Bob:\n     Hard:\n     9:\n" +
		"     0,0,0,0,0:\n" + fourTaps + "\n;\n"

	got := charts(text)
	if len(got) != 1 {
		t.Fatalf("got %d charts, want 1", len(got))
	}
	if got[0].diff != "Hard" || got[0].meter != 9 {
		t.Errorf("chart = {%q %d}, want {\"Hard\" 9}", got[0].diff, got[0].meter)
	}
	if strings.Contains(got[0].notes, "0,0,0,0,0") {
		t.Errorf("the radar values landed in the note data: %q", got[0].notes)
	}
}

func TestChartsFindsNothingToShow(t *testing.T) {
	for _, tc := range []struct{ name, text string }{
		{"empty", ""},
		{"header only", simHeader},
		{"no dance charts (sm)", simHeader + smChart("pump-single", "Hard", "12", "00000")},
		{"no dance charts (ssc)", simHeader + sscChart("pump-single", "Hard", "12", "00000")},
		{"truncated sm chart", simHeader + "#NOTES:\n     dance-single:\n     :\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := charts(tc.text); len(got) != 0 {
				t.Errorf("charts() = %+v, want none", got)
			}
		})
	}
}

func TestChartsHandlesCRLF(t *testing.T) {
	text := strings.ReplaceAll(simHeader+sscChart("dance-single", "Hard", "9", fourTaps), "\n", "\r\n")
	got := charts(text)
	if len(got) != 1 {
		t.Fatalf("charts() found %d charts in a CRLF file, want 1", len(got))
	}
	if lanesFor(got[0].style) != 4 {
		t.Errorf("style = %q, which is not a four-panel style", got[0].style)
	}
	var count int
	measureNotes(got[0].notes, 4, func(float64, int, int) { count++ })
	if count != 4 {
		t.Errorf("counted %d notes in a CRLF file, want 4", count)
	}
}

// ----------------------------------------------------------- measureNotes

type emitted struct {
	beat  float64
	cols  int
	quant int
}

func collectNotes(data string, lanes int) []emitted {
	var out []emitted
	measureNotes(data, lanes, func(beat float64, cols, quant int) {
		out = append(out, emitted{beat, cols, quant})
	})
	return out
}

func TestChartMeasureNotes(t *testing.T) {
	for _, tc := range []struct {
		name  string
		data  string
		lanes int
		want  []emitted
	}{
		{
			name: "four rows are one beat apart", data: fourTaps, lanes: 4,
			want: []emitted{{0, 1, 0}, {1, 2, 0}, {2, 4, 0}, {3, 8, 0}},
		},
		{
			name:  "eight rows are half a beat apart",
			data:  "1000\n0100\n0010\n0001\n1000\n0100\n0010\n0001",
			lanes: 4,
			want: []emitted{
				{0, 1, 0}, {0.5, 2, 1}, {1, 4, 0}, {1.5, 8, 1},
				{2, 1, 0}, {2.5, 2, 1}, {3, 4, 0}, {3.5, 8, 1},
			},
		},
		{
			name:  "sixteen rows are a quarter beat apart",
			data:  "1000\n0100\n0010\n0001\n" + strings.Repeat("0000\n", 11) + "0000",
			lanes: 4,
			want:  []emitted{{0, 1, 0}, {0.25, 2, 3}, {0.5, 4, 1}, {0.75, 8, 3}},
		},
		{
			name:  "twelve rows are triplets",
			data:  "1000\n0100\n0010\n" + strings.Repeat("0000\n", 8) + "0000",
			lanes: 4,
			want:  []emitted{{0, 1, 0}, {4.0 / 12, 2, 2}, {8.0 / 12, 4, 2}},
		},
		{
			name:  "later measures start four beats on",
			data:  fourTaps + ",\n" + fourTaps + ",\n" + fourTaps,
			lanes: 4,
			want: []emitted{
				{0, 1, 0}, {1, 2, 0}, {2, 4, 0}, {3, 8, 0},
				{4, 1, 0}, {5, 2, 0}, {6, 4, 0}, {7, 8, 0},
				{8, 1, 0}, {9, 2, 0}, {10, 4, 0}, {11, 8, 0},
			},
		},
		{
			name:  "an empty measure still takes up four beats",
			data:  "\n\n,\n" + fourTaps,
			lanes: 4,
			want:  []emitted{{4, 1, 0}, {5, 2, 0}, {6, 4, 0}, {7, 8, 0}},
		},
		{
			name:  "holds and rolls arrive, mines and lifts do not",
			data:  "2000\n4000\n3000\n0000",
			lanes: 4,
			want:  []emitted{{0, 1, 0}, {1, 1, 0}},
		},
		{
			name:  "mines and lifts and fakes are not notes",
			data:  "M000\nL000\nF000\n0000",
			lanes: 4,
			want:  nil,
		},
		{
			name:  "hold ends alone are not notes",
			data:  "3000\n0000\n0000\n0000",
			lanes: 4,
			want:  nil,
		},
		{
			name:  "jumps and hands are one row",
			data:  "1100\n1011\n1111\n0000",
			lanes: 4,
			want:  []emitted{{0, 0b0011, 0}, {1, 0b1101, 0}, {2, 0b1111, 0}},
		},
		{
			name:  "comments and blank lines do not count as rows",
			data:  "// this measure is 4 rows\n1000\n\n0100\n  \n// halfway\n0010\n0001\n",
			lanes: 4,
			want:  []emitted{{0, 1, 0}, {1, 2, 0}, {2, 4, 0}, {3, 8, 0}},
		},
		{
			name:  "doubles reads eight columns",
			data:  "10000001\n00011000\n00000000\n00000010",
			lanes: 8,
			want:  []emitted{{0, 0b10000001, 0}, {1, 0b00011000, 0}, {3, 0b01000000, 0}},
		},
		{
			name:  "a doubles row read as singles keeps the left pad",
			data:  "10000001\n00011000\n00000000\n00000010",
			lanes: 4,
			want:  []emitted{{0, 0b0001, 0}, {1, 0b1000, 0}},
		},
		{
			name:  "a short row does not run off the end",
			data:  "10\n0\n\n1",
			lanes: 4,
			want:  []emitted{{0, 1, 0}, {8.0 / 3, 1, 2}},
		},
		{
			name:  "nothing at all",
			data:  "",
			lanes: 4,
			want:  nil,
		},
		{
			name:  "only rests",
			data:  "0000\n0000\n0000\n0000",
			lanes: 4,
			want:  nil,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := collectNotes(tc.data, tc.lanes)
			if len(got) != len(tc.want) {
				t.Fatalf("got %d notes %v, want %d %v", len(got), got, len(tc.want), tc.want)
			}
			for i := range got {
				if !nearly(got[i].beat, tc.want[i].beat) || got[i].cols != tc.want[i].cols || got[i].quant != tc.want[i].quant {
					t.Errorf("note %d = %+v, want %+v", i, got[i], tc.want[i])
				}
			}
		})
	}
}

// ------------------------------------------------------- chartsForWindow

// beats builds a body with a tap on the left arrow on every beat, four rows to
// the measure, so beat b is note b.
func beats(n int) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		if i > 0 && i%4 == 0 {
			b.WriteString(",\n")
		}
		b.WriteString("1000\n")
	}
	return b.String()
}

func TestChartsForWindowClipsAndRebasesTimes(t *testing.T) {
	// 120bpm, no offset: beat b lands at b/2 seconds.
	text := simHeader + smChart("dance-single", "Hard", "9", beats(32))

	got := chartsForWindow(text, 2, 2) // seconds 2..4, which is beats 4..8
	if len(got) != 1 {
		t.Fatalf("got %d charts, want 1", len(got))
	}
	want := []float64{0, 0.5, 1, 1.5, 2}
	if len(got[0].Notes) != len(want) {
		t.Fatalf("got %d notes %+v, want %d", len(got[0].Notes), got[0].Notes, len(want))
	}
	for i, w := range want {
		if !nearly(got[0].Notes[i].T, w) {
			t.Errorf("note %d at %v, want %v (times are relative to the window)", i, got[0].Notes[i].T, w)
		}
		if got[0].Notes[i].Cols != 1 {
			t.Errorf("note %d cols = %d, want 1", i, got[0].Notes[i].Cols)
		}
	}
	if got[0].Lanes != 4 || got[0].Meter != 9 || got[0].Diff != "Hard" || got[0].Style != "dance-single" {
		t.Errorf("chart = %+v, want a 4-lane dance-single Hard 9", got[0])
	}
}

func TestChartsForWindowSilentWindowStillComesBack(t *testing.T) {
	// Notes only in the first two measures, i.e. the first four seconds.
	text := simHeader + smChart("dance-single", "Hard", "9", beats(8))

	got := chartsForWindow(text, 30, 20)
	if len(got) != 1 {
		t.Fatalf("got %d charts, want the chart back with nothing in it", len(got))
	}
	if len(got[0].Notes) != 0 {
		t.Errorf("got %d notes in a silent window, want none", len(got[0].Notes))
	}
	if got[0].Lanes != 4 || got[0].Meter != 9 {
		t.Errorf("chart = %+v, want the difficulty still described", got[0])
	}
}

func TestChartsForWindowOrdersEasiestFirstSinglesBeforeDoubles(t *testing.T) {
	text := simHeader +
		smChart("dance-double", "Challenge", "12", beats(8)) +
		smChart("dance-single", "Challenge", "10", beats(8)) +
		smChart("dance-double", "Hard", "8", beats(8)) +
		smChart("dance-single", "Beginner", "2", beats(8)) +
		smChart("dance-single", "Medium", "6", beats(8))

	got := chartsForWindow(text, 0, 20)
	var order []string
	for _, c := range got {
		order = append(order, fmt.Sprintf("%s/%d", c.Style, c.Meter))
	}
	want := []string{
		"dance-single/2", "dance-single/6", "dance-single/10",
		"dance-double/8", "dance-double/12",
	}
	if len(order) != len(want) {
		t.Fatalf("got %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("got %v, want %v", order, want)
		}
	}
	for _, c := range got {
		switch c.Style {
		case "dance-single":
			if c.Lanes != 4 {
				t.Errorf("%s has %d lanes, want 4", c.Style, c.Lanes)
			}
		case "dance-double":
			if c.Lanes != 8 {
				t.Errorf("%s has %d lanes, want 8", c.Style, c.Lanes)
			}
		}
	}
}

// Two charts of the same style can carry the same meter -- about one installed
// song in twenty does -- and the tiebreak decides which of them the browser
// shows first. It used to sort on the inverse of a display-preference map,
// which put Edit first and Challenge ahead of Hard; it sorts on difficulty
// order now, which is what "easiest first" has to mean.
func TestChartsForWindowOrdersTiedMetersByDifficulty(t *testing.T) {
	text := simHeader +
		smChart("dance-single", "Challenge", "9", beats(8)) +
		smChart("dance-single", "Beginner", "9", beats(8)) +
		smChart("dance-single", "Hard", "9", beats(8)) +
		smChart("dance-single", "Medium", "9", beats(8)) +
		smChart("dance-single", "Easy", "9", beats(8))

	var order []string
	for _, c := range chartsForWindow(text, 0, 20) {
		order = append(order, c.Diff)
	}
	want := "Beginner Easy Medium Hard Challenge"
	if got := strings.Join(order, " "); got != want {
		t.Errorf("tied on meter 9 the order is %q, want %q", got, want)
	}
}

func TestChartsForWindowDoublesUsesAllEightLanes(t *testing.T) {
	body := "10000000\n00000001\n00011000\n00000000"
	text := simHeader + sscChart("dance-double", "Challenge", "13", body)

	got := chartsForWindow(text, 0, 20)
	if len(got) != 1 {
		t.Fatalf("got %d charts, want 1", len(got))
	}
	if got[0].Lanes != 8 {
		t.Fatalf("lanes = %d, want 8", got[0].Lanes)
	}
	want := []int{0b00000001, 0b10000000, 0b00011000}
	if len(got[0].Notes) != len(want) {
		t.Fatalf("got %d notes, want %d", len(got[0].Notes), len(want))
	}
	for i, w := range want {
		if got[0].Notes[i].Cols != w {
			t.Errorf("note %d cols = %08b, want %08b", i, got[0].Notes[i].Cols, w)
		}
	}
}

func TestChartsForWindowNothingToShow(t *testing.T) {
	withCharts := simHeader + smChart("dance-single", "Hard", "9", beats(8))
	for _, tc := range []struct {
		name   string
		text   string
		from   float64
		length float64
	}{
		{"no length", withCharts, 0, 0},
		{"negative length", withCharts, 0, -20},
		{"no tempo", "#TITLE:x;\n" + smChart("dance-single", "Hard", "9", beats(8)), 0, 20},
		{"no dance charts", simHeader + smChart("pump-single", "Hard", "9", "00000"), 0, 20},
		{"empty note data", simHeader + smChart("dance-single", "Hard", "9", "\n"), 0, 20},
		{"nothing at all", "", 0, 20},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := chartsForWindow(tc.text, tc.from, tc.length); len(got) != 0 {
				t.Errorf("chartsForWindow() = %+v, want nothing", got)
			}
		})
	}
}

func TestChartsForWindowKeepsQuantization(t *testing.T) {
	// One measure of sixteenths on the left arrow: 4th, 16th, 8th, 16th, ...
	body := strings.Repeat("1000\n", 16)
	text := simHeader + smChart("dance-single", "Hard", "9", body)

	got := chartsForWindow(text, 0, 20)
	if len(got) != 1 || len(got[0].Notes) != 16 {
		t.Fatalf("got %d charts with %d notes, want 1 with 16", len(got), len(got[0].Notes))
	}
	want := []int{0, 3, 1, 3, 0, 3, 1, 3, 0, 3, 1, 3, 0, 3, 1, 3}
	for i, w := range want {
		if got[0].Notes[i].Q != w {
			t.Errorf("note %d quant = %d, want %d", i, got[0].Notes[i].Q, w)
		}
	}
}

// ------------------------------------------------------------------- caps

// dense builds a body of `measures` measures with a tap on every one of `rows`
// rows, i.e. measures*rows notes.
func dense(measures, rows int) string {
	var b strings.Builder
	for m := 0; m < measures; m++ {
		if m > 0 {
			b.WriteString(",\n")
		}
		for r := 0; r < rows; r++ {
			b.WriteString("1000\n")
		}
	}
	return b.String()
}

func TestChartNoteCapPerChart(t *testing.T) {
	// 100 measures of 16ths is 1600 notes, and 200 seconds at 120bpm.
	text := simHeader + smChart("dance-single", "Hard", "9", dense(100, 16))

	got := chartsForWindow(text, 0, 1000)
	if len(got) != 1 {
		t.Fatalf("got %d charts, want 1", len(got))
	}
	if len(got[0].Notes) != maxNotes {
		t.Errorf("got %d notes, want the per-chart cap of %d", len(got[0].Notes), maxNotes)
	}
	// The cap keeps the front of the window, so what came back is still in order.
	for i := 1; i < len(got[0].Notes); i++ {
		if got[0].Notes[i].T < got[0].Notes[i-1].T {
			t.Fatalf("note %d at %v is before note %d at %v", i, got[0].Notes[i].T, i-1, got[0].Notes[i-1].T)
		}
	}
}

func TestChartNoteCapIsPerChartNotWholeFile(t *testing.T) {
	// Four charts that each fill the per-chart cap. There is deliberately no
	// cap across the file: one existed, and it left whichever charts sorted
	// last with an empty note list, which the screen cannot tell apart from a
	// window where the song genuinely does nothing.
	body := dense(100, 16)
	text := simHeader +
		smChart("dance-single", "Beginner", "1", body) +
		smChart("dance-single", "Easy", "2", body) +
		smChart("dance-single", "Medium", "3", body) +
		smChart("dance-single", "Hard", "4", body)

	got := chartsForWindow(text, 0, 1000)
	if len(got) != 4 {
		t.Fatalf("got %d charts, want 4", len(got))
	}
	for _, c := range got {
		if len(c.Notes) > maxNotes {
			t.Errorf("%s has %d notes, over the per-chart cap of %d", c.Diff, len(c.Notes), maxNotes)
		}
		if len(c.Notes) == 0 {
			t.Errorf("%s came back with no notes at all; every chart here has some", c.Diff)
		}
	}
}

// ------------------------------------------------- the simfiles on this box

// TestChartsAgainstInstalledSongs runs the parser over whatever is in the
// ITGmania song folder. Real files are the only place the awkward cases live
// -- split BPMs, keysounds, mine-only measures, files that are not UTF-8 --
// so this asserts invariants rather than values, and says nothing at all if
// there are no songs installed.
func TestChartsAgainstInstalledSongs(t *testing.T) {
	const songs = `C:\Games\ITGmania\Songs`

	if info, err := os.Stat(songs); err != nil || !info.IsDir() {
		t.Skipf("no song folder at %s", songs)
	}

	var files []string
	err := filepath.WalkDir(songs, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // an unreadable corner of the folder is not a test failure
		}
		if d.IsDir() {
			return nil
		}
		switch strings.ToLower(filepath.Ext(path)) {
		case ".sm", ".ssc":
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		t.Skipf("could not walk %s: %v", songs, err)
	}
	if len(files) == 0 {
		t.Skipf("no simfiles under %s", songs)
	}

	// Take an even sample across the whole folder rather than the first N, so
	// every pack gets a look in. PREVIEW_SONG_BUDGET=0 reads all of them.
	budget := 400
	if testing.Short() {
		budget = 40
	}
	if v, err := strconv.Atoi(os.Getenv("PREVIEW_SONG_BUDGET")); err == nil && v >= 0 {
		budget = v
	}
	if budget > 0 && len(files) > budget {
		stride := len(files) / budget
		sampled := make([]string, 0, budget+1)
		for i := 0; i < len(files); i += stride {
			sampled = append(sampled, files[i])
		}
		files = sampled
	}

	const window = 20.0
	parsed, withCharts, notes := 0, 0, 0

	for _, path := range files {
		raw, err := os.ReadFile(path)
		if err != nil || len(raw) > 8<<20 {
			continue
		}
		text := string(raw)
		parsed++

		from := 45.0
		if v, ok := tagFloat(text, "SAMPLESTART"); ok && v > 0 {
			from = v
		}
		got := chartsForWindow(text, from, window)

		// Every dance chart the file declares has to be found. This is the one
		// place the count can be checked against something outside the parser:
		// the style lines the author wrote.
		declared := smStyleLine.FindAllString(text, -1)
		if strings.EqualFold(filepath.Ext(path), ".ssc") {
			declared = sscStyleTag.FindAllString(text, -1)
		}
		found := charts(text)
		if len(declared) != len(found) {
			t.Errorf("%s: charts() found %d dance charts, the file declares %d", path, len(found), len(declared))
		}
		// ...and every one of them that has note data has to survive into the
		// window, empty or not. Template files with a declared but blank chart
		// are the one thing that drops out.
		playable := 0
		for _, c := range found {
			if strings.TrimSpace(c.notes) != "" {
				playable++
			}
		}
		if !readTiming(text).ok() {
			playable = 0
		}
		if len(got) != playable {
			t.Errorf("%s: the window has %d charts, want the %d with note data", path, len(got), playable)
		}

		if len(got) == 0 {
			continue
		}
		withCharts++

		for _, c := range got {
			where := fmt.Sprintf("%s [%s %s %d]", path, c.Style, c.Diff, c.Meter)

			if c.Lanes != 4 && c.Lanes != 8 {
				t.Errorf("%s: %d lanes, want 4 or 8", where, c.Lanes)
				continue
			}
			if len(c.Notes) > maxNotes {
				t.Errorf("%s: %d notes, over the per-chart cap of %d", where, len(c.Notes), maxNotes)
			}
			notes += len(c.Notes)

			prev := -1.0
			for i, n := range c.Notes {
				if n.T < prev-eps {
					t.Errorf("%s: note %d at %.6fs is before note %d at %.6fs", where, i, n.T, i-1, prev)
					break
				}
				prev = n.T
				if n.T < -eps || n.T > window+eps {
					t.Errorf("%s: note %d at %.6fs is outside the %.0fs window", where, i, n.T, window)
					break
				}
				if n.Q < 0 || n.Q > 7 {
					t.Errorf("%s: note %d has quantization %d, want 0..7", where, i, n.Q)
					break
				}
				if n.Cols == 0 {
					t.Errorf("%s: note %d has no columns set", where, i)
					break
				}
				if n.Cols >= 1<<uint(c.Lanes) {
					t.Errorf("%s: note %d columns %b spill past %d lanes", where, i, n.Cols, c.Lanes)
					break
				}
			}
		}
	}

	t.Logf("read %d simfiles, %d had a dance chart, %d notes in the sample windows", parsed, withCharts, notes)
	if withCharts < 10 {
		t.Errorf("only %d of %d simfiles produced a chart, which is too few to have tested anything", withCharts, parsed)
	}
}
