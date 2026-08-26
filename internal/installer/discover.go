package installer

import (
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

// Install describes one ITGmania installation found on this machine.
type Install struct {
	Root    string // install root (contains Themes/, Program/ or the app bundle)
	SaveDir string // where Preferences.ini lives (portable: <root>/Save)
	// PrefsFound is whether a Preferences.ini was actually there. When it was
	// not, nothing can say which theme is in use, and the allowlist is being
	// written into a file the game has not created yet.
	PrefsFound bool
	ThemesDir  string // <root>/Themes
	Portable   bool   // Save lives beside the install rather than in the user profile
	Version    string // best-effort, may be empty
	HasSimply  bool   // at least one theme here can load the module

	// ThemeDir is the theme chosen for this run. Empty means "work it out",
	// which is what everything except an explicit choice wants.
	ThemeDir string

	// GameUser is the account ITGmania runs as, when it could be worked out.
	// Everything this installer writes belongs to them -- the save profile, the
	// helper, the autostart registration -- so it is resolved once, on
	// evidence, rather than inferred separately in each place from whatever
	// HOME happened to be set to.
	GameUser GameUser
}

// ModuleThemeDir returns the theme directory the installed module actually
// lives in, which is where an update must land.
//
// SimplyLoveDir answers a different question -- "where would an install go?"
// -- and answering it here loses on forks: a player running a renamed Simply
// Love fork has the module in the fork, but a fresh discovery has no ThemeDir,
// so the fallback picks whatever folder is literally called "Simply Love".
// The updater would then write 44 files into a theme nobody is running,
// report success, and change nothing the player can see.
//
// So this looks for the module itself. The theme named in Preferences.ini is
// believed first, because that is the one the game is drawing; failing that,
// any theme holding the module; failing that, wherever an install would go,
// which at least fails in the obvious place rather than a hidden one.
func (i Install) ModuleThemeDir() string {
	has := func(themeDir string) bool {
		return themeDir != "" &&
			isFile(filepath.Join(themeDir, "Modules", "ITGmania Content Browser.lua"))
	}
	// CurrentTheme, not preference(): a per-game override beats the global
	// Theme key, and the override is what the running game actually loads.
	if current := CurrentTheme(i.SaveDir); current != "" {
		for _, root := range ThemeRoots(i) {
			if dir := filepath.Join(root, current); has(dir) {
				return dir
			}
		}
	}
	for _, root := range ThemeRoots(i) {
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() && has(filepath.Join(root, e.Name())) {
				return filepath.Join(root, e.Name())
			}
		}
	}
	return i.SimplyLoveDir()
}

