package preview

import (
	"archive/zip"
	"bytes"
	"strings"
	"testing"
)

// indexOf builds an archive index over a zip made from name -> contents.
func indexOf(t *testing.T, files map[string]string) *archive {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	blob := buf.Bytes()
	zr, err := zip.NewReader(bytes.NewReader(blob), int64(len(blob)))
	if err != nil {
		t.Fatal(err)
	}
	return &archive{files: zr.File}
}

func TestFindPackIniPrefersTheShallowest(t *testing.T) {
	cases := []struct {
		name  string
		files map[string]string
		want  string
	}{
		{
			name: "beside the song folders",
			files: map[string]string{
				"Some Pack/Pack.ini":        "[Group]\nSyncOffset=NULL\n",
				"Some Pack/A Song/song.ssc": "#TITLE:A;",
				"Some Pack/A Song/Pack.ini": "not the pack's",
			},
			want: "Some Pack/Pack.ini",
		},
		{
			name: "packed flat",
			files: map[string]string{
				"pack.ini":        "[Group]\nSyncOffset=ITG\n",
				"A Song/song.ssc": "#TITLE:A;",
			},
			want: "pack.ini",
		},
		{
			name: "only inside a song folder is not the pack's, but it is all there is",
			files: map[string]string{
				"Some Pack/A Song/Pack.ini": "[Group]\nSyncOffset=ITG\n",
			},
			want: "Some Pack/A Song/Pack.ini",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := findPackIni(indexOf(t, c.files))
			if got == nil {
				t.Fatal("found nothing")
			}
			if got.Name != c.want {
				t.Errorf("found %q, want %q", got.Name, c.want)
			}
		})
	}
}

func TestFindPackIniIgnoresEverythingElse(t *testing.T) {
	got := findPackIni(indexOf(t, map[string]string{
		"Some Pack/A Song/song.ssc": "#TITLE:A;",
		"Some Pack/banner.png":      "png",
		"Some Pack/packs.ini":       "not it",
		"Some Pack/Pack.ini.bak":    "not it either",
	}))
	if got != nil {
		t.Errorf("found %q in an archive with no Pack.ini", got.Name)
	}
}

func TestSyncOffsetIsReadLoosely(t *testing.T) {
	cases := []struct {
		body string
		want string
	}{
		{"[Group]\nSyncOffset=NULL\n", "NULL"},
		{"[Group]\nSyncOffset=ITG\n", "ITG"},
		{"[Group]\r\nsyncoffset = itg\r\n", "ITG"},
		{"[Group]\nSync_Offset=null\n", "NULL"},
		{"[Group]\nSyncOffset  =  0\n", "NULL"},
		// a file that says nothing about sync is present but silent
		{"[Group]\nDisplayTitle=Some Pack\n", ""},
		{"", ""},
		// and a value nobody recognises is not guessed at
		{"[Group]\nSyncOffset=banana\n", ""},
	}
	for _, c := range cases {
		var got string
		if m := syncOffset.FindStringSubmatch(c.body); m != nil {
			switch strings.ToUpper(strings.TrimSpace(m[1])) {
			case "NULL", "0":
				got = "NULL"
			case "ITG":
				got = "ITG"
			}
		}
		if got != c.want {
			t.Errorf("%q -> %q, want %q", c.body, got, c.want)
		}
	}
}

func TestFindBesideTakesOnlyAudioInTheSongsOwnFolder(t *testing.T) {
	a := indexOf(t, map[string]string{
		"Pack/A Song/song.ssc":     "#TITLE:A;",
		"Pack/A Song/preview.ogg":  "clip",
		"Pack/A Song/song.ogg":     "full",
		"Pack/A Song/banner.png":   "png",
		"Pack/Other Song/loud.ogg": "not this one",
	})

	cases := []struct {
		name string
		tag  string
		want string
	}{
		{"names the clip", "preview.ogg", "Pack/A Song/preview.ogg"},
		// tags are typed by hand, and the archives were built on filesystems
		// that did not care
		{"wrong case", "PREVIEW.OGG", "Pack/A Song/preview.ogg"},
		{"padded", "  preview.ogg  ", "Pack/A Song/preview.ogg"},
		// a path in the tag addresses the song's folder, never the archive
		{"path is stripped", "sub/preview.ogg", "Pack/A Song/preview.ogg"},
		{"windows path is stripped", `sub\preview.ogg`, "Pack/A Song/preview.ogg"},
		{"cannot climb out", "../Other Song/loud.ogg", "Pack/A Song/loud.ogg"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := findBeside(a, "Pack/A Song", c.tag)
			if c.want == "Pack/A Song/loud.ogg" {
				// there is no loud.ogg in this song's folder, so nothing
				if got != nil {
					t.Errorf("reached %q from another folder", got.Name)
				}
				return
			}
			if got == nil {
				t.Fatalf("found nothing for %q", c.tag)
			}
			if got.Name != c.want {
				t.Errorf("found %q, want %q", got.Name, c.want)
			}
		})
	}
}

func TestFindBesideRefusesWhatIsNotAudio(t *testing.T) {
	a := indexOf(t, map[string]string{
		"Pack/A Song/song.ssc":   "#TITLE:A;",
		"Pack/A Song/banner.png": "png",
	})
	for _, tag := range []string{"banner.png", "song.ssc", "", "   ", ".", "..", "missing.ogg"} {
		if got := findBeside(a, "Pack/A Song", tag); got != nil {
			t.Errorf("%q gave %q", tag, got.Name)
		}
	}
}
