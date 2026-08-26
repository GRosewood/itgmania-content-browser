package installer

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// ModuleFiles is the payload copied into Themes/<Simply Love>/Modules/.
// It is supplied by the caller so this package stays free of embed details.
type ModuleFiles fs.FS

// InstallResult describes what Apply did.
type InstallResult struct {
	ModulesDir string
	Written    []string
	Replaced   []string // superseded files removed during an upgrade
	Prefs      PrefsResult
	Helper     HelperResult
}

// HelperResult reports what was cleaned off an install that used to run the
// background helper. Earlier versions registered a login item and kept a
// binary beside Save/; the game does everything itself now, so an upgrade's
// whole job here is taking that machinery away.
type HelperResult struct {
	Removed []string
}

// legacyFiles are names shipped by earlier versions of this module. They must
// be deleted on upgrade: Simply Love loads every .lua in Modules/, so a stale
// copy alongside the current one would register the title-menu entry twice.
var legacyFiles = []string{
	"SMO Find Content.lua",
	"SMO Find Content README.md",
	// short-lived watcher-launcher experiment
	"Launch ITGmania.bat",
	"Launch ITGmania.ps1",
	"launch-itgmania.sh",
}

// removeLegacy deletes superseded files from a Modules directory and reports
// which ones were there.
func removeLegacy(modulesDir string) []string {
	var removed []string
	for _, name := range legacyFiles {
		p := filepath.Join(modulesDir, name)
		if !isFile(p) {
			continue
		}
		if err := os.Remove(p); err == nil {
			removed = append(removed, name)
		}
	}
	return removed
}

// CopyModuleFiles writes a payload into a Modules directory and reports what
// it wrote, relative to that directory.
//
// It is separate from Apply because the in-game updater uses it on its own.
// Apply also stops the loopback helper and lays down a fresh binary, which is
// exactly what an update running *inside* that helper must not do; all the
// updater wants is the files.
//
// progress, if given, is called before each file with how many have been
// written and how many there are, so a caller can draw a bar.
func CopyModuleFiles(modulesDir string, files fs.FS, progress func(done, total int)) ([]string, error) {
	return copyModuleFilesFor(modulesDir, files, progress, GameUser{})
}

// copyModuleFilesFor is CopyModuleFiles with an owner to hand the results to.
func copyModuleFilesFor(modulesDir string, files fs.FS, progress func(done, total int), owner GameUser) ([]string, error) {
	var names []string
	if err := fs.WalkDir(files, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			names = append(names, p)
		}
		return nil
	}); err != nil {
		return nil, err
	}

	var written []string
	for i, p := range names {
		if progress != nil {
			progress(i, len(names))
		}
		data, err := fs.ReadFile(files, p)
		if err != nil {
			return written, err
		}
		// Keep the layout the payload has: the tab icons live in a
		// subdirectory beside the module, and flattening them would put them
		// where nothing looks for them.
		rel := filepath.FromSlash(p)
		dest := filepath.Join(modulesDir, rel)

		// An archive off the network is walked by this same code, so refuse
		// anything that climbs out of the directory it is meant to fill.
		// fs.FS rejects such names already; this says so where it matters
		// rather than resting on that.
		if !within(modulesDir, dest) {
			return written, fmt.Errorf("refusing %s: outside %s", p, modulesDir)
		}
		if dir := filepath.Dir(dest); dir != modulesDir {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return written, fmt.Errorf("creating %s: %w", dir, err)
			}
			chownLike(dir, modulesDir)
			chownToGameUser(dir, owner)
		}

		mode := os.FileMode(0o644)
		if strings.HasSuffix(p, ".sh") {
			mode = 0o755
		}
		if err := os.WriteFile(dest, data, mode); err != nil {
			return written, fmt.Errorf("writing %s: %w", dest, err)
		}
		// Handed back to whoever owns the theme. Installing with sudo would
		// otherwise leave root-owned files that the in-game updater -- which
		// runs as the player, through the helper -- cannot replace, so the
		// browser would offer an update it could never finish.
		chownLike(dest, modulesDir)
		chownToGameUser(dest, owner)
		written = append(written, rel)
	}
	if progress != nil {
		progress(len(names), len(names))
	}
	return written, nil
}

