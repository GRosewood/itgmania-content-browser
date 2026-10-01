package installer

// The layout that broke: the game installed centrally, and the theme it
// actually draws sitting on a drive the player mounted through the game's own
// options. Only the install and the profile were searched, so the live theme
// could not be found -- and the module went into the install's stock copy
// while the installer said it had succeeded.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mountedTheme builds an install whose live theme is on a mounted tree.
// The tree is mounted at the game's root, so its Themes/ lands on /Themes the
// same way its Songs/ lands on /Songs.
func mountedTheme(t *testing.T, name, key string) (Install, string) {
	t.Helper()
	root := t.TempDir()
	drive := t.TempDir()

	themes := filepath.Join(root, "Themes")
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}
	// the install's own stock copy: compatible, and not the one being played
	writeTheme(t, themes, "Simply Love", slOverlay, slMetrics)
	// the live one, out on the drive
	writeTheme(t, filepath.Join(drive, "Themes"), name, slOverlay, slMetrics)

	inst := Install{Root: root, ThemesDir: themes, SaveDir: save}
	setPrefs(t, inst, "[Options]\nTheme="+name+"\n"+key+"="+drive+"\n")
	return inst, filepath.Join(drive, "Themes", name)
}

func TestThemeOnAMountedTreeIsFound(t *testing.T) {
	for _, key := range []string{
		"AdditionalFoldersWritable",
		"AdditionalFoldersReadOnly", // a theme only has to be readable to load
		"AdditionalFolders",
	} {
		t.Run(key, func(t *testing.T) {
			inst, want := mountedTheme(t, "Cabinet Love", key)

			got, ask, err := PickTheme(Themes(inst), "", CurrentTheme(inst.SaveDir))
			if err != nil {
				t.Fatalf("PickTheme: %v", err)
			}
			if ask {
				t.Error("asked, when the theme in use was right there to be found")
			}
			if got.Path != want {
				t.Errorf("installed into %s, want the mounted copy %s", got.Path, want)
			}
			if !got.Current {
				t.Error("did not recognise the mounted theme as the one in use")
			}
		})
	}
}

