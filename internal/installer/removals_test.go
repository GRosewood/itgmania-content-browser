package installer

import (
	"os"
	"path/filepath"
	"testing"
)

// fixture builds an install root with a Songs directory and the given packs.
func fixture(t *testing.T, packs ...string) Install {
	t.Helper()
	root := t.TempDir()
	for _, p := range packs {
		dir := filepath.Join(root, "Songs", p, "A Song")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "song.sm"), []byte("#TITLE:x;"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}
	return Install{Root: root, SaveDir: save, ThemesDir: filepath.Join(root, "Themes")}
}

// The pack name arrives over HTTP from the game, so a traversal must never
// reach outside the Songs directory even though the endpoint is loopback-only.
func TestSafePackDirRejectsEscapes(t *testing.T) {
	inst := fixture(t, "Real Pack")

	for _, name := range []string{
		"..", ".", "../Program", `..\Program`, "sub/dir", `sub\dir`,
		"/etc", `C:\Windows`, "", "   ",
	} {
		if dir, err := safePackDir(inst, name); err == nil {
			t.Errorf("%q was accepted as %q; want refusal", name, dir)
		}
	}
}

func TestSafePackDirFindsRealPack(t *testing.T) {
	inst := fixture(t, "Real Pack")
	dir, err := safePackDir(inst, "Real Pack")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(dir) != "Real Pack" {
		t.Errorf("got %q", dir)
	}
}

func TestSafePackDirRejectsMissingPack(t *testing.T) {
	inst := fixture(t, "Real Pack")
	if _, err := safePackDir(inst, "Never Existed"); err == nil {
		t.Error("a pack that is not there should not resolve")
	}
}

func TestRemovePackDeletesOnlyItsOwnFolder(t *testing.T) {
	inst := fixture(t, "Alpha", "Keep Me")

	path, err := RemovePack(inst, "Alpha")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(path) != "Alpha" {
		t.Errorf("removed %q", path)
	}

	songs := filepath.Join(inst.Root, "Songs")
	if _, err := os.Stat(filepath.Join(songs, "Alpha")); !os.IsNotExist(err) {
		t.Error("Alpha still exists")
	}
	if _, err := os.Stat(filepath.Join(songs, "Keep Me")); err != nil {
		t.Errorf("an unrelated pack was removed: %v", err)
	}
}

func TestRemovePackRefusesTraversal(t *testing.T) {
	inst := fixture(t, "Alpha")
	// a sibling of Songs/ that must survive
	outside := filepath.Join(inst.Root, "Program")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}

	if _, err := RemovePack(inst, "../Program"); err == nil {
		t.Fatal("traversal was accepted")
	}
	if _, err := os.Stat(outside); err != nil {
		t.Errorf("the traversal target was removed: %v", err)
	}
}

func TestSongRootsFindsThePortableLayout(t *testing.T) {
	inst := fixture(t, "Alpha")
	roots := SongRoots(inst)
	if len(roots) == 0 {
		t.Fatal("no song roots found")
	}
	if filepath.Base(roots[0]) != "Songs" {
		t.Errorf("got %q", roots[0])
	}
}
