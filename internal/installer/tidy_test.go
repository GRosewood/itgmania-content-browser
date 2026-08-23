package installer

import (
	"os"
	"path/filepath"
	"testing"
)

// The engine leaves an empty <dir>newdir.temp.newdir beside every directory it
// creates, so unzipping a pack scatters one per song folder. The sweep has to
// clear those without touching anything a pack actually needs.
func TestTidyProbeFilesClearsProbesAndNothingElse(t *testing.T) {
	root := t.TempDir()
	songs := filepath.Join(root, "Songs")
	pack := filepath.Join(songs, "Some Pack")
	song := filepath.Join(pack, "A Song")
	if err := os.MkdirAll(song, 0o755); err != nil {
		t.Fatal(err)
	}

	write := func(path string, body string) {
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// the probes: one beside the pack, one beside the song folder
	beside := pack + "newdir.temp.newdir"
	inside := song + "newdir.temp.newdir"
	write(beside, "")
	write(inside, "")

	// and things that must survive
	chart := filepath.Join(song, "song.ssc")
	banner := filepath.Join(pack, "banner.png")
	// a file that ends the same way but is NOT empty: not ours to delete
	notEmpty := filepath.Join(pack, "keepnewdir.temp.newdir")
	write(chart, "#TITLE:A Song;")
	write(banner, "not really a png")
	write(notEmpty, "somebody put something here")

	inst := Install{Root: root, SaveDir: filepath.Join(root, "Save")}

	removed, err := TidyProbeFiles(inst)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if len(removed) != 2 {
		t.Fatalf("removed %d probes, want 2: %v", len(removed), removed)
	}

	for _, gone := range []string{beside, inside} {
		if _, err := os.Stat(gone); !os.IsNotExist(err) {
			t.Errorf("%s should have been swept", filepath.Base(gone))
		}
	}
	for _, kept := range []string{chart, banner, notEmpty} {
		if _, err := os.Stat(kept); err != nil {
			t.Errorf("%s should have survived: %v", filepath.Base(kept), err)
		}
	}
}

// Sweeping an install whose Songs directory does not exist is not an error --
// the helper calls this after every download and should not start reporting
// failures on an install laid out differently.
func TestTidyProbeFilesToleratesAMissingSongsDirectory(t *testing.T) {
	root := t.TempDir()
	inst := Install{Root: root, SaveDir: filepath.Join(root, "Save")}
	removed, err := TidyProbeFiles(inst)
	if err != nil {
		t.Fatalf("sweep should tolerate a missing Songs dir, got %v", err)
	}
	if len(removed) != 0 {
		t.Fatalf("removed %v from an install with no Songs", removed)
	}
}