// SimplyLoveDir returns the Simply Love theme directory for this install.
// ITGmania ships the theme as "Simply Love"; some users rename their copy, so
// we fall back to any theme directory that looks like Simply Love.
func (i Install) SimplyLoveDir() string {
	if i.ThemeDir != "" {
		return i.ThemeDir
	}
	// The theme actually in use comes before any match on name, and it is
	// looked for in every place the engine loads themes from -- the player's
	// profile as well as the install.
	//
	// Two things went wrong without this. An install can hold both "Simply
	// Love" and "Simply Love-SM5" with the second switched on, and taking the
	// stock name first put the module in the one the player does not load. And
	// on Linux the game is in /opt, owned by root, so a theme the player added
	// is in ~/.itgmania/Themes -- which was not searched at all, so the theme
	// in use could not be found even by name. Both ended the same way: files
	// landed, the installer reported success, and Find Content never appeared.
	if cur := CurrentTheme(i.SaveDir); cur != "" {
		for _, root := range ThemeRoots(i) {
			if dir := filepath.Join(root, cur); isDir(dir) {
				return dir
			}
		}
	}
	var exact string
	for _, root := range ThemeRoots(i) {
		candidate := filepath.Join(root, "Simply Love")
		if exact == "" {
			exact = candidate
		}
		if isDir(candidate) {
			return candidate
		}
	}
	if exact == "" {
		exact = filepath.Join(i.ThemesDir, "Simply Love")
	}
	for _, root := range ThemeRoots(i) {
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			name := e.Name()
			if strings.HasPrefix(strings.ToLower(name), "simply love") {
				return filepath.Join(root, name)
			}
		}
	}
	return exact
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// candidateRoots returns plausible ITGmania install roots for this platform.
func candidateRoots() []string {
	var out []string
	add := func(paths ...string) {
		for _, p := range paths {
			if p != "" {
				out = append(out, p)
			}
		}
	}

	// the same home the Save directory is worked out from, so a sudo
	// install searches the cabinet user's profile rather than root's
	home := homeDir()

	switch runtime.GOOS {
	case "windows":
		programFiles := os.Getenv("ProgramFiles")
		programFilesX86 := os.Getenv("ProgramFiles(x86)")
		localAppData := os.Getenv("LOCALAPPDATA")
		for _, drive := range []string{"C:", "D:", "E:"} {
			add(
				filepath.Join(drive+string(filepath.Separator), "Games", "ITGmania"),
				filepath.Join(drive+string(filepath.Separator), "ITGmania"),
			)
		}
		add(
			filepath.Join(programFiles, "ITGmania"),
			filepath.Join(programFilesX86, "ITGmania"),
			filepath.Join(localAppData, "Programs", "ITGmania"),
		)
		if home != "" {
			add(
				filepath.Join(home, "ITGmania"),
				filepath.Join(home, "Games", "ITGmania"),
				filepath.Join(home, "Desktop", "ITGmania"),
			)
		}
		// Steam library default
		add(filepath.Join(programFilesX86, "Steam", "steamapps", "common", "ITGmania"))

	case "darwin":
		add("/Applications/ITGmania.app")
		if home != "" {
			add(
				filepath.Join(home, "Applications", "ITGmania.app"),
				filepath.Join(home, "ITGmania"),
			)
		}

	default: // linux and friends
		add(
			"/opt/itgmania",
			"/opt/ITGmania",
			"/usr/local/itgmania",
			"/usr/local/games/itgmania",
			"/usr/games/itgmania",
			"/usr/share/itgmania",
		)
		if home != "" {
			add(
				filepath.Join(home, ".itgmania"),
				filepath.Join(home, "itgmania"),
				filepath.Join(home, "ITGmania"),
				filepath.Join(home, "Games", "itgmania"),
				filepath.Join(home, ".local", "share", "itgmania"),
			)
		}
		// Mounted drives. A cabinet with the game on a second disk is ordinary
		// -- /mnt/itgmania is a real layout -- and none of the fixed paths
		// above can guess the mount point, so the mount roots are listed
		// instead. Only one level down: /mnt and /media hold mount points, not
		// trees to walk.
		add(mountedCandidates()...)
	}
	return out
}

// mountedCandidates lists directories one level under the usual mount roots.
//
// Inspect rejects anything without a game binary in it, so listing every mount
// point costs a stat per entry and admits nothing that is not an install. That
// is a better trade than a fixed list of names, which cannot know what someone
// called their drive.
func mountedCandidates() []string {
	var out []string
	roots := []string{"/mnt", "/media", "/run/media", "/srv"}
	if home := homeDir(); home != "" {
		// /media/<user>/<label> and /run/media/<user>/<label> are what the
		// desktop automounters produce.
		if u := filepath.Base(home); u != "" && u != "." && u != string(filepath.Separator) {
			roots = append(roots, filepath.Join("/media", u), filepath.Join("/run/media", u))
		}
	}
	for _, root := range roots {
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			dir := filepath.Join(root, e.Name())
			out = append(out, dir)
			// One more level, for a drive holding the game in a subfolder
			// rather than at its root.
			for _, name := range []string{"itgmania", "ITGmania", "Games/itgmania", "Games/ITGmania"} {
				out = append(out, filepath.Join(dir, filepath.FromSlash(name)))
			}
		}
	}
	return out
}

// homeDir is the home of the person running this, which is not always the home
// of the account the process is under.
//
// Installing onto a cabinet is usually done with sudo, and sudo hands the
// process root's environment: HOME becomes /root, and every per-user path
// derived from it -- the search list, the Save directory -- points somewhere
// the game has never looked. That is how an install ends up writing a
// Preferences.ini nobody reads. SUDO_USER is who actually asked.
func homeDir() string {
	if who := os.Getenv("SUDO_USER"); who != "" && who != "root" {
		if u, err := user.Lookup(who); err == nil && u.HomeDir != "" {
			return u.HomeDir
		}
	}
	home, _ := os.UserHomeDir()
	return home
}

