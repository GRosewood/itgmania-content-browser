package update

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"itgmania-content-browser/internal/branding"
	"itgmania-content-browser/internal/installer"
)

// The module is an entry file plus a folder of parts, and Simply Love loads
// every .lua sitting directly in Modules/ while ignoring folders. So exactly
// one .lua may ever land at the top of Modules/. Two would both be loaded, and
// the browser would register its title-menu entry twice.
//
// Nothing on the update path deletes anything -- Write is CopyModuleFiles,
// which only ever writes -- so a release that renamed or moved the entry file
// would leave the old one behind on every machine that updated in game, and
// the two would be loaded together. That is not a thing to find out from a bug
// report, so it is a test.
func TestUpdateOverAnOlderModuleLeavesOneTopLevelLua(t *testing.T) {
	// The shipped archive, if it has been built. This is deliberately the real
	// artifact rather than a fixture: the thing worth checking is what actually
	// goes out.
	archive := distArchive(t)
	zr, err := zip.OpenReader(archive)
	if err != nil {
		t.Fatalf("open archive: %v", err)
	}
	defer zr.Close()

	// Where the module would be re-rooted to. "." means the whole archive
	// survives; anything else means files above that directory are dropped.
	root, err := payloadRoot(&zr.Reader)
	if err != nil {
		t.Fatalf("payloadRoot: %v", err)
	}
	if _, err := root.Open(ModuleFile); err != nil {
		t.Fatalf("the re-rooted payload has no %s: %v", ModuleFile, err)
	}
	// The icons sit beside the entry file. If the archive were rooted at a
	// subfolder they would silently vanish from in-game updates while fresh
	// installs still worked, which is the quiet half of this failure.
	if _, err := root.Open("ContentBrowserIcons/beginner.png"); err != nil {
		t.Errorf("the re-rooted payload dropped ContentBrowserIcons: %v", err)
	}

	// A Modules/ folder as it looks on a machine running the previous release:
	// one big single-file module, and the icons.
	modules := t.TempDir()
	oldModule := filepath.Join(modules, ModuleFile)
	if err := os.WriteFile(oldModule, []byte("-- the previous, single-file module\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(modules, "ContentBrowserIcons"), 0o755); err != nil {
		t.Fatal(err)
	}

	// Exactly what the in-game updater does.
	if _, err := installer.CopyModuleFiles(modules, root, nil); err != nil {
		t.Fatalf("unpacking over the old install: %v", err)
	}

	entries, err := os.ReadDir(modules)
	if err != nil {
		t.Fatal(err)
	}
	var topLevelLua []string
	for _, e := range entries {
		if !e.IsDir() && strings.EqualFold(filepath.Ext(e.Name()), ".lua") {
			topLevelLua = append(topLevelLua, e.Name())
		}
	}
	if len(topLevelLua) != 1 || topLevelLua[0] != ModuleFile {
		t.Fatalf("Modules/ holds %v after the update; it must hold exactly [%s]",
			topLevelLua, ModuleFile)
	}

	// And the old contents are gone rather than merely joined.
	got, err := os.ReadFile(oldModule)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(got), "the previous, single-file module") {
		t.Error("the old module was not overwritten")
	}

	// The parts landed in their folder, where the theme's non-recursive listing
	// will never see them.
	parts, err := os.ReadDir(filepath.Join(modules, strings.TrimSuffix(ModuleFile, ".lua")))
	if err != nil {
		t.Fatalf("the parts folder was not written: %v", err)
	}
	var count int
	for _, p := range parts {
		if strings.EqualFold(filepath.Ext(p.Name()), ".lua") {
			count++
		}
	}
	if count < 20 {
		t.Errorf("only %d parts were written; the split has more than that", count)
	}
	t.Logf("one top-level %s, %d parts beside it", ModuleFile, count)
}

// distArchive is the built module zip for THIS version, named from branding
// rather than a literal -- a hardcoded name had both of these release-safety
// tests silently skipping forever after the first version bump.
func distArchive(t *testing.T) string {
	t.Helper()
	archive := filepath.Join("..", "..", "dist",
		branding.Slug+"-module-"+branding.Version+".zip")
	if _, err := os.Stat(archive); err != nil {
		t.Skipf("%s not built; run ./build.sh first", filepath.Base(archive))
	}
	return archive
}

// The write order is a safety property, so it is pinned here rather than left
// to luck. CopyModuleFiles walks the payload in sorted order, and "ITGmania
// Content Browser/..." sorts before "ITGmania Content Browser.lua" -- the
// folder's children before the entry file. An update interrupted partway
// through therefore leaves the OLD entry file in place next to whatever parts
// were written: the old single-file module still works outright, and an old
// split entry either loads cleanly or names the missing part in an error. If
// the entry were written first, an interruption would leave a new entry
// pointing at old parts, which can misbehave without erroring at all.
func TestUpdateWritesThePartsBeforeTheEntryFile(t *testing.T) {
	archive := distArchive(t)
	zr, err := zip.OpenReader(archive)
	if err != nil {
		t.Fatalf("open archive: %v", err)
	}
	defer zr.Close()
	root, err := payloadRoot(&zr.Reader)
	if err != nil {
		t.Fatalf("payloadRoot: %v", err)
	}

	written, err := installer.CopyModuleFiles(t.TempDir(), root, nil)
	if err != nil {
		t.Fatalf("CopyModuleFiles: %v", err)
	}

	entryAt, lastPartAt := -1, -1
	for i, name := range written {
		if name == ModuleFile {
			entryAt = i
		}
		if strings.HasPrefix(name, strings.TrimSuffix(ModuleFile, ".lua")+string(filepath.Separator)) {
			lastPartAt = i
		}
	}
	if entryAt == -1 || lastPartAt == -1 {
		t.Fatalf("could not find the entry (%d) or the parts (%d) in the write order", entryAt, lastPartAt)
	}
	if entryAt < lastPartAt {
		t.Errorf("the entry file was written at %d, before the last part at %d -- "+
			"an interrupted update could leave a new entry pointing at old parts",
			entryAt, lastPartAt)
	}
	t.Logf("entry written at %d of %d, after all %s parts", entryAt+1, len(written),
		strings.TrimSuffix(ModuleFile, ".lua"))
}
