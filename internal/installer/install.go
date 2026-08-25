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

// HelperResult reports how the loopback delete helper was set up. A failure
// here is not fatal: everything except in-game pack removal still works.
type HelperResult struct {
	Binary    string
	Autostart string
	Running   bool
	Err       error
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

	res.ModulesDir = filepath.Join(themeDir, "Modules")
	if err := os.MkdirAll(res.ModulesDir, 0o755); err != nil {
		return res, fmt.Errorf("creating %s: %w", res.ModulesDir, err)
	}
	// a Modules/ this run had to create belongs to the theme above it
	chownLike(res.ModulesDir, themeDir)

	res.Replaced = removeLegacy(res.ModulesDir)

	written, err := CopyModuleFiles(res.ModulesDir, files, nil)
	res.Written = written
	if err != nil {
		return res, err
	}

	prefs, err := EnsureAllowlist(inst.SaveDir)
	if err != nil {
		return res, err
	}
	res.Prefs = prefs

	// The loopback helper is what makes in-game pack deletion possible at all.
	// It is best-effort: if any of this fails the browser still works, and the
	// Installed Packs screen says removal is unavailable rather than lying.
	res.Helper = setUpHelper(inst)
	return res, nil
}

func setUpHelper(inst Install) HelperResult {
	var out HelperResult

	// An older helper may be running and holding its own binary open.
	StopHelper(inst)

	// Removal used to be a queue the player had to apply from the desktop.
	// It is done in-game now, so the leftover queue file only confuses.
	_ = os.Remove(filepath.Join(HelperDir(inst), "pending-removals.txt"))

	bin, err := InstallHelperBinary(inst)
	if err != nil {
		out.Err = err
		return out
	}
	out.Binary = bin

	if err := RegisterAutostart(inst); err != nil {
		out.Err = err
		return out
	}
	out.Autostart = AutostartDescription(inst)

	// Start it now so the feature works before the next login.
	if err := StartHelper(inst); err != nil {
		out.Err = err
		return out
	}
	out.Running = true
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

	// The parts folder goes wholesale, not just file by file. The walk above
	// removes what THIS payload ships, but the in-game updater never deletes
	// anything, so a machine that has been through a release which renamed a
	// part still holds the old name -- and a folder emptied of everything
	// except orphans would survive its own uninstall forever. The folder is
	// wholly this project's, by name, so taking all of it is taking ours.
	partsDir := filepath.Join(modulesDir, "ITGmania Content Browser")
	if isDir(partsDir) {
		if rmErr := os.RemoveAll(partsDir); rmErr == nil {
			removed = append(removed, "ITGmania Content Browser"+string(filepath.Separator)+" (leftover parts)")
		}
	}
	return removed, nil
}