// ModuleThemeDir is the updater's question -- "where is the module now?" -- and
// it has to reach the mounted copy too, or an update rewrites a theme nobody
// is running and reports success.
func TestUpdateFindsTheModuleOnAMountedTree(t *testing.T) {
	inst, themeDir := mountedTheme(t, "Cabinet Love", "AdditionalFoldersWritable")
	mods := filepath.Join(themeDir, "Modules")
	if err := os.MkdirAll(mods, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(mods, "ITGmania Content Browser.lua")
	if err := os.WriteFile(path, []byte("-- module\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := inst.ModuleThemeDir(); got != themeDir {
		t.Errorf("update would write to %s, but the module is in %s", got, themeDir)
	}
}

// Same name, two directories. The install's copy is the one this can speak
// for, but the other has to be reported: writing into the wrong copy of a
// theme is completely silent otherwise.
func TestSameThemeNameInTwoPlacesIsReported(t *testing.T) {
	inst, mounted := mountedTheme(t, "Simply Love", "AdditionalFoldersWritable")

	var sl Theme
	for _, th := range Themes(inst) {
		if strings.EqualFold(th.Name, "Simply Love") {
			sl = th
		}
	}
	if sl.Name == "" {
		t.Fatal("Simply Love went missing entirely")
	}
	if len(sl.AlsoIn) != 1 || sl.AlsoIn[0] != mounted {
		t.Errorf("AlsoIn = %v, want the mounted copy %s", sl.AlsoIn, mounted)
	}
	// and it is still one entry, not two themes with the same name
	n := 0
	for _, th := range Themes(inst) {
		if strings.EqualFold(th.Name, "Simply Love") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("listed the same theme %d times", n)
	}
}

// The case with no good answer: Preferences.ini names a theme that is nowhere
// this installer can see. Taking the only compatible theme left is exactly the
// wrong move, and doing it without a word is how this went unnoticed.
func TestConfiguredThemeThatIsNowhereRefusesToPickSilently(t *testing.T) {
	root := t.TempDir()
	themes := filepath.Join(root, "Themes")
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTheme(t, themes, "Simply Love", slOverlay, slMetrics)
	inst := Install{Root: root, ThemesDir: themes, SaveDir: save}
	// mounted somewhere this installer was never told about
	setPrefs(t, inst, "[Options]\nTheme=Cabinet Love\n")

	found := Themes(inst)
	if ThemeListed(found, "Cabinet Love") {
		t.Fatal("fixture is wrong: the theme should not be findable")
	}
	_, ask, err := PickTheme(found, "", CurrentTheme(inst.SaveDir))
	if err != nil {
		t.Fatalf("PickTheme: %v", err)
	}
	if !ask {
		t.Error("silently picked the only compatible theme, which is known to be the wrong one")
	}
}

// The way out of a same-name collision: name the directory, not the theme.
// Without it a player with "Simply Love" in two roots has no way to say which
// one they mean short of renaming a theme.
func TestExplicitThemePathBeatsAnAmbiguousName(t *testing.T) {
	inst, mounted := mountedTheme(t, "Simply Love", "AdditionalFoldersWritable")

	got, ask, err := PickTheme(Themes(inst), mounted, CurrentTheme(inst.SaveDir))
	if err != nil || ask {
		t.Fatalf("by path: ask=%v err=%v", ask, err)
	}
	if got.Path != mounted {
		t.Errorf("got %s, want the copy that was asked for: %s", got.Path, mounted)
	}

	// and a path that is not there is refused rather than fallen back on
	if _, _, err := PickTheme(Themes(inst), filepath.Join(inst.Root, "Themes", "Nope"), ""); err == nil {
		t.Error("accepted a theme directory that does not exist")
	}
}

// A non-portable install after an in-game update. On Windows the game mounts
// its own folder read-only, so the update could only write into the profile,
// and it left a "Simply Love" there holding nothing but Modules. The engine
// reads that and the install's copy as one theme, file by file; judged alone,
// the profile copy was "not a Simply Love theme" and nothing could install.
func TestPartialProfileCopyIsJudgedWithTheCopyUnderIt(t *testing.T) {
	for _, tc := range []struct {
		name           string
		profileOverlay string // the profile copy's own loader, "" for none
		wantOK         bool
	}{
		{"only Modules in the profile copy", "", true},
		// a loader in the profile copy is the one the game reads, so it is
		// the one judged, whatever the copy under it has
		{"profile copy replaces the loader with one that loads nothing", "local t = Def.ActorFrame{}\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root, home := t.TempDir(), t.TempDir()
			themes := filepath.Join(root, "Themes")
			save := filepath.Join(home, "Save")
			if err := os.MkdirAll(save, 0o755); err != nil {
				t.Fatal(err)
			}
			writeTheme(t, themes, "Simply Love", slOverlay, slMetrics)
			profileTheme := filepath.Join(home, "Themes", "Simply Love")
			writeTheme(t, filepath.Join(home, "Themes"), "Simply Love", tc.profileOverlay, "")
			mods := filepath.Join(profileTheme, "Modules")
			if err := os.MkdirAll(mods, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(mods, "ITGmania Content Browser.lua"), []byte("-- module\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			inst := Install{Root: root, ThemesDir: themes, SaveDir: save}
			setPrefs(t, inst, "[Options]\nTheme=Simply Love\n")

			got, _, err := PickTheme(Themes(inst), "", CurrentTheme(inst.SaveDir))
			if !tc.wantOK {
				if err == nil {
					t.Fatalf("chose %s, but the loader the game reads there loads nothing", got.Path)
				}
				return
			}
			if err != nil {
				t.Fatalf("PickTheme: %v", err)
			}
			if got.Path != profileTheme {
				t.Errorf("installing into %s, want the profile copy %s, which the game reads first", got.Path, profileTheme)
			}
			if !got.Installed {
				t.Error("the module already in the profile copy went unseen")
			}
			if len(got.AlsoIn) != 1 || got.AlsoIn[0] != filepath.Join(themes, "Simply Love") {
				t.Errorf("AlsoIn = %v, want the install's own copy", got.AlsoIn)
			}
			if dir := inst.ModuleThemeDir(); dir != profileTheme {
				t.Errorf("an update would write to %s, want %s", dir, profileTheme)
			}
		})
	}
}
