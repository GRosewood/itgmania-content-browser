package installer

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

// link makes dir-link point at target, as a symlink where the platform allows
// and as an NTFS junction on a Windows box without symlink privilege. A
// junction resolves through EvalSymlinks the same way, which is the property
// under test.
func link(t *testing.T, target, name string) {
	t.Helper()
	if err := os.Symlink(target, name); err == nil {
		return
	} else if runtime.GOOS != "windows" {
		t.Fatal(err)
	}
	out, err := exec.Command("cmd", "/c", "mklink", "/J", name, target).CombinedOutput()
	if err != nil {
		t.Skipf("no symlink privilege and mklink /J failed: %v (%s)", err, out)
	}
}

// The Cache directory sits beside Save in every layout the engine mounts, so
// resolving it is one Dir() from the already-resolved SaveDir -- but cabinets
// point it at mounted drives through symlinks, and that is the case that has
// to actually work.
func TestCacheDirIsTheSiblingOfSave(t *testing.T) {
	root := t.TempDir()
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := CacheDir(Install{SaveDir: save})
	if err != nil {
		t.Fatalf("CacheDir: %v", err)
	}
	// t.TempDir can itself sit behind a symlink (macOS /var -> /private/var),
	// so compare resolved to resolved.
	want, _ := filepath.EvalSymlinks(filepath.Join(root, "Cache"))
	if got != want {
		t.Errorf("CacheDir = %q, want %q", got, want)
	}
	if fi, err := os.Stat(got); err != nil || !fi.IsDir() {
		t.Errorf("the Cache directory was not created: %v", err)
	}
}

func TestCacheDirFollowsASymlinkToAMountedDrive(t *testing.T) {
	root := t.TempDir()
	save := filepath.Join(root, "Save")
	drive := filepath.Join(root, "big-drive", "itg-cache")
	for _, d := range []string{save, drive} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	link(t, drive, filepath.Join(root, "Cache"))

	got, err := CacheDir(Install{SaveDir: save})
	if err != nil {
		t.Fatalf("CacheDir: %v", err)
	}
	want, _ := filepath.EvalSymlinks(drive)
	if got != want {
		t.Errorf("CacheDir = %q, want the symlink's target %q", got, want)
	}
}

// A symlink to a drive that is not mounted is the cabinet failure mode: the
// pointer exists, the target does not. That must come back as an error, not as
// a fresh directory quietly shadowing the mount point.
func TestCacheDirRefusesADanglingSymlink(t *testing.T) {
	root := t.TempDir()
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}
	link(t, filepath.Join(root, "not-mounted"), filepath.Join(root, "Cache"))

	if got, err := CacheDir(Install{SaveDir: save}); err == nil {
		t.Errorf("CacheDir = %q, want an error for a dangling symlink", got)
	}
}

func TestCacheDirNeedsASaveDir(t *testing.T) {
	if got, err := CacheDir(Install{}); err == nil {
		t.Errorf("CacheDir = %q, want an error with no SaveDir", got)
	}
}

// A fork install must be updated inside the fork. ModuleThemeDir finds the
// module rather than trusting the stock theme name, believing the theme
// Preferences.ini names when it holds the module.
func TestModuleThemeDirFindsTheFork(t *testing.T) {
	root := t.TempDir()
	themes := filepath.Join(root, "Themes")
	save := filepath.Join(root, "Save")
	fork := filepath.Join(themes, "Simply Cool")
	stock := filepath.Join(themes, "Simply Love")
	for _, d := range []string{save, filepath.Join(fork, "Modules"), stock} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	module := filepath.Join(fork, "Modules", "ITGmania Content Browser.lua")
	if err := os.WriteFile(module, []byte("-- the module\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	prefs := "[Options]\nTheme=Simply Cool\n"
	if err := os.WriteFile(filepath.Join(save, "Preferences.ini"), []byte(prefs), 0o644); err != nil {
		t.Fatal(err)
	}

	inst := Install{ThemesDir: themes, SaveDir: save}
	if got := inst.ModuleThemeDir(); got != fork {
		t.Errorf("ModuleThemeDir = %q, want the fork %q", got, fork)
	}

	// Without the preference it still finds the module by looking.
	if err := os.Remove(filepath.Join(save, "Preferences.ini")); err != nil {
		t.Fatal(err)
	}
	if got := inst.ModuleThemeDir(); got != fork {
		t.Errorf("ModuleThemeDir without prefs = %q, want the fork %q", got, fork)
	}

	// With no module installed anywhere, fall back to where an install would go.
	if err := os.Remove(module); err != nil {
		t.Fatal(err)
	}
	if got := inst.ModuleThemeDir(); got != stock {
		t.Errorf("ModuleThemeDir with nothing installed = %q, want %q", got, stock)
	}
}
