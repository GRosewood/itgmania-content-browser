package preview

import (
	"archive/zip"
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestNormalizeIgnoresPunctuationAndCase(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"Stupid For You", "stupidforyou"},
		{"stupid_for_you", "stupidforyou"},
		{"[16] Stupid For You!", "16stupidforyou"},
		{"", ""},
	} {
		if got := normalize(tc.in); got != tc.want {
			t.Errorf("normalize(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestTagFloatReadsSimfileTags(t *testing.T) {
	body := "#TITLE:Whatever;\n#SAMPLESTART:45.500;\n#SAMPLELENGTH:12.000;\n"
	if v, ok := tagFloat(body, "SAMPLESTART"); !ok || v != 45.5 {
		t.Errorf("SAMPLESTART = %v, %v; want 45.5, true", v, ok)
	}
	if v, ok := tagFloat(body, "SAMPLELENGTH"); !ok || v != 12 {
		t.Errorf("SAMPLELENGTH = %v, %v; want 12, true", v, ok)
	}
	if _, ok := tagFloat(body, "OFFSET"); ok {
		t.Error("found a tag that is not there")
	}
	if _, ok := tagFloat("#SAMPLESTART:nonsense;", "SAMPLESTART"); ok {
		t.Error("accepted a non-numeric tag")
	}
}

func TestPickRefusesACoincidence(t *testing.T) {
	songs := []song{{dir: "pack/Aurora Borealis"}, {dir: "pack/Stupid For You"}}
	if got, ok := pick(songs, "Stupid For You"); !ok || got.dir != "pack/Stupid For You" {
		t.Errorf("exact match failed: %v %v", got.dir, ok)
	}
	// "Ur" appears inside "Aurora" -- two characters of overlap is not a match.
	if _, ok := pick(songs, "Ur"); ok {
		t.Error("matched a two-character coincidence")
	}
	if _, ok := pick(songs, "Some Other Song Entirely"); ok {
		t.Error("matched a song that is not in the pack")
	}
}

func TestCollectPrefersTheSmallerAudioAndTheSscFile(t *testing.T) {
	// A folder shipping both a full track and a short clip, and both simfile
	// formats. The clip and the .ssc should win.
	files := []*zip.File{
		zipEntry("pack/Song/full.ogg", 5_000_000),
		zipEntry("pack/Song/clip.ogg", 400_000),
		zipEntry("pack/Song/song.sm", 20_000),
		zipEntry("pack/Song/song.ssc", 22_000),
		zipEntry("__MACOSX/pack/Song/._clip.ogg", 100),
		zipEntry("pack/Song/banner.png", 90_000),
	}
	songs := collect(files)
	if len(songs) != 1 {
		t.Fatalf("got %d songs, want 1", len(songs))
	}
	if songs[0].audio.Name != "pack/Song/clip.ogg" {
		t.Errorf("audio = %q, want the clip", songs[0].audio.Name)
	}
	if songs[0].simfile.Name != "pack/Song/song.ssc" {
		t.Errorf("simfile = %q, want the .ssc", songs[0].simfile.Name)
	}
}

func zipEntry(name string, size uint64) *zip.File {
	f := &zip.File{}
	f.Name = name
	f.CompressedSize64 = size
	f.UncompressedSize64 = size
	return f
}

// ---------------------------------------------------------------- end to end

// buildPack writes a zip shaped like a real pack: a pack folder, song folders
// under it, and an audio file and simfile in each.
func buildPack(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	add := func(name string, body []byte) {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(body); err != nil {
			t.Fatal(err)
		}
	}
	// Deliberately large and compressible, so the reader has to span blocks.
	audio := append([]byte("OggS"), bytes.Repeat([]byte("audio data "), 200_000)...)
	add("Test Pack/Stupid For You/stupid for you.ogg", audio)
	add("Test Pack/Stupid For You/song.ssc", []byte("#TITLE:Stupid For You;\n#SAMPLESTART:45.5;\n#SAMPLELENGTH:12;\n"))
	add("Test Pack/Another Song/another.ogg", append([]byte("OggS"), bytes.Repeat([]byte("x"), 50_000)...))
	add("Test Pack/Another Song/song.sm", []byte("#TITLE:Another Song;\n"))
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestGetExtractsOneSongOverRangeRequests(t *testing.T) {
	packBytes := buildPack(t)

	var ranged int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/download/pack/") {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Range") != "" {
			ranged++
		}
		// ServeContent handles Range and Accept-Ranges for us, which is what
		// the real download server does too.
		http.ServeContent(w, r, "pack.zip", time.Unix(0, 0), bytes.NewReader(packBytes))
	}))
	defer srv.Close()

	dir := t.TempDir()
	f := New(dir, srv.URL)

	got, err := f.Get(10269, "Stupid For You")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Start != 45.5 || got.Length != 12 {
		t.Errorf("sample window = %v/%v, want 45.5/12", got.Start, got.Length)
	}
	if got.Title != "Stupid For You" {
		t.Errorf("title = %q", got.Title)
	}
	if ranged == 0 {
		t.Error("never issued a range request -- it downloaded the whole pack")
	}

	body, err := os.ReadFile(got.Path)
	if err != nil {
		t.Fatalf("reading the extracted audio: %v", err)
	}
	if !bytes.HasPrefix(body, []byte("OggS")) {
		t.Error("extracted file is not the audio we put in")
	}
	if len(body) != 4+11*200_000 {
		t.Errorf("extracted %d bytes, want the whole entry", len(body))
	}

	// Asking again reuses the file rather than fetching it a second time.
	before := ranged
	again, err := f.Get(10269, "Stupid For You")
	if err != nil || again.Path != got.Path {
		t.Fatalf("second Get: %v %v", again, err)
	}
	if ranged != before {
		t.Errorf("refetched a cached preview (%d new range requests)", ranged-before)
	}

	// And a song that is not in the pack is an error, not a wrong song.
	if _, err := f.Get(10269, "Not In This Pack At All"); err == nil {
		t.Error("matched a song the pack does not have")
	}

	f.Clear()
	if _, err := os.Stat(got.Path); !os.IsNotExist(err) {
		t.Error("Clear left the extracted audio behind")
	}
}

