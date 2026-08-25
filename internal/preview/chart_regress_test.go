package preview

// Regressions for defects an adversarial review of this parser turned up and
// then demonstrated. Each one is the smallest input that reproduced it.

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
)

const regressHeader = "#TITLE:Test;\n#OFFSET:0.000;\n#BPMS:0.000=120.000;\n"

// four measures, one note per measure, in a different column each time
const regressBody = "1000\n0000\n0000\n0000\n,\n0100\n0000\n0000\n0000\n,\n0010\n0000\n0000\n0000\n"

func times(notes []Note) []float64 {
	out := make([]float64, 0, len(notes))
	for _, n := range notes {
		out = append(out, n.T)
	}
	return out
}

// A description is free text somebody typed, and one colon in it used to shift
// every field along: the difficulty became half the name, the meter became
// zero, and the radar values ("0.9,1.8,0.7") were read as note rows, inventing
// arrows that are not in the chart.
func TestChartDescriptionMayContainAColon(t *testing.T) {
	const plain = `#NOTES:
     dance-single:
     Foo Bar:
     Challenge:
     10:
     0.9,1.8,0.7,0.6,0.5:
` + regressBody + `;
`
	const colon = `#NOTES:
     dance-single:
     K. Ito: Remix:
     Challenge:
     10:
     0.9,1.8,0.7,0.6,0.5:
` + regressBody + `;
`

	want := chartsForWindow(regressHeader+plain, 0, 20)
	got := chartsForWindow(regressHeader+colon, 0, 20)

	if len(want) != 1 || len(got) != 1 {
		t.Fatalf("charts: plain %d, with a colon %d; want 1 each", len(want), len(got))
	}
	if got[0].Diff != "Challenge" {
		t.Errorf("difficulty = %q, want Challenge", got[0].Diff)
	}
	if got[0].Meter != 10 {
		t.Errorf("meter = %d, want 10", got[0].Meter)
	}
	if len(got[0].Notes) != len(want[0].Notes) {
		t.Fatalf("notes = %d, want %d (the same chart, differently described)",
			len(got[0].Notes), len(want[0].Notes))
	}
	for i := range got[0].Notes {
		if got[0].Notes[i] != want[0].Notes[i] {
			t.Errorf("note %d = %+v, want %+v", i, got[0].Notes[i], want[0].Notes[i])
		}
	}
}

// A comment can hold a comma or a semicolon, and both are structure here: a
// comma ends a measure and a semicolon ends the chart. Left in, a note to a
// fellow charter shifts every measure after it, or truncates the chart.
func TestChartCommentsCannotShiftOrTruncate(t *testing.T) {
	clean := chartsForWindow(regressHeader+`#NOTES:
     dance-single:
     :
     Hard:
     8:
     0,0,0,0,0:
`+regressBody+`;
`, 0, 20)
	if len(clean) != 1 || len(clean[0].Notes) != 3 {
		t.Fatalf("control: %d charts, %d notes; want 1 and 3", len(clean), len(clean[0].Notes))
	}

	for _, tc := range []struct{ name, comment string }{
		{"comma in a comment", "// bpm change here, watch out"},
		{"semicolon in a comment", "// careful; this is a trap"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := strings.Replace(regressBody, ",\n0100", ",\n"+tc.comment+"\n0100", 1)
			got := chartsForWindow(regressHeader+`#NOTES:
     dance-single:
     :
     Hard:
     8:
     0,0,0,0,0:
`+body+`;
`, 0, 20)
			if len(got) != 1 {
				t.Fatalf("got %d charts, want 1", len(got))
			}
			if len(got[0].Notes) != len(clean[0].Notes) {
				t.Fatalf("notes = %v, want %v", times(got[0].Notes), times(clean[0].Notes))
			}
			for i := range got[0].Notes {
				if got[0].Notes[i] != clean[0].Notes[i] {
					t.Errorf("note %d = %+v, want %+v", i, got[0].Notes[i], clean[0].Notes[i])
				}
			}
		})
	}
}

// Charts come back in the order the wheel shows them. At an equal meter that
// has to fall back on the difficulty, easiest first -- Hard before Challenge,
// Edit last. It used to sort by a preference order, backwards.
func TestChartOrderAtEqualMeter(t *testing.T) {
	text := regressHeader
	for _, diff := range []string{"Edit", "Challenge", "Beginner", "Hard", "Easy", "Medium"} {
		text += `#NOTES:
     dance-single:
     :
     ` + diff + `:
     9:
     0,0,0,0,0:
` + regressBody + `;
`
	}
	got := chartsForWindow(text, 0, 20)
	if len(got) != 6 {
		t.Fatalf("got %d charts, want 6", len(got))
	}
	want := []string{"Beginner", "Easy", "Medium", "Hard", "Challenge", "Edit"}
	for i, diff := range want {
		if got[i].Diff != diff {
			var order []string
			for _, c := range got {
				order = append(order, c.Diff)
			}
			t.Fatalf("order = %v, want %v", order, want)
		}
	}
}

