package installer

// Where songs actually live.
//
// ITGmania mounts every song folder at the same place. <install>/Songs is
// mounted first, and then each entry of AdditionalSongFoldersWritable is
// mounted over the top of it, so /Songs inside the game is the union of all of
// them and nothing in Lua can tell them apart.
//
// That matters when writing. The file manager picks a driver for a new file by
// counting how many directories it would have to create, lowest wins, ties
// going to the earliest-loaded driver. Every driver ties on a pack that does
// not exist yet, so the engine's own unzip always lands in <install>/Songs --
// even when the player has pointed the game at a mounted drive and that Songs
// directory is a stub on a system disk that may not be writable at all.
//
// So the helper does the writing, and this file is how it knows where.

import (
	"os"
	"path/filepath"
	"strings"
)

// preference reads one key out of the [Options] section of Preferences.ini.
func preference(saveDir, key string) string {
	if saveDir == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(saveDir, "Preferences.ini"))
	if err != nil {
		return ""
	}
	section := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(strings.Trim(line, "[]"))
			continue
		}
		if section != "options" {
			continue
		}
		if k, v, ok := splitKV(line); ok && strings.EqualFold(k, key) {
			return v
		}
	}
	return ""
}

// AdditionalSongDirs lists the song folders the player configured as writable.
//
// AdditionalSongFolders is the old spelling; the engine migrates it into
// AdditionalSongFoldersWritable on load but leaves the original in the file, so
// both are read. The read-only variant is deliberately not read: it is mounted
// read-only precisely so nothing writes to it.
func AdditionalSongDirs(inst Install) []string {
	return prefDirs(inst, "", "AdditionalSongFoldersWritable", "AdditionalSongFolders")
}

// AdditionalRootDirs lists the extra trees mounted at the top of the game's
// filesystem, with "/Songs" appended -- because that is where a pack inside one
// of them lives.
//
// The engine mounts the two kinds at different points (StepMania.cpp):
//
//	MountFolders("dir", AdditionalFoldersWritable,     "/")
//	MountFolders("dir", AdditionalSongFoldersWritable, "/Songs")
//
// So an "additional song folder" holds packs directly, while an "additional
// folder" is a whole second game tree and its packs sit one level in, under
// Songs/. Only the first was ever looked at, so a pack on a drive mounted the
// second way could be seen in the browser -- the engine merges both into
// /Songs -- and then not be found when it came to deleting it.
//
// The read-only variants are deliberately absent from both: the player mounted
// those read-only, and nothing here should be deleting out of them.
func AdditionalRootDirs(inst Install) []string {
	return prefDirs(inst, "Songs", "AdditionalFoldersWritable", "AdditionalFolders")
}

// AdditionalThemeDirs lists the Themes/ of every tree the player mounted at
// the game's root.
//
// This is the same mount AdditionalRootDirs reads, one directory along. A tree
// mounted at "/" puts its Themes/ onto /Themes exactly as it puts its Songs/
// onto /Songs, so a cabinet whose library lives on a mounted drive can have
// the theme it is actually running sitting there and nowhere else. Only the
// install and the player's profile were ever searched, so that theme could not
// be found -- and the module went into a different copy, or a different theme,
// while the installer reported success.
//
// The read-only variant counts here, unlike in the song folders. Nothing in
// this package should write into a read-only mount, but a theme on one still
// loads, and finding it is what stops the module being installed into some
// other theme instead. Whether the chosen directory can actually be written to
// is a separate question, asked later, where it can be answered honestly.
func AdditionalThemeDirs(inst Install) []string {
	return prefDirs(inst, "Themes",
		"AdditionalFoldersWritable", "AdditionalFoldersReadOnly", "AdditionalFolders")
}

