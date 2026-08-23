package installer

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// Install describes one ITGmania installation found on this machine.
type Install struct {
	Root      string // install root (contains Themes/, Program/ or the app bundle)
	SaveDir   string // where Preferences.ini lives (portable: <root>/Save)
	ThemesDir string // <root>/Themes
	Portable  bool   // Save lives beside the install rather than in the user profile
	Version   string // best-effort, may be empty
	HasSimply bool   // at least one theme here can load the module

	// ThemeDir is the theme chosen for this run. Empty means "work it out",
	// which is what everything except an explicit choice wants.
	ThemeDir string
}

// SimplyLoveDir returns the Simply Love theme directory for this install.
// ITGmania ships the theme as "Simply Love"; some users rename their copy, so
// we fall back to any theme directory that looks like Simply Love.
func (i Install) SimplyLoveDir() string {
	if i.ThemeDir != "" {
		return i.ThemeDir
	}
	exact := filepath.Join(i.ThemesDir, "Simply Love")
	if isDir(exact) {
		return exact
	}
	entries, err := os.ReadDir(i.ThemesDir)
	if err != nil {
		return exact
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasPrefix(strings.ToLower(name), "simply love") {
			return filepath.Join(i.ThemesDir, name)
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

	home, _ := os.UserHomeDir()

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
	}
	return out
}

// userSaveDir is where a non-portable install keeps Save/.
func userSaveDir() string {
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "windows":
		if appData := os.Getenv("APPDATA"); appData != "" {
			return filepath.Join(appData, "ITGmania", "Save")
		}
	case "darwin":
		if home != "" {
			return filepath.Join(home, "Library", "Application Support", "ITGmania", "Save")
		}
	default:
		if home != "" {
			return filepath.Join(home, ".itgmania", "Save")
		}
	}
	return ""
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
	// Themes/ alone is not enough; require another ITGmania marker.
	if !isDir(filepath.Join(root, "Data")) && !isDir(filepath.Join(root, "Program")) &&
		!isDir(filepath.Join(root, "NoteSkins")) {
		return Install{}, false
	}

	inst := Install{Root: root, ThemesDir: themes}

	// Portable installs keep Save/ beside the install and ship Portable.ini.
	localSave := filepath.Join(root, "Save")
	portableMarker := isFile(filepath.Join(root, "Portable.ini"))
	switch {
	case portableMarker:
		inst.Portable = true
		inst.SaveDir = localSave
	case isDir(localSave) && isFile(filepath.Join(localSave, "Preferences.ini")):
		// no marker but a populated local Save: treat as portable
		inst.Portable = true
		inst.SaveDir = localSave
	default:
		if us := userSaveDir(); us != "" {
			inst.SaveDir = us
		} else {
			inst.SaveDir = localSave
		}
	}

	inst.HasSimply = len(CompatibleThemes(inst)) > 0
	inst.Version = detectVersion(root)
	return inst, true
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