// userSaveDir is where a non-portable install keeps Save/.
func userSaveDir() string {
	return saveUnderHome(homeDir())
}

// saveUnderHome is where ITGmania keeps Save/ under a given home directory.
// Split out from userSaveDir so the same rule can be asked of somebody else s
// home -- which is the whole problem on a cabinet set up with sudo.
func saveUnderHome(home string) string {
	switch runtime.GOOS {
	case "windows":
		// Windows keeps it under the roaming profile rather than the home
		// directory, and there is only ever the one.
		if appData := os.Getenv("APPDATA"); appData != "" {
			return filepath.Join(appData, "ITGmania", "Save")
		}
		return ""
	case "darwin":
		if home == "" {
			return ""
		}
		return filepath.Join(home, "Library", "Application Support", "ITGmania", "Save")
	default:
		if home == "" {
			return ""
		}
		return filepath.Join(home, ".itgmania", "Save")
	}
}

// Inspect turns a candidate directory into an Install, or returns ok=false if
// it does not look like an ITGmania installation.
//
// On macOS the user may point at either ITGmania.app or the directory holding
// it; both are accepted.
func Inspect(root string) (Install, bool) {
	root = filepath.Clean(root)

	// macOS: resources live inside the bundle.
	if runtime.GOOS == "darwin" {
		if strings.HasSuffix(strings.ToLower(root), ".app") {
			inner := filepath.Join(root, "Contents", "Resources")
			if isDir(filepath.Join(inner, "Themes")) {
				root = inner
			}
		} else if isDir(filepath.Join(root, "ITGmania.app", "Contents", "Resources", "Themes")) {
			root = filepath.Join(root, "ITGmania.app", "Contents", "Resources")
		}
	}

	themes := filepath.Join(root, "Themes")
	if !isDir(themes) {
		return Install{}, false
	}
	// Themes/ alone is not enough, and neither is a directory that merely
	// looks like one.
	//
	// ITGmania mirrors its whole layout into the player's profile: ~/.itgmania
	// holds Save/, Cache/, Songs/, Themes/ and NoteSkins/ too. Accepting
	// "Data or Program or NoteSkins" therefore matched the profile as well as
	// the install, so a machine with one copy of the game was reported as two
	// -- and picking the profile gave an empty theme list and the wrong answer
	// about which theme is in use.
	//
	// The game's own desktop entry settles it: TryExec=/opt/itgmania/itgmania.
	// An install is the thing with the executable in it. A profile has no
	// executable, and never will.
	if !hasGameBinary(root) {
		return Install{}, false
	}

	inst := Install{Root: root, ThemesDir: themes}

	// Which Save directory the game actually reads.
	//
	// Getting this wrong is quiet and expensive: the network allowlist is
	// written into Preferences.ini, and the theme in use is read out of it, so
	// picking the wrong one both fails to enable the browser and installs it
	// into whichever theme happened to sort first.
	localSave := filepath.Join(root, "Save")
	if isFile(filepath.Join(root, "Portable.ini")) {
		// the marker is definitive; nothing else gets a say
		inst.Portable = true
		inst.SaveDir = localSave
	} else if u, ok := ResolveGameUser(root); ok && saveUnderHome(u.Home) != "" {
		// The account that actually plays decides where Save is. Guessing from
		// the environment put it under /root when the installer was run with
		// sudo, and everything downstream -- the allowlist, the theme in use,
		// the helper -- followed it there.
		inst.GameUser = u
		inst.SaveDir = saveUnderHome(u.Home)
		inst.PrefsFound = isFile(filepath.Join(inst.SaveDir, "Preferences.ini"))
		// A portable install still wins: its Save sits beside the game and the
		// game reads that one whoever runs it.
		if isFile(filepath.Join(localSave, "Preferences.ini")) {
			inst.SaveDir, inst.PrefsFound, inst.Portable = localSave, true, true
		}
	} else {
		inst.SaveDir, inst.PrefsFound = pickSaveDir(localSave, saveDirCandidates(root))
		inst.Portable = inst.SaveDir == localSave
	}
	if !inst.PrefsFound {
		inst.PrefsFound = isFile(filepath.Join(inst.SaveDir, "Preferences.ini"))
	}

	inst.HasSimply = len(CompatibleThemes(inst)) > 0
	inst.Version = detectVersion(root)
	return inst, true
}