// Doubles sorts after singles whatever its meter, so a doubles-only pack still
// gets a chart and a mixed one does not lead with eight arrows.
func TestChartOrderPutsSinglesFirst(t *testing.T) {
	text := regressHeader +
		`#NOTES:
     dance-double:
     :
     Beginner:
     1:
     0,0,0,0,0:
` + "1000000\n0000000\n0000000\n0000000\n" + `;
#NOTES:
     dance-single:
     :
     Challenge:
     15:
     0,0,0,0,0:
` + regressBody + `;
`
	got := chartsForWindow(text, 0, 20)
	if len(got) != 2 {
		t.Fatalf("got %d charts, want 2", len(got))
	}
	if got[0].Lanes != 4 || got[1].Lanes != 8 {
		t.Errorf("lanes = %d then %d, want 4 then 8", got[0].Lanes, got[1].Lanes)
	}
}

// "nan" and "inf" parse as float64s and pass every "is it positive" test. They
// used to reach the JSON encoder, which refuses them -- and the caller saw a
// 200 with an empty body and nothing to say what had gone wrong.
func TestSampleWindowSurvivesNonsenseTags(t *testing.T) {
	for _, bad := range []string{"nan", "NaN", "inf", "+Inf", "-inf", "1e400"} {
		t.Run(bad, func(t *testing.T) {
			text := "#TITLE:Test;\n#OFFSET:0;\n#BPMS:0=120;\n" +
				"#SAMPLESTART:" + bad + ";\n#SAMPLELENGTH:" + bad + ";\n"

			start, _ := tagFloat(text, "SAMPLESTART")
			length, _ := tagFloat(text, "SAMPLELENGTH")
			if !finite(start) || start < 0 {
				start = 0
			}
			if !finite(length) || length < 0 {
				length = 0
			}
			if length <= 0 {
				if start < 20 {
					start = 20
				}
				length = 20
			}

			if math.IsNaN(start) || math.IsInf(start, 0) {
				t.Fatalf("start = %v", start)
			}
			if math.IsNaN(length) || math.IsInf(length, 0) || length <= 0 {
				t.Fatalf("length = %v", length)
			}

			sample := Sample{Start: start, Length: length, Charts: chartsForWindow(text, start, length)}
			if _, err := json.Marshal(sample); err != nil {
				t.Fatalf("the sample will not encode: %v", err)
			}
		})
	}
}

// A file whose every tempo is zero or negative has no tempo, whatever the tag
// says. It used to pass, and stacked the whole chart on one instant.
func TestChartRejectsATempoThatIsNotOne(t *testing.T) {
	for _, bpms := range []string{"0.000=0.000", "0.000=-120.000", "0.000=0.000,32.000=0.000"} {
		text := "#TITLE:Test;\n#OFFSET:0;\n#BPMS:" + bpms + ";\n" +
			`#NOTES:
     dance-single:
     :
     Hard:
     8:
     0,0,0,0,0:
` + regressBody + `;
`
		if got := chartsForWindow(text, 0, 20); got != nil {
			t.Errorf("#BPMS:%s produced %d charts; a file with no tempo has nothing to show",
				bpms, len(got))
		}
	}
}

// A negative stop is a warp. The engine plays them; a preview cannot, because
// the browser walks its notes forward only and would be handed times that go
// backwards.
func TestChartNoteTimesNeverGoBackwards(t *testing.T) {
	text := "#TITLE:Test;\n#OFFSET:0;\n#BPMS:0=120;\n#STOPS:1.000=-2.000,2.000=0.500;\n" +
		`#NOTES:
     dance-single:
     :
     Hard:
     8:
     0,0,0,0,0:
` + regressBody + `;
`
	got := chartsForWindow(text, 0, 60)
	if len(got) != 1 {
		t.Fatalf("got %d charts, want 1", len(got))
	}
	for i := 1; i < len(got[0].Notes); i++ {
		if got[0].Notes[i].T < got[0].Notes[i-1].T {
			t.Fatalf("note times go backwards: %v", times(got[0].Notes))
		}
	}
}

// A file truncated mid-chart has no closing ';'. Dropping it lost the whole
// chart, when the twenty seconds the window wants are usually all present.
func TestChartWithoutATerminatorIsStillAChart(t *testing.T) {
	text := regressHeader + `#NOTES:
     dance-single:
     :
     Hard:
     8:
     0,0,0,0,0:
` + regressBody
	got := chartsForWindow(text, 0, 20)
	if len(got) != 1 {
		t.Fatalf("got %d charts, want 1", len(got))
	}
	if len(got[0].Notes) != 3 {
		t.Errorf("notes = %v, want three", times(got[0].Notes))
	}
}
