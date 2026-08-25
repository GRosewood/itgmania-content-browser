package packs

import (
	"archive/zip"
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"
)

func TestSafeRelRefusesEscapes(t *testing.T) {
	for _, bad := range []string{
		"../evil.sm",
		"pack/../../evil.sm",
		`C:\Windows\evil.sm`,
		"..",
		"pack/..",
		"__MACOSX/pack/._x",
		"",
	} {
		if got, ok := safeRel(bad); ok {
			t.Errorf("safeRel(%q) allowed %q", bad, got)
		}
	}
	for _, good := range []struct{ in, want string }{
		{"Pack/Song/file.sm", "Pack/Song/file.sm"},
		{"/Pack/Song/file.sm", "Pack/Song/file.sm"},
		// stripped to a relative path, so it lands inside the pack root
		{"/etc/passwd", "etc/passwd"},
		{`Pack\Song\file.sm`, "Pack/Song/file.sm"},
	} {
		got, ok := safeRel(good.in)
		if !ok || got != good.want {
			t.Errorf("safeRel(%q) = %q,%v; want %q,true", good.in, got, ok, good.want)
		}
	}
}

func buildPack(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	add := func(name, body string) {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	add("Test Pack/Song One/song.ssc", "#TITLE:One;")
	add("Test Pack/Song One/song.ogg", "OggS........")
	add("Test Pack/Song Two/song.ssc", "#TITLE:Two;")
	// something that must never be written
	add("../escaped.txt", "nope")
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestInstallLandsInTheGivenRoot(t *testing.T) {
	packBytes := buildPack(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/zip")
		http.ServeContent(w, r, "pack.zip", time.Unix(0, 0), bytes.NewReader(packBytes))
	}))
	defer srv.Close()

	// Two directories, standing in for <install>/Songs and a mounted drive.
	base := t.TempDir()
	deflt := filepath.Join(base, "Songs")
	mounted := filepath.Join(base, "mnt", "songs")
	for _, d := range []string{deflt, mounted} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	in := New(func() (string, error) { return mounted, nil }, srv.URL)
	if err := in.Start(7, "Test Pack"); err != nil {
		t.Fatalf("Start: %v", err)
	}

	var last Progress
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		all := in.Status()
		if len(all) == 1 && (all[0].Phase == "done" || all[0].Phase == "failed") {
			last = all[0]
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if last.Phase != "done" {
		t.Fatalf("install ended as %q: %s", last.Phase, last.Err)
	}

	// the pack is on the mounted drive...
	if _, err := os.Stat(filepath.Join(mounted, "Test Pack", "Song One", "song.ssc")); err != nil {
		t.Errorf("pack did not land in the configured root: %v", err)
	}
	// ...and nothing at all went to the default one
	entries, err := os.ReadDir(deflt)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("%d entries written to the default Songs folder, want none", len(entries))
	}

	// the escaping entry was refused
	if _, err := os.Stat(filepath.Join(base, "escaped.txt")); !os.IsNotExist(err) {
		t.Error("an entry escaped the destination")
	}

	sort.Strings(last.Groups)
	if len(last.Groups) != 1 || last.Groups[0] != "Test Pack" {
		t.Errorf("groups = %v, want [Test Pack]", last.Groups)
	}
	// and the part file was cleaned up
	for _, e := range mustRead(t, mounted) {
		if filepath.Ext(e) == ".part" {
			t.Errorf("left a temp file behind: %s", e)
		}
	}
}

func mustRead(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

func TestInstallReportsAnUnusableRoot(t *testing.T) {
	in := New(func() (string, error) { return "", os.ErrPermission }, "https://example.invalid")
	if err := in.Start(0, "x"); err == nil {
		t.Error("accepted pack 0")
	}
	if err := in.Start(9, "x"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		all := in.Status()
		if len(all) == 1 && all[0].Phase == "failed" {
			if all[0].Err == "" {
				t.Error("failed without saying why")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Error("an install with nowhere to go never reported failure")
}