// saveDirCandidates is every Save directory a profile might keep, best guess
// first. See candidateHomes for why there is more than one.
func saveDirCandidates(root string) []string {
	var out []string
	for _, home := range candidateHomes(root) {
		if dir := saveUnderHome(home); dir != "" {
			out = append(out, dir)
		}
	}
	return out
}

// pickSaveDir chooses between the Save beside the install and the profiles that
// might hold one, and says whether any of them had a Preferences.ini.
//
// Whichever holds that file is the one the game reads. When more than one does
// -- a portable copy beside a stale profile, or a machine with several accounts
// -- the most recently written wins, because the engine rewrites the whole file
// every time it exits, so the live one is always the freshest.
func pickSaveDir(localSave string, profiles []string) (string, bool) {
	best, bestWhen, found := "", time.Time{}, false
	for _, dir := range append([]string{localSave}, profiles...) {
		if dir == "" {
			continue
		}
		info, err := os.Stat(filepath.Join(dir, "Preferences.ini"))
		if err != nil {
			continue
		}
		if !found || info.ModTime().After(bestWhen) {
			best, bestWhen, found = dir, info.ModTime(), true
		}
	}
	if found {
		return best, true
	}
	// None exists yet. A fresh run will make one in the first profile we would
	// have looked in, unless there is no profile at all.
	if len(profiles) > 0 {
		return profiles[0], false
	}
	return localSave, false
}

// detectVersion makes a best effort at the installed ITGmania version. The
// engine writes it as the first line of Logs/log.txt (e.g. "ITGmania1.3.0").
// It is informational only -- installation does not depend on it.
func detectVersion(root string) string {
	for _, rel := range []string{
		filepath.Join("Logs", "log.txt"),
		filepath.Join("Logs", "info.txt"),
	} {
		data, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			continue
		}
		head := string(data)
		if len(head) > 4096 {
			head = head[:4096]
		}
		for _, line := range strings.Split(head, "\n") {
			line = strings.TrimSpace(line)
			if i := strings.Index(line, "ITGmania"); i >= 0 {
				v := strings.TrimSpace(line[i+len("ITGmania"):])
				v = strings.TrimPrefix(v, " ")
				if v != "" && (v[0] >= '0' && v[0] <= '9') {
					if sp := strings.IndexAny(v, " \t\r"); sp > 0 {
						v = v[:sp]
					}
					return v
				}
			}
		}
	}
	return ""
}

// Discover scans the usual locations and returns every install found,
// de-duplicated and with Simply Love installs first.
func Discover() []Install {
	seen := map[string]bool{}
	var found []Install
	for _, root := range candidateRoots() {
		inst, ok := Inspect(root)
		if !ok {
			continue
		}
		key := strings.ToLower(inst.Root)
		if seen[key] {
			continue
		}
		seen[key] = true
		found = append(found, inst)
	}
	sort.SliceStable(found, func(a, b int) bool {
		if found[a].HasSimply != found[b].HasSimply {
			return found[a].HasSimply
		}
		return found[a].Root < found[b].Root
	})
	return found
}

// hasGameBinary reports whether a directory holds the ITGmania executable.
//
// This is what separates an install from the profile ITGmania creates beside
// it, which carries the same directory names but nothing to run. The game's
// own .desktop identifies itself the same way, with TryExec pointing at the
// binary.
func hasGameBinary(root string) bool {
	// Windows keeps it in Program/, which is also what its own installer sets
	// as the executables directory.
	for _, p := range []string{
		filepath.Join(root, "Program", "ITGmania.exe"),
		filepath.Join(root, "Program", "StepMania.exe"),
		// Linux: the binary sits at the top, beside Themes/.
		filepath.Join(root, "itgmania"),
		filepath.Join(root, "itgmania-bin"),
		filepath.Join(root, "ITGmania"),
		// macOS: Inspect re-roots onto Contents/Resources, so the executable
		// is one level up in Contents/MacOS.
		filepath.Join(root, "..", "MacOS", "ITGmania"),
	} {
		if isFile(p) {
			return true
		}
	}
	// A Program/ directory with any executable in it counts: forks rename the
	// binary, and the directory only exists in an install.
	if entries, err := os.ReadDir(filepath.Join(root, "Program")); err == nil {
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".exe") {
				return true
			}
		}
	}
	return false
}