// prefDirs reads comma-separated directories out of the named preferences,
// optionally appending a subdirectory, and keeps the ones that exist.
func prefDirs(inst Install, sub string, keys ...string) []string {
	seen := map[string]bool{}
	var out []string
	for _, key := range keys {
		for _, raw := range strings.Split(preference(inst.SaveDir, key), ",") {
			p := expandHome(strings.TrimSpace(raw), inst)
			if p == "" {
				continue
			}
			if sub != "" {
				p = filepath.Join(p, sub)
			}
			abs, err := filepath.Abs(p)
			if err != nil || seen[abs] || !isDir(abs) {
				continue
			}
			seen[abs] = true
			out = append(out, abs)
		}
	}
	return out
}

// expandHome turns a leading ~ into the home of the account that plays. A path
// typed into the game's own options screen can carry one, and filepath.Abs
// would otherwise make a directory literally named "~".
func expandHome(p string, inst Install) string {
	if p == "" || p[0] != '~' {
		return p
	}
	home := inst.GameUser.Home
	if home == "" {
		home = homeDir()
	}
	if home == "" {
		return p
	}
	if p == "~" {
		return home
	}
	if len(p) > 1 && (p[1] == '/' || p[1] == filepath.Separator) {
		return filepath.Join(home, p[2:])
	}
	return p
}

// Writable reports whether a directory can actually be written to. Being
// configured is not the same as being mounted: a drive that is not plugged in
// leaves a directory that exists and refuses everything.
func Writable(dir string) bool {
	f, err := os.CreateTemp(dir, ".cb-write-check-*")
	if err != nil {
		return false
	}
	name := f.Name()
	f.Close()
	os.Remove(name)
	return true
}

// InstallRoots lists where a newly downloaded pack could be written, best
// first: the folders the player configured, then the install's own Songs.
//
// It is the write-side twin of SongRoots, and the two are deliberately built
// from the same pair of preferences. They drifted once -- deletion learned
// about trees mounted at the game's root and downloading did not -- and the
// result was a player who could see a pack on their drive, delete it, and not
// download one back to the same place. A shared shape is what keeps the two
// answers about "where do packs live" from disagreeing again.
//
// The order differs from SongRoots on purpose. Looking for a pack, the
// install's own Songs comes first because that is where most of them are.
// Choosing where to PUT one, a configured folder wins: a player who set one did
// so to say where their library belongs.
func InstallRoots(inst Install) []string {
	seen := map[string]bool{}
	var out []string
	add := func(p string) {
		if p == "" || seen[p] {
			return
		}
		seen[p] = true
		out = append(out, p)
	}
	// "put songs here", the more specific of the two
	for _, dir := range AdditionalSongDirs(inst) {
		add(dir)
	}
	// ...then the Songs/ of a whole tree mounted at the game's root, which the
	// engine merges into /Songs just the same
	for _, dir := range AdditionalRootDirs(inst) {
		add(dir)
	}
	return out
}

// InstallRoot is where a newly downloaded pack should be written.
//
// The first configured folder that can actually be written to is taken; if none
// can, the install's own Songs directory is the fallback, and if that cannot be
// written either the caller is told rather than finding out halfway through an
// unzip.
func InstallRoot(inst Install) (string, error) {
	for _, dir := range InstallRoots(inst) {
		if Writable(dir) {
			return dir, nil
		}
	}
	fallback := filepath.Join(inst.Root, "Songs")
	if inst.SaveDir != "" && !isDir(fallback) {
		fallback = filepath.Join(filepath.Dir(inst.SaveDir), "Songs")
	}
	if err := os.MkdirAll(fallback, 0o755); err != nil {
		return "", err
	}
	if !Writable(fallback) {
		return "", &RootError{Dir: fallback}
	}
	return fallback, nil
}

// RootError is a song directory that cannot be written to.
type RootError struct{ Dir string }

func (e *RootError) Error() string {
	return e.Dir + " cannot be written to; set AdditionalSongFoldersWritable to a" +
		" folder you own, or fix its permissions"
}
