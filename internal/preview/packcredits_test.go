package preview

import (
	"reflect"
	"testing"
)

// The parser has to read authorship the way pack authors actually wrote it:
// SSC header + per-chart tags, SM header + the description slot of #NOTES.
func TestSimfileCredits(t *testing.T) {
	cases := []struct {
		name string
		file string
		body string
		want []string
	}{{
		name: "ssc header and per-chart credits, deduplicated",
		file: "song.ssc",
		body: "#TITLE:A;\n#CREDIT:Rosewood;\n" +
			"#NOTEDATA:;\n#STEPSTYPE:dance-single;\n#CREDIT:Rosewood;\n#NOTES:\n0000\n;\n" +
			"#NOTEDATA:;\n#STEPSTYPE:dance-double;\n#CREDIT:G. Rosewood;\n#NOTES:\n0000\n;\n",
		want: []string{"G. Rosewood", "Rosewood"},
	}, {
		name: "sm description slot carries the author",
		file: "song.sm",
		body: "#TITLE:B;\n" +
			"#NOTES:\n     dance-single:\n     Rosewood:\n     Challenge:\n     12:\n     0,0,0,0,0:\n0000\n;\n" +
			"#NOTES:\n     dance-single:\n     :\n     Hard:\n     9:\n     0,0,0,0,0:\n0000\n;\n",
		want: []string{"Rosewood"},
	}, {
		name: "sm with header credit and empty descriptions",
		file: "song.sm",
		body: "#TITLE:C;\n#CREDIT:Rosewood;\n" +
			"#NOTES:\n     dance-single:\n     :\n     Medium:\n     7:\n     0:\n0000\n;\n",
		want: []string{"Rosewood"},
	}, {
		name: "nothing credited anywhere",
		file: "song.sm",
		body: "#TITLE:D;\n#NOTES:\n     dance-single:\n     :\n     Easy:\n     3:\n     0:\n0000\n;\n",
		want: nil,
	}, {
		name: "ssc with chart credits but no header",
		file: "song.ssc",
		body: "#TITLE:E;\n#NOTEDATA:;\n#CREDIT:Somebody Else;\n#NOTES:\n0000\n;\n",
		want: []string{"Somebody Else"},
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := simfileCredits(c.file, c.body)
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("simfileCredits() = %#v, want %#v", got, c.want)
			}
		})
	}
}
