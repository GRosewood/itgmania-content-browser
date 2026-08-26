package installer

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writePrefs puts a Preferences.ini in dir, stamped at the given age.
func writePrefs(t *testing.T, dir string, age time.Duration) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "Preferences.ini")
	if err := os.WriteFile(path, []byte("[Options]\nTheme=Simply Love\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	when := time.Now().Add(-age)
	if err := os.Chtimes(path, when, when); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestPickSaveDirTakesTheOneThatExists(t *testing.T) {
	root := t.TempDir()
	local := filepath.Join(root, "Save")
	user := filepath.Join(root, "profile", "Save")

	// Only the profile has one: a normal system-wide install.
	writePrefs(t, user, 0)
	got, found := pickSaveDir(local, []string{user})
	if !found || got != user {
		t.Errorf("with only a profile: got %q found=%v, want %q true", got, found, user)
	}

	// Only the install has one: a portable copy.
	root2 := t.TempDir()
	local2 := filepath.Join(root2, "Save")
	user2 := filepath.Join(root2, "profile", "Save")
	writePrefs(t, local2, 0)
	got, found = pickSaveDir(local2, []string{user2})
	if !found || got != local2 {
		t.Errorf("with only a portable Save: got %q found=%v, want %q true", got, found, local2)
	}
}

func TestPickSaveDirTakesTheNewerWhenBothExist(t *testing.T) {
	root := t.TempDir()
	local := filepath.Join(root, "Save")
	user := filepath.Join(root, "profile", "Save")

	// A stale portable copy beside a profile in daily use. The engine rewrites
	// the whole file on exit, so the recent one is the one being played.
	writePrefs(t, local, 30*24*time.Hour)
	writePrefs(t, user, time.Minute)

	got, found := pickSaveDir(local, []string{user})
	if !found || got != user {
		t.Errorf("got %q found=%v, want the newer %q", got, found, user)
	}

	// ...and the other way round.
	root2 := t.TempDir()
	local2 := filepath.Join(root2, "Save")
	user2 := filepath.Join(root2, "profile", "Save")
	writePrefs(t, local2, time.Minute)
	writePrefs(t, user2, 30*24*time.Hour)

	got, found = pickSaveDir(local2, []string{user2})
	if !found || got != local2 {
		t.Errorf("got %q found=%v, want the newer %q", got, found, local2)
	}
}

func TestPickSaveDirSaysWhenThereIsNoneYet(t *testing.T) {
	root := t.TempDir()
	local := filepath.Join(root, "Save")
	user := filepath.Join(root, "profile", "Save")

	got, found := pickSaveDir(local, []string{user})
	if found {
		t.Error("reported a Preferences.ini where there is none")
	}
	// A first run will make one in the profile, so that is where to aim.
	if got != user {
		t.Errorf("got %q, want %q", got, user)
	}

	// With no profile at all, the install's own Save is the only candidate.
	got, found = pickSaveDir(local, nil)
	if found || got != local {
		t.Errorf("with no profile: got %q found=%v, want %q false", got, found, local)
	}
}

func TestInspectReportsWhetherPrefsWereFound(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{"Themes", "Program"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// An install is identified by having the game in it, so the fixture needs
	// one. Directory names alone also describe the profile ITGmania keeps
	// beside the install, which is not an install.
	if err := os.WriteFile(filepath.Join(root, "Program", "ITGmania.exe"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	// Portable.ini makes the local Save definitive, marker or not.
	if err := os.WriteFile(filepath.Join(root, "Portable.ini"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	inst, ok := Inspect(root)
	if !ok {
		t.Fatal("did not recognise the install")
	}
	if !inst.Portable {
		t.Error("Portable.ini did not make it portable")
	}
	if inst.PrefsFound {
		t.Error("claimed a Preferences.ini that is not there")
	}

	writePrefs(t, filepath.Join(root, "Save"), 0)
	inst, _ = Inspect(root)
	if !inst.PrefsFound {
		t.Error("did not notice the Preferences.ini")
	}
}

func TestPickSaveDirScansPastRootsOwnProfile(t *testing.T) {
	// The sudo su - case: the shell's own profile has nothing, and the machine
	// the game is actually played on is somebody else's home. Whichever holds a
	// Preferences.ini is the answer, whatever order the candidates arrive in.
	root := t.TempDir()
	local := filepath.Join(root, "Save")
	rootProfile := filepath.Join(root, "root", ".itgmania", "Save")
	player := filepath.Join(root, "home", "cab", ".itgmania", "Save")

	writePrefs(t, player, time.Minute)

	got, found := pickSaveDir(local, []string{rootProfile, player})
	if !found || got != player {
		t.Errorf("got %q found=%v, want the player's %q", got, found, player)
	}
}

func TestPickSaveDirPrefersTheFreshestAcrossProfiles(t *testing.T) {
	// Two accounts have played on this machine. The one that played most
	// recently is the one whose settings the game is writing.
	root := t.TempDir()
	local := filepath.Join(root, "Save")
	old := filepath.Join(root, "home", "olduser", ".itgmania", "Save")
	live := filepath.Join(root, "home", "cab", ".itgmania", "Save")

	writePrefs(t, old, 90*24*time.Hour)
	writePrefs(t, live, time.Hour)

	got, found := pickSaveDir(local, []string{old, live})
	if !found || got != live {
		t.Errorf("got %q found=%v, want the freshest %q", got, found, live)
	}
}

// ITGmania mirrors its layout into the player's profile: ~/.itgmania holds
// Save/, Cache/, Songs/, Themes/ and NoteSkins/ as well. Matching on those
// names reported one copy of the game as two installs, and choosing the
// profile gave an empty theme list and the wrong answer about the theme in
// use. Only the copy with the executable in it is an install.
func TestProfileDirectoryIsNotAnInstall(t *testing.T) {
	profile := t.TempDir()
	for _, dir := range []string{"Themes", "NoteSkins", "Songs", "Save", "Cache"} {
		if err := os.MkdirAll(filepath.Join(profile, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok := Inspect(profile); ok {
		t.Fatal("a profile directory was reported as an ITGmania installation")
	}

	// The same tree with the game in it is one.
	if err := os.MkdirAll(filepath.Join(profile, "Program"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profile, "Program", "ITGmania.exe"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, ok := Inspect(profile); !ok {
		t.Fatal("a real install was not recognised")
	}
}

// The Linux layout has the binary at the top, beside Themes/ -- which is what
// ITGmania's own desktop entry points at (TryExec=/opt/itgmania/itgmania).
func TestLinuxInstallIsRecognisedByItsBinary(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{"Themes", "NoteSkins"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok := Inspect(root); ok {
		t.Fatal("recognised an install with no game in it")
	}
	if err := os.WriteFile(filepath.Join(root, "itgmania"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, ok := Inspect(root); !ok {
		t.Fatal("did not recognise a Linux install by its binary")
	}
}
