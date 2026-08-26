package installer

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// theme writes a theme directory with the parts detection looks at. Passing an
// empty string for either part leaves that file out.
func writeTheme(t *testing.T, themesDir, name, overlay, metrics string) {
	t.Helper()
	dir := filepath.Join(themesDir, name)
	if overlay != "" {
		if err := os.MkdirAll(filepath.Join(dir, "BGAnimations"), 0o755); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, "BGAnimations", "ScreenSystemLayer overlay.lua")
		if err := os.WriteFile(path, []byte(overlay), 0o644); err != nil {
			t.Fatal(err)
		}
	} else if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if metrics != "" {
		if err := os.WriteFile(filepath.Join(dir, "metrics.ini"), []byte(metrics), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// what a Simply Love overlay's module loader looks like, reduced to the two
// things detection keys on
const slOverlay = `
local function LoadModules()
	local files = FILEMAN:GetDirListing(THEME:GetCurrentThemeDirectory().."Modules/")
end
LoadModules()
`

const slMetrics = `
[ScreenSelectMusic]
Choice1="something else entirely"

[ScreenTitleMenu]
ChoiceNames="1,2"
Choice1="screen,ScreenSelectMusic;text,Dance Mode"
Choice2="screen,ScreenExit;text,Exit"
`

func themeFixture(t *testing.T) Install {
	t.Helper()
	root := t.TempDir()
	themes := filepath.Join(root, "Themes")
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}

	// A fork under a name nothing would have guessed.
	writeTheme(t, themes, "Zarzob Fork", slOverlay, slMetrics)
	// The stock theme.
	writeTheme(t, themes, "Simply Love", slOverlay, slMetrics)
	// A theme with a title menu but no module loader: nothing would ever run.
	writeTheme(t, themes, "Some Other Theme", "local t = Def.ActorFrame{}\n", slMetrics)
	// Simply Love's loader but no title menu to add an entry to.
	writeTheme(t, themes, "Headless", slOverlay, "[ScreenGameplay]\nFoo=1\n")
	// The engine's base theme, which is never a target.
	writeTheme(t, themes, "_fallback", slOverlay, slMetrics)

	return Install{Root: root, ThemesDir: themes, SaveDir: save}
}

func setPrefs(t *testing.T, inst Install, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(inst.SaveDir, "Preferences.ini"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCurrentThemePrefersThePerGameOverride(t *testing.T) {
	inst := themeFixture(t)
	setPrefs(t, inst, "[Options]\nTheme=Simply Love\n\n[Game-dance]\nTheme=Zarzob Fork\n")
	if got := CurrentTheme(inst.SaveDir); got != "Zarzob Fork" {
		t.Errorf("CurrentTheme = %q, want the per-game override", got)
	}

	setPrefs(t, inst, "[Options]\nTheme=Simply Love\n")
	if got := CurrentTheme(inst.SaveDir); got != "Simply Love" {
		t.Errorf("CurrentTheme = %q, want the global one", got)
	}

	setPrefs(t, inst, "[Options]\nHttpEnabled=1\n")
	if got := CurrentTheme(inst.SaveDir); got != "" {
		t.Errorf("CurrentTheme = %q, want empty when nothing says", got)
	}
}

func TestThemesJudgeOnContentNotName(t *testing.T) {
	inst := themeFixture(t)
	setPrefs(t, inst, "[Game-dance]\nTheme=Zarzob Fork\n")

	byName := map[string]Theme{}
	for _, th := range Themes(inst) {
		byName[th.Name] = th
	}

	if _, ok := byName["_fallback"]; ok {
		t.Error("the engine's base theme was offered as a target")
	}
	if th := byName["Zarzob Fork"]; !th.Compatible() || !th.Current {
		t.Errorf("a fork under an unrelated name was not recognised: %+v", th)
	}
	if th := byName["Simply Love"]; !th.Compatible() {
		t.Error("the stock theme was not recognised")
	}
	if th := byName["Some Other Theme"]; th.Compatible() {
		t.Error("a theme with no module loader was accepted")
	} else if th.Why() != "does not load Modules/" {
		t.Errorf("unhelpful reason: %q", th.Why())
	}
	if th := byName["Headless"]; th.Compatible() {
		t.Error("a theme with no title menu was accepted")
	} else if th.Why() != "no ScreenTitleMenu choices" {
		t.Errorf("unhelpful reason: %q", th.Why())
	}

	// The theme in use sorts first so it is what a default picks up.
	if first := Themes(inst)[0]; first.Name != "Zarzob Fork" {
		t.Errorf("first candidate is %q, want the theme in use", first.Name)
	}
}

func TestPickThemeDefaultsToTheOneInUse(t *testing.T) {
	inst := themeFixture(t)
	setPrefs(t, inst, "[Game-dance]\nTheme=Zarzob Fork\n")

	got, ask, err := PickTheme(Themes(inst), "")
	if err != nil || ask {
		t.Fatalf("PickTheme = %v, ask=%v, err=%v", got.Name, ask, err)
	}
	if got.Name != "Zarzob Fork" {
		t.Errorf("picked %q, want the theme in use", got.Name)
	}
}

func TestPickThemeAsksWhenTheChoiceIsAPreference(t *testing.T) {
	inst := themeFixture(t)
	// Nothing in use, and two themes could take it.
	setPrefs(t, inst, "[Options]\nHttpEnabled=1\n")

	_, ask, err := PickTheme(Themes(inst), "")
	if err != nil {
		t.Fatalf("PickTheme: %v", err)
	}
	if !ask {
		t.Error("picked silently between two equally good themes")
	}
}

func TestPickThemeHonoursAndValidatesAnExplicitName(t *testing.T) {
	inst := themeFixture(t)
	setPrefs(t, inst, "[Game-dance]\nTheme=Zarzob Fork\n")
	themes := Themes(inst)

	got, ask, err := PickTheme(themes, "simply love") // case-insensitive
	if err != nil || ask || got.Name != "Simply Love" {
		t.Errorf("explicit name: got %q ask=%v err=%v", got.Name, ask, err)
	}

	if _, _, err := PickTheme(themes, "Some Other Theme"); err == nil {
		t.Error("accepted a theme the module cannot run under")
	}
	if _, _, err := PickTheme(themes, "Nonexistent"); err == nil {
		t.Error("accepted a theme that is not there")
	}
}

func TestPickThemeReportsWhenNothingWillDo(t *testing.T) {
	root := t.TempDir()
	themes := filepath.Join(root, "Themes")
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTheme(t, themes, "Plain Theme", "local t = Def.ActorFrame{}\n", "[ScreenTitleMenu]\nChoice1=\"x\"\n")
	inst := Install{Root: root, ThemesDir: themes, SaveDir: save}

	if _, _, err := PickTheme(Themes(inst), ""); err == nil {
		t.Fatal("claimed an install with no usable theme was fine")
	}
	if len(CompatibleThemes(inst)) != 0 {
		t.Error("found a compatible theme where there is none")
	}
}

// The engine mounts <profile>/Themes over the install's own (ArchHooks_Unix.cpp
// mounts sUserDataPath+"/Themes" at "/Themes"; the other platforms do the same
// for their profile directories). On a Linux cabinet the game is in /opt owned
// by root, so a theme the player adds goes in their profile -- and a theme list
// built only from the install directory cannot see it. The theme in use was
// then never found, and the module went into whichever theme sorted first.
func TestThemesIncludesTheProfileAndPrefersIt(t *testing.T) {
	root := t.TempDir()
	profile := t.TempDir()

	installThemes := filepath.Join(root, "Themes")
	profileThemes := filepath.Join(profile, "Themes")
	const overlay = `local f = FILEMAN:GetDirListing("Modules/")`
	const metrics = `[ScreenTitleMenu]
Choice1="screen,ScreenExit"
`
	writeTheme(t, installThemes, "Simply Love", overlay, metrics)
	writeTheme(t, profileThemes, "Simply Love-SM5", overlay, metrics)
	// the same name in both: the profile copy is the one the game loads
	writeTheme(t, installThemes, "Shared", overlay, metrics)
	writeTheme(t, profileThemes, "Shared", overlay, metrics)

	save := filepath.Join(profile, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(save, "Preferences.ini"),
		[]byte("[Options]\nTheme=Simply Love-SM5\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	inst := Install{Root: root, ThemesDir: installThemes, SaveDir: save}

	var sm5 *Theme
	shared := 0
	for i := range Themes(inst) {
		th := Themes(inst)[i]
		if th.Name == "Simply Love-SM5" {
			t2 := th
			sm5 = &t2
		}
		if th.Name == "Shared" {
			shared++
			if !strings.HasPrefix(th.Path, profileThemes) {
				t.Errorf("Shared resolved to %q, want the profile copy", th.Path)
			}
		}
	}
	if sm5 == nil {
		t.Fatal("the theme in the player's profile was not listed at all")
	}
	if !sm5.Current {
		t.Error("the theme named in Preferences.ini was not marked as in use")
	}
	if shared != 1 {
		t.Errorf("a theme present in both places was listed %d times, want 1", shared)
	}

	// ...and that is where the module must go.
	if got := inst.SimplyLoveDir(); got != filepath.Join(profileThemes, "Simply Love-SM5") {
		t.Errorf("SimplyLoveDir = %q, want the profile's Simply Love-SM5", got)
	}
}
