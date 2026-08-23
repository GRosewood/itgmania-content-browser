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

	res.Replaced = removeLegacy(res.ModulesDir)

	err := fs.WalkDir(files, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		data, err := fs.ReadFile(files, p)
		if err != nil {
			return err
		}
		// Keep the layout the payload has: the tab icons live in a
		// subdirectory beside the module, and flattening them would put them
		// where nothing looks for them.
		rel := filepath.FromSlash(p)
		dest := filepath.Join(res.ModulesDir, rel)
		if dir := filepath.Dir(dest); dir != res.ModulesDir {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return fmt.Errorf("creating %s: %w", dir, err)
			}
		}

		mode := os.FileMode(0o644)
		if strings.HasSuffix(p, ".sh") {
			mode = 0o755
		}
		if err := os.WriteFile(dest, data, mode); err != nil {
			return fmt.Errorf("writing %s: %w", dest, err)
		}
		res.Written = append(res.Written, rel)
		return nil
	})
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
	modulesDir := filepath.Join(inst.SimplyLoveDir(), "Modules")
	removed := removeLegacy(modulesDir)

	// Take the login item out first, then signal the running helper to exit by
	// removing the config file it polls for.
	where := AutostartDescription(inst)
	if err := UnregisterAutostart(inst); err == nil {
		removed = append(removed, "login item ("+where+")")
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
	return removed, err
}
