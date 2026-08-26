package installer

// Theme discovery.
//
// The module is a Simply Love add-on, but "Simply Love" is not the only theme
// it runs under: the forks people actually play on -- ArrowCloud's build,
// Zarzob's, someone's personal rename -- are Simply Love underneath and load
// modules the same way. Matching on the folder name found the original and
// missed every one of them.
//
// So a theme is judged on what it can do rather than what it is called. Two
// things have to be true, and both are things the module would fail on:
//
//   - Its ScreenSystemLayer overlay loads Modules/. This is the whole hook: the
//     theme walks that directory, runs each .lua, and attaches what comes back
//     to the system layer. Without it the module is a file nothing ever reads.
//   - Its metrics declare ScreenTitleMenu choices. The module reads those to
//     add its own entry to the title menu; a theme without them has no menu to
//     add to, and asking for a metric that is not there is an error, not an
//     empty string.
//
// Everything else the module touches -- the loading spinner graphic, the menu
// sounds -- falls back to the engine's own copy when a theme lacks it, so those
// are worth reporting but not worth refusing over.

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Theme is one theme directory and what it can do.
type Theme struct {
	Name      string // the directory name, as shown to the player
	Path      string // full path to the theme directory
	Modules   bool   // its system-layer overlay loads Modules/
	TitleMenu bool   // its metrics declare ScreenTitleMenu choices
	Current   bool   // the theme this install is actually set to use
	Installed bool   // the module is already in this theme
}

// Compatible reports whether the module would run under this theme.
func (t Theme) Compatible() bool { return t.Modules && t.TitleMenu }

// Why explains a refusal, for a listing that would otherwise just say no.
func (t Theme) Why() string {
	switch {
	case t.Compatible():
		return ""
	case !t.Modules && !t.TitleMenu:
		return "not a Simply Love theme"
	case !t.Modules:
		return "does not load Modules/"
	default:
		return "no ScreenTitleMenu choices"
	}
}

// themeLoadsModules reports whether a theme walks its own Modules directory.
func themeLoadsModules(dir string) bool {
	data, err := os.ReadFile(filepath.Join(dir, "BGAnimations", "ScreenSystemLayer overlay.lua"))
	if err != nil {
		return false
	}
	body := string(data)
	return strings.Contains(body, "Modules/") && strings.Contains(body, "GetDirListing")
}

// themeHasTitleChoices reports whether metrics.ini declares the title menu the
// module adds itself to. Only the [ScreenTitleMenu] section counts: plenty of
// other screens have Choice keys of their own.
func themeHasTitleChoices(dir string) bool {
	data, err := os.ReadFile(filepath.Join(dir, "metrics.ini"))
	if err != nil {
		return false
	}
	inSection := false
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			inSection = strings.EqualFold(line, "[ScreenTitleMenu]")
			continue
		}
		if inSection && strings.HasPrefix(line, "Choice") {
			return true
		}
	}
	return false
}

// themeHasModule reports whether our module is already installed in a theme.
func themeHasModule(dir string) bool {
	entries, err := os.ReadDir(filepath.Join(dir, "Modules"))
	if err != nil {
		return false
	}
	for _, e := range entries {
		name := e.Name()
		if strings.HasSuffix(strings.ToLower(name), ".lua") &&
			strings.Contains(strings.ToLower(name), "content browser") {
			return true
		}
	}
	return false
}

// CurrentTheme is the theme this install is set to use.
//
// ITGmania keeps a global Theme under [Options] and a per-game override under
// [Game-<game>]. The override is what the running game actually loads, so when
// both are present the override wins.
func CurrentTheme(saveDir string) string {
	data, err := os.ReadFile(filepath.Join(saveDir, "Preferences.ini"))
	if err != nil {
		return ""
	}
	var global, perGame string
	section := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(strings.Trim(line, "[]"))
			continue
		}
		key, value, ok := splitKV(line)
		if !ok || !strings.EqualFold(key, "Theme") || value == "" {
			continue
		}
		switch {
		case section == "options":
			global = value
		case strings.HasPrefix(section, "game-"):
			perGame = value
		}
	}
	if perGame != "" {
		return perGame
	}
	return global
}

