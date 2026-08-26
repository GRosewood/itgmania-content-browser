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

// An uninstall has to take the browser's own working data with it. It never
// did: the helper's folder and the preview cache hold no file the payload
// ships, so the file-by-file walk never reached them and a "complete" uninstall
// left the installed-dates list and megabytes of downloaded artwork behind.
func TestUninstallRemovesTheBrowsersOwnDataAndCache(t *testing.T) {
	inst := fixture(t)
	modules := filepath.Join(inst.ThemesDir, "Simply Love", "Modules")
	if err := os.MkdirAll(modules, 0o755); err != nil {
		t.Fatal(err)
	}

	helperDir := HelperDir(inst)
	if err := os.MkdirAll(helperDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"installed-dates.txt", "beginner-packs.txt"} {
		if err := os.WriteFile(filepath.Join(helperDir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	cache, err := CacheDir(inst)
	if err != nil {
		t.Fatalf("CacheDir: %v", err)
	}
	ours := filepath.Join(cache, "ITGmaniaContentBrowser")
	if err := os.MkdirAll(filepath.Join(ours, "previews"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ours, "previews", "a.ogg"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// the engine's own cache lives beside ours and must survive
	engine := filepath.Join(cache, "Songs")
	if err := os.MkdirAll(engine, 0o755); err != nil {
		t.Fatal(err)
	}

	if _, err := Uninstall(inst, os.DirFS(t.TempDir())); err != nil {
		t.Fatalf("Uninstall: %v", err)
	}

	if _, err := os.Stat(helperDir); !os.IsNotExist(err) {
		t.Errorf("the helper's folder survived the uninstall: %v", err)
	}
	if _, err := os.Stat(ours); !os.IsNotExist(err) {
		t.Errorf("the preview cache survived the uninstall: %v", err)
	}
	if _, err := os.Stat(engine); err != nil {
		t.Errorf("the engine's own cache was taken with ours: %v", err)
	}
}

// Folders wholly ours by name go wholesale, because the uninstaller's idea of
// the payload can be older than what is on disk -- the Windows wizard runs the
// copy bundled when setup.exe was last run.
func TestUninstallTakesOurFoldersEvenWhenThePayloadIsStale(t *testing.T) {
	inst := fixture(t)
	modules := filepath.Join(inst.ThemesDir, "Simply Love", "Modules")
	for _, dir := range []string{"ITGmania Content Browser", "ContentBrowserIcons"} {
		if err := os.MkdirAll(filepath.Join(modules, dir), 0o755); err != nil {
			t.Fatal(err)
		}
		// a name no payload has ever shipped
		orphan := filepath.Join(modules, dir, "99 renamed in a later release.lua")
		if err := os.WriteFile(orphan, []byte("-- x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Simply Love's own file in the same directory must not be touched.
	if err := os.WriteFile(filepath.Join(modules, "README.md"), []byte("theirs"), 0o644); err != nil {
		t.Fatal(err)
	}

	// an empty payload: the walk removes nothing, so only the wholesale pass can
	if _, err := Uninstall(inst, os.DirFS(t.TempDir())); err != nil {
		t.Fatalf("Uninstall: %v", err)
	}

	for _, dir := range []string{"ITGmania Content Browser", "ContentBrowserIcons"} {
		if _, err := os.Stat(filepath.Join(modules, dir)); !os.IsNotExist(err) {
			t.Errorf("%s survived with orphaned files in it: %v", dir, err)
		}
	}
	if body, err := os.ReadFile(filepath.Join(modules, "README.md")); err != nil || string(body) != "theirs" {
		t.Errorf("Simply Love's own README was disturbed: %q, %v", body, err)
	}
}
