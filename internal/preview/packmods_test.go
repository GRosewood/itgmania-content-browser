package preview

import (
	"archive/zip"
	"bytes"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

// index builds a zip holding the named entries and returns its file list, which
// is what the fetcher works from. The contents do not matter -- everything here
// reads names only.
func index(t *testing.T, names ...string) []*zip.File {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for _, name := range names {
		f, err := w.Create(name)
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		if _, err := f.Write([]byte("x")); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	r, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	return r.File
}

func TestModSongs(t *testing.T) {
	cases := []struct {
		name  string
		files []string
		want  PackMods
	}{{
		name: "a song with Lua beside its chart is a modfile",
		files: []string{
			"Pack/Song A/song.ssc", "Pack/Song A/song.ogg", "Pack/Song A/mod.lua",
			"Pack/Song B/song.sm", "Pack/Song B/song.ogg",
		},
		want: PackMods{Songs: []string{"Song A"}, Count: 1, Total: 2},
	}, {
		name: "a pack with no Lua at all",
		files: []string{
			"Pack/Song A/song.ssc", "Pack/Song B/song.sm", "Pack/pack.ini",
		},
		want: PackMods{Count: 0, Total: 2},
	}, {
		name: "Lua at the top of the pack belongs to no song",
		files: []string{
			"Pack/Song A/song.ssc", "Pack/Song B/song.sm",
			"Pack/setup.lua", "Pack/pack.ini",
		},
		want: PackMods{Count: 0, Total: 2},
	}, {
		name: "extensions are matched whatever their case",
		files: []string{
			"Pack/Song A/song.SSC", "Pack/Song A/MOD.LUA",
			"Pack/Song B/song.Sm", "Pack/Song B/notes.Lua",
		},
		want: PackMods{Songs: []string{"Song A", "Song B"}, Count: 2, Total: 2},
	}, {
		name: "songs are found however deeply the pack nests them",
		files: []string{
			"Pack/Group/Sub/Song A/song.ssc", "Pack/Group/Sub/Song A/mod.lua",
			"Song B/song.ssc",
		},
		want: PackMods{Songs: []string{"Song A"}, Count: 1, Total: 2},
	}, {
		name: "a folder of Lua with no simfile is not a song",
		files: []string{
			"Pack/Scripts/thing.lua", "Pack/Song A/song.ssc",
		},
		want: PackMods{Count: 0, Total: 1},
	}, {
		name: "several mods among many songs report both figures",
		files: []string{
			"Pack/A/a.ssc", "Pack/A/a.lua",
			"Pack/B/b.ssc",
			"Pack/C/c.sm", "Pack/C/gimmick.lua",
			"Pack/D/d.ssc", "Pack/E/e.ssc",
		},
		want: PackMods{Songs: []string{"A", "C"}, Count: 2, Total: 5},
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := modSongs(index(t, c.files...))
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("modSongs() = %+v, want %+v", got, c.want)
			}
		})
	}
}

// TestPackModsOverRangeRequests runs the real path: a pack served over HTTP,
// read through the same ranged index every preview uses. The modfile here is
// named default.lua, which is what a chart's mod is actually called.
func TestPackModsOverRangeRequests(t *testing.T) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	// Stored rather than deflated: repeated filler compresses to almost nothing,
	// and a pack small enough to swallow whole would not exercise the seek this
	// test exists to check.
	add := func(name string, body []byte, method uint16) {
		t.Helper()
		w, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: method})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(body); err != nil {
			t.Fatal(err)
		}
	}
	filler := bytes.Repeat([]byte("audio data "), 200_000)
	add("Cholomount/[T02] Ascendanz (SM)/song.ssc", []byte("#TITLE:Ascendanz;\n"), zip.Deflate)
	add("Cholomount/[T02] Ascendanz (SM)/song.ogg", append([]byte("OggS"), filler...), zip.Store)
	add("Cholomount/[T02] Ascendanz (SM)/default.lua", []byte("return Def.ActorFrame{}\n"), zip.Deflate)
	add("Cholomount/Plain Song/song.sm", []byte("#TITLE:Plain Song;\n"), zip.Deflate)
	add("Cholomount/Plain Song/song.ogg", append([]byte("OggS"), filler...), zip.Store)
	add("Cholomount/pack.ini", []byte("[Group]\nSyncOffset=NULL\n"), zip.Deflate)
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	packBytes := buf.Bytes()

	var served int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/download/pack/") {
			http.NotFound(w, r)
			return
		}
		rec := &counter{ResponseWriter: w}
		http.ServeContent(rec, r, "pack.zip", time.Unix(0, 0), bytes.NewReader(packBytes))
		served += rec.n
	}))
	defer srv.Close()

	f := New(t.TempDir(), srv.URL)
	got, err := f.PackMods(10269)
	if err != nil {
		t.Fatalf("PackMods: %v", err)
	}
	want := PackMods{Songs: []string{"[T02] Ascendanz (SM)"}, Count: 1, Total: 2}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("PackMods() = %+v, want %+v", got, want)
	}
	if served >= int64(len(packBytes)) {
		t.Errorf("read %d bytes of a %d byte pack -- it downloaded the whole thing",
			served, len(packBytes))
	}
	t.Logf("answered from %d bytes of a %d byte pack", served, len(packBytes))
}

// counter records how much a handler actually wrote, so a test can tell a
// ranged read from a full download.
type counter struct {
	http.ResponseWriter
	n int64
}

func (c *counter) Write(p []byte) (int, error) {
	n, err := c.ResponseWriter.Write(p)
	c.n += int64(n)
	return n, err
}
