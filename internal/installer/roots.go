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
	seen := map[string]bool{}
	var out []string
	for _, key := range []string{"AdditionalSongFoldersWritable", "AdditionalSongFolders"} {
		for _, raw := range strings.Split(preference(inst.SaveDir, key), ",") {
			p := strings.TrimSpace(raw)
			if p == "" {
				continue
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

// InstallRoot is where a newly downloaded pack should be written.
//
// A configured additional folder wins over <install>/Songs, because a player
// who configured one did so to say where their library lives. The first one
// that can actually be written to is taken; if none can, the install's own
// Songs directory is the fallback, and if that cannot be written either the
// caller is told rather than finding out halfway through an unzip.
func InstallRoot(inst Install) (string, error) {
	for _, dir := range AdditionalSongDirs(inst) {
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
