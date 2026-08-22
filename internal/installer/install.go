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
	Prefs      PrefsResult
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
		name := filepath.Base(p)
		dest := filepath.Join(res.ModulesDir, name)

		mode := os.FileMode(0o644)
		if strings.HasSuffix(name, ".sh") {
			mode = 0o755
		}
		if err := os.WriteFile(dest, data, mode); err != nil {
			return fmt.Errorf("writing %s: %w", dest, err)
		}
		res.Written = append(res.Written, name)
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
	return res, nil
}

// Uninstall removes the module files. Preferences.ini is left alone: other
// things may rely on the hosts, and removing them is a one-line manual edit.
func Uninstall(inst Install, files ModuleFiles) ([]string, error) {
	modulesDir := filepath.Join(inst.SimplyLoveDir(), "Modules")
	var removed []string

	err := fs.WalkDir(files, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		name := filepath.Base(p)
		target := filepath.Join(modulesDir, name)
		if !isFile(target) {
			return nil
		}
		if err := os.Remove(target); err != nil {
			return fmt.Errorf("removing %s: %w", target, err)
		}
		removed = append(removed, name)
		return nil
	})
	return removed, err
}