// within reports whether path sits inside root.
func within(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// Apply copies the module payload into the install's Simply Love theme and
// makes sure the network allowlist permits the pack index.
func Apply(inst Install, files ModuleFiles) (InstallResult, error) {
	var res InstallResult

	themeDir := inst.SimplyLoveDir()
	if !isDir(themeDir) {
		return res, fmt.Errorf("Simply Love theme not found at %s", themeDir)
	}

	// A theme can be on a drive the player mounted read-only through the game's
	// own options. It loads from there perfectly well, so it is a legitimate
	// answer to "which theme is this cabinet running" and the search finds it
	// -- but nothing can be written into it, and "read-only file system" on its
	// own does not tell anybody which of the paths on screen was the problem.
	if readOnlyFS(themeDir) {
		return res, fmt.Errorf("%s is on a read-only filesystem, so the module"+
			" cannot be installed into it; remount it writable, or install into"+
			" a copy of the theme that is not read-only", themeDir)
	}

	res.ModulesDir = filepath.Join(themeDir, "Modules")
	if err := os.MkdirAll(res.ModulesDir, 0o755); err != nil {
		return res, fmt.Errorf("creating %s: %w", res.ModulesDir, err)
	}
	// a Modules/ this run had to create belongs to the theme above it -- and
	// then to the player, because replacing a file needs write permission on
	// the directory holding it, and the in-game updater runs as them
	chownLike(res.ModulesDir, themeDir)
	chownToGameUser(res.ModulesDir, inst.GameUser)

	res.Replaced = removeLegacy(res.ModulesDir)
	res.Replaced = append(res.Replaced, removeNestedModules(res.ModulesDir)...)

	written, err := copyModuleFilesFor(res.ModulesDir, files, nil, inst.GameUser)
	res.Written = written
	if err != nil {
		return res, err
	}

	prefs, err := EnsureAllowlist(inst.SaveDir)
	if err != nil {
		return res, err
	}
	res.Prefs = prefs

	// Nothing is set up any more -- the game fetches, unzips and truncates
	// for itself, and previews come from the web relay. What remains is
	// tidying away the machinery an older version left running.
	res.Helper = cleanUpOldHelper(inst)
	return res, nil
}

func cleanUpOldHelper(inst Install) HelperResult {
	var out HelperResult

	// the order matters: stop whatever may be running before touching the
	// binary it runs from, and take the registration away before the thing
	// it registers
	was := autostartInfo(inst)
	if err := UnregisterAutostart(inst); err == nil && was.Mechanism != MechNone {
		out.Removed = append(out.Removed, string(was.Mechanism))
	}
	if path, taken := UnpatchLauncher(inst); taken {
		out.Removed = append(out.Removed, "launcher line in "+filepath.Base(path))
	}
	StopHelper(inst)
	if RemoveHelperBinary(inst) {
		out.Removed = append(out.Removed, "helper binary")
	}
	// the queue file and config of helpers long gone
	_ = os.Remove(filepath.Join(HelperDir(inst), "pending-removals.txt"))
	return out
}

// Uninstall removes the module files. Preferences.ini is left alone: other
// things may rely on the hosts, and removing them is a one-line manual edit.
func Uninstall(inst Install, files ModuleFiles) ([]string, error) {
	// The theme that actually holds the module, so a fork install is cleaned
	// out of the fork rather than out of a folder that merely has the stock
	// name.
	modulesDir := filepath.Join(inst.ModuleThemeDir(), "Modules")
	removed := removeLegacy(modulesDir)

	// Take the autostart registration out first, then signal the running helper
	// to exit by removing the config file it polls for.
	//
	// What was actually there is asked BEFORE clearing it, and reported only if
	// there was something: unregisterAutostart returns nil whether or not it
	// found anything, so reporting on its error alone claimed to have removed a
	// registration that never existed -- and named a path computed from the
	// platform rather than from the machine.
	was := autostartInfo(inst)
	if err := UnregisterAutostart(inst); err == nil && was.Mechanism != MechNone {
		removed = append(removed, string(was.Mechanism)+" ("+was.Path+")")
	}
	if path, taken := UnpatchLauncher(inst); taken {
		removed = append(removed, "helper start removed from "+path)
	}
	// StopHelper waits for the process to let go of its executable, so the
	// delete below actually succeeds on Windows instead of silently failing.
	StopHelper(inst)
	if RemoveHelperBinary(inst) {
		removed = append(removed, filepath.Base(HelperBinary(inst)))
	}

	err := fs.WalkDir(files, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel := filepath.FromSlash(p)
		target := filepath.Join(modulesDir, rel)
		if !isFile(target) {
			return nil
		}
		if err := os.Remove(target); err != nil {
			return fmt.Errorf("removing %s: %w", target, err)
		}
		removed = append(removed, rel)
		// tidy away a payload subdirectory once its last file has gone
		if dir := filepath.Dir(target); dir != modulesDir {
			_ = os.Remove(dir)
		}
		return nil
	})
	if err != nil {
		return removed, err
	}

	// These folders go wholesale, not just file by file. The walk above removes
	// what THIS payload ships, and that is not the same as what is there: the
	// in-game updater never deletes anything, and the uninstaller the Windows
	// wizard runs is the copy bundled when setup.exe was last run, so its idea
	// of the payload can be several releases old. Either way a folder emptied of
	// everything except names nobody remembers would survive its own uninstall
	// forever. Both are wholly this project's, by name, so taking all of them is
	// taking ours.
	for _, name := range []string{"ITGmania Content Browser", "ContentBrowserIcons"} {
		dir := filepath.Join(modulesDir, name)
		if !isDir(dir) {
			continue
		}
		if rmErr := os.RemoveAll(dir); rmErr == nil {
			removed = append(removed, name+string(filepath.Separator)+" (leftovers)")
		}
	}

	// The browser's own working data: the helper's folder beside Save, and the
	// preview and banner cache. Neither holds a file the payload ships, so
	// neither was ever reached by the walk -- an uninstall left behind the list
	// of installed dates and however many megabytes of downloaded artwork, which
	// is not what "remove the module files" means to anybody.
	//
	// RemoveHelperBinary above has already waited for the helper to let go of
	// its executable, so by here the directory can actually be taken.
	if dir := HelperDir(inst); isDir(dir) {
		if rmErr := os.RemoveAll(dir); rmErr == nil {
			removed = append(removed, dir)
		}
	}
	if cache, cacheErr := CacheDir(inst); cacheErr == nil {
		dir := filepath.Join(cache, "ITGmaniaContentBrowser")
		if isDir(dir) {
			if rmErr := os.RemoveAll(dir); rmErr == nil {
				removed = append(removed, dir)
			}
		}
	}
	return removed, nil
}
