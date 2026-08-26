package installer

import (
	"os"
	"path/filepath"
	"testing"
)

// mounted builds the layout a Linux cabinet actually has: the game installed
// somewhere central, and the song library on a drive the player mounted through
// the game's own preferences.
//
// The two kinds of mount go to different places in the engine
// (StepMania.cpp):
//
//	AdditionalSongFolders -> /Songs   the folder holds packs directly
//	AdditionalFolders     -> /        the folder is a whole tree; packs are in Songs/
//
// Both end up merged into /Songs as far as the game is concerned, which is why
// a player sees no difference and this code has to know about both.
func mounted(t *testing.T, key, packName string) (Install, string) {
	t.Helper()
	root := t.TempDir()
	drive := t.TempDir()

	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(filepath.Join(root, "Songs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}

	// where the pack really is, for each kind of mount
	packRoot := drive
	if key == "AdditionalFolders" {
		packRoot = filepath.Join(drive, "Songs")
	}
	pack := filepath.Join(packRoot, packName)
	if err := os.MkdirAll(filepath.Join(pack, "A Song"), 0o755); err != nil {
		t.Fatal(err)
	}

	prefs := "[Options]\n" + key + "=" + filepath.ToSlash(drive) + "\n"
	if err := os.WriteFile(filepath.Join(save, "Preferences.ini"), []byte(prefs), 0o644); err != nil {
		t.Fatal(err)
	}

	return Install{Root: root, SaveDir: save, ThemesDir: filepath.Join(root, "Themes")}, pack
}

// Deleting a pack that lives on a mounted drive. This failed for the tree
// mounted at the game's root: the browser listed the pack, because the engine
// merges both mounts into /Songs, and then removal could not find it.
func TestRemovePackFindsAPackOnEitherKindOfMount(t *testing.T) {
	for _, key := range []string{"AdditionalSongFolders", "AdditionalFolders"} {
		t.Run(key, func(t *testing.T) {
			inst, pack := mounted(t, key, "Mounted Pack")

			got, err := RemovePack(inst, "Mounted Pack")
			if err != nil {
				t.Fatalf("RemovePack: %v", err)
			}
			if got != pack {
				t.Errorf("removed %q, want %q", got, pack)
			}
			if _, err := os.Stat(pack); !os.IsNotExist(err) {
				t.Errorf("the pack is still there: %v", err)
			}
		})
	}
}

// And downloading one back to the same place. This is the other half of the
// same bug: the install root only ever considered AdditionalSongFolders, so on
// a cabinet whose library is a mounted tree the download fell back to the
// install's own Songs -- which is root-owned, and refuses.
func TestInstallRootPrefersEitherKindOfMountOverTheInstall(t *testing.T) {
	for _, key := range []string{"AdditionalSongFolders", "AdditionalFolders"} {
		t.Run(key, func(t *testing.T) {
			inst, pack := mounted(t, key, "Mounted Pack")
			want := filepath.Dir(pack)

			got, err := InstallRoot(inst)
			if err != nil {
				t.Fatalf("InstallRoot: %v", err)
			}
			if got != want {
				t.Errorf("InstallRoot = %q, want %q", got, want)
			}
		})
	}
}

// A pack can be deleted from exactly the places one can be downloaded to. Any
// gap between the two lists is a player who can remove a pack and then not put
// it back, which is the shape both halves of this bug had.
func TestEveryInstallRootIsAlsoASongRoot(t *testing.T) {
	for _, key := range []string{"AdditionalSongFolders", "AdditionalFolders"} {
		t.Run(key, func(t *testing.T) {
			inst, _ := mounted(t, key, "Mounted Pack")

			song := map[string]bool{}
			for _, dir := range SongRoots(inst) {
				song[dir] = true
			}
			roots := InstallRoots(inst)
			if len(roots) == 0 {
				t.Fatal("no install roots at all")
			}
			for _, dir := range roots {
				if !song[dir] {
					t.Errorf("%q can be downloaded to but not deleted from", dir)
				}
			}
		})
	}
}

// The configured folder wins over the install's own Songs -- a player who set
// one said where their library belongs.
func TestInstallRootPutsConfiguredFoldersFirst(t *testing.T) {
	inst, pack := mounted(t, "AdditionalFolders", "Mounted Pack")
	roots := InstallRoots(inst)
	if len(roots) == 0 {
		t.Fatal("no install roots")
	}
	if roots[0] != filepath.Dir(pack) {
		t.Errorf("first install root = %q, want the configured %q", roots[0], filepath.Dir(pack))
	}
	for _, dir := range roots {
		if dir == filepath.Join(inst.Root, "Songs") {
			t.Error("the install's own Songs is in InstallRoots; it is the fallback, not a candidate")
		}
	}
}

// With nothing configured there is nothing to prefer, and the fallback stands.
func TestInstallRootFallsBackToTheInstallsOwnSongs(t *testing.T) {
	inst := fixture(t)
	got, err := InstallRoot(inst)
	if err != nil {
		t.Fatalf("InstallRoot: %v", err)
	}
	if want := filepath.Join(inst.Root, "Songs"); got != want {
		t.Errorf("InstallRoot = %q, want %q", got, want)
	}
}

// A drive that is configured but not plugged in must not be chosen: the
// directory is simply absent, and picking it would fail halfway through an
// unzip rather than falling back cleanly.
func TestInstallRootSkipsAMountThatIsNotThere(t *testing.T) {
	root := t.TempDir()
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}
	gone := filepath.Join(t.TempDir(), "not-plugged-in")
	prefs := "[Options]\nAdditionalFolders=" + filepath.ToSlash(gone) + "\n"
	if err := os.WriteFile(filepath.Join(save, "Preferences.ini"), []byte(prefs), 0o644); err != nil {
		t.Fatal(err)
	}
	inst := Install{Root: root, SaveDir: save, ThemesDir: filepath.Join(root, "Themes")}

	if roots := InstallRoots(inst); len(roots) != 0 {
		t.Errorf("InstallRoots = %v, want none for an absent drive", roots)
	}
	got, err := InstallRoot(inst)
	if err != nil {
		t.Fatalf("InstallRoot: %v", err)
	}
	if want := filepath.Join(root, "Songs"); got != want {
		t.Errorf("InstallRoot = %q, want the fallback %q", got, want)
	}
}