func TestGetRejectsNonsenseArguments(t *testing.T) {
	f := New(t.TempDir(), "https://example.invalid")
	if _, err := f.Get(0, "Song"); err == nil {
		t.Error("accepted pack 0")
	}
	if _, err := f.Get(1, "   "); err == nil {
		t.Error("accepted a blank song")
	}
}

func TestTempoPrefersDisplayBpmThenBpms(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		want       float64
	}{
		{"displaybpm wins", "#BPMS:0.000=150.000;\n#DISPLAYBPM:175;", 175},
		{"range takes the low end", "#DISPLAYBPM:150:170;", 150},
		{"falls back to the first bpms entry", "#BPMS:0.000=128.500,32.000=200.000;", 128.5},
		{"nothing usable", "#TITLE:Whatever;", 0},
		{"junk displaybpm falls through", "#DISPLAYBPM:*;\n#BPMS:0.000=90.000;", 90},
	} {
		if got := tempo(tc.body); got != tc.want {
			t.Errorf("%s: tempo = %v, want %v", tc.name, got, tc.want)
		}
	}
}

// buildSpreadPack makes a pack whose songs are incompressible and far enough
// apart to land in different blocks, so that what a fetch reads is visible in
// the request count rather than hidden by a block that happened to be cached.
func buildSpreadPack(t *testing.T) []byte {
	t.Helper()
	noise := func(n int, seed uint32) []byte {
		b := make([]byte, n)
		x := seed
		for i := range b {
			x = x*1664525 + 1013904223 // a plain LCG: incompressible enough, and the same every run
			b[i] = byte(x >> 24)
		}
		return b
	}
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	add := func(name string, body []byte) {
		// Stored, not deflated: the point is for these to occupy real space.
		w, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Store})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(body); err != nil {
			t.Fatal(err)
		}
	}
	add("Pack/Song One/one.ogg", append([]byte("OggS"), noise(3<<20, 1)...))
	add("Pack/Song One/one.ssc", []byte("#SAMPLESTART:10;\n#SAMPLELENGTH:12;\n"))
	add("Pack/Song Two/two.ogg", append([]byte("OggS"), noise(3<<20, 99)...))
	add("Pack/Song Two/two.ssc", []byte("#SAMPLESTART:20;\n#SAMPLELENGTH:12;\n"))
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestSecondSongInAPackSkipsTheIndex(t *testing.T) {
	packBytes := buildSpreadPack(t)

	var heads, ranges int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			heads++
		} else if r.Header.Get("Range") != "" {
			ranges++
		}
		http.ServeContent(w, r, "pack.zip", time.Unix(0, 0), bytes.NewReader(packBytes))
	}))
	defer srv.Close()

	f := New(t.TempDir(), srv.URL)

	if _, err := f.Get(1, "Song One"); err != nil {
		t.Fatalf("first song: %v", err)
	}
	firstHeads, firstRanges := heads, ranges
	if firstHeads != 1 {
		t.Fatalf("first song issued %d HEADs, want 1", firstHeads)
	}

	// A different song out of the same pack. The index is already in hand, so
	// nothing should ask the server how big the pack is a second time, and the
	// only reads should be the ones covering that song's audio.
	if _, err := f.Get(1, "Song Two"); err != nil {
		t.Fatalf("second song: %v", err)
	}
	if heads != firstHeads {
		t.Errorf("second song re-read the pack header (%d HEADs, want %d)", heads, firstHeads)
	}
	second := ranges - firstRanges
	if second == 0 {
		t.Error("second song fetched nothing, so this proves nothing")
	}
	t.Logf("first song %d ranged reads, second song %d", firstRanges, second)
}