// ThemeRoots is every directory the game loads themes from, in the order the
// engine mounts them -- the player's profile first, because it is mounted OVER
// the install.
//
// This is not a detail. ArchHooks_Unix.cpp mounts <profile>/Themes at /Themes
// alongside the install's own, and the Windows and macOS hooks do the same for
// their profile directories. On a Linux cabinet the game lives in
// /opt/itgmania, owned by root, so a player adding a theme puts it in their
// profile -- and a theme list built only from the install directory could not
// see it. The theme actually in use was therefore never found, Current never
// matched anything, and the module went into whichever theme sorted first.
func ThemeRoots(inst Install) []string {
	var out []string
	seen := map[string]bool{}
	add := func(dir string) {
		if dir == "" || seen[dir] || !isDir(dir) {
			return
		}
		seen[dir] = true
		out = append(out, dir)
	}
	// The profile's Themes, which the engine mounts over the install's.
	if inst.SaveDir != "" && !inst.Portable {
		add(filepath.Join(filepath.Dir(inst.SaveDir), "Themes"))
	}
	add(inst.ThemesDir)
	return out
}

// Themes lists the install's theme directories, best candidate first.
func Themes(inst Install) []Theme {
	current := CurrentTheme(inst.SaveDir)

	var found []Theme
	seen := map[string]bool{}
	for _, root := range ThemeRoots(inst) {
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			name := e.Name()
			// _fallback is the engine's own base theme, not something to
			// install into
			if strings.HasPrefix(name, "_") || strings.HasPrefix(name, ".") {
				continue
			}
			// The profile is listed first and wins: the engine mounts it over
			// the install, so that is the copy the game actually loads.
			if seen[strings.ToLower(name)] {
				continue
			}
			seen[strings.ToLower(name)] = true
			dir := filepath.Join(root, name)
			found = append(found, Theme{
				Name:      name,
				Path:      dir,
				Modules:   themeLoadsModules(dir),
				TitleMenu: themeHasTitleChoices(dir),
				Current:   strings.EqualFold(name, current),
				Installed: themeHasModule(dir),
			})
		}
	}

	// Best first: one it would run under, that the player is using, that it is
	// already in. The rest keep alphabetical order so a listing reads sensibly.
	sort.SliceStable(found, func(a, b int) bool {
		x, y := found[a], found[b]
		if x.Compatible() != y.Compatible() {
			return x.Compatible()
		}
		if x.Current != y.Current {
			return x.Current
		}
		if x.Installed != y.Installed {
			return x.Installed
		}
		return strings.ToLower(x.Name) < strings.ToLower(y.Name)
	})
	return found
}

// CompatibleThemes is Themes filtered to the ones the module would run under.
func CompatibleThemes(inst Install) []Theme {
	var out []Theme
	for _, t := range Themes(inst) {
		if t.Compatible() {
			out = append(out, t)
		}
	}
	return out
}

// PickTheme chooses which theme to install into.
//
// want is the name the caller asked for, if any. With no name it picks only
// when the answer is not a matter of taste: the theme in use, or the single
// compatible one. Anything else is the player's call, and ask reports that.
func PickTheme(themes []Theme, want string) (chosen Theme, ask bool, err error) {
	var usable []Theme
	for _, t := range themes {
		if t.Compatible() {
			usable = append(usable, t)
		}
	}

	if want != "" {
		for _, t := range themes {
			if strings.EqualFold(t.Name, want) {
				if !t.Compatible() {
					return Theme{}, false, &ThemeError{Name: t.Name, Reason: t.Why()}
				}
				return t, false, nil
			}
		}
		return Theme{}, false, &ThemeError{Name: want, Reason: "no such theme in this install"}
	}

	if len(usable) == 0 {
		return Theme{}, false, &ThemeError{Reason: "no theme here loads Simply Love modules"}
	}
	// The theme actually in use is the one the player will see it in.
	for _, t := range usable {
		if t.Current {
			return t, false, nil
		}
	}
	if len(usable) == 1 {
		return usable[0], false, nil
	}
	return usable[0], true, nil
}

// ThemeError is a theme that cannot be installed into, and why.
type ThemeError struct {
	Name   string
	Reason string
}

func (e *ThemeError) Error() string {
	if e.Name == "" {
		return e.Reason
	}
	return e.Name + ": " + e.Reason
}
