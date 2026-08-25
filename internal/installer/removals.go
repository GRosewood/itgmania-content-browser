package installer

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// The engine leaves one of these behind for every directory it creates.
//
// RageFileManager::CreateDir writes <dir>newdir.temp.newdir to check the
// location is writable and then deletes it again -- but the delete goes
// through a filename cache that was never told the file exists, so it silently
// does nothing, and the missing separator makes each one a sibling of the
// directory rather than a child. Unzipping a pack creates a directory per
// song, so a pack arrives with one of these beside every folder it made.
// They are always empty.
const tempDirProbe = "newdir.temp.newdir"

// Deleting a song pack.
//
// ITGmania's Lua API cannot delete files -- RageFileManager exposes only Copy,
// DoesFileExist, GetFileSizeBytes, GetHashForFile, GetDirListing and Unzip --
// so the in-game "Installed Packs" screen asks the loopback helper to do it,
// and the helper lands here.

// SongRoots lists the directories a pack folder could live in for this install:
// the install's own Songs directory, wherever that is for this layout, plus any
// writable song folder the player configured. The read-only ones are left out
// on purpose -- nothing here should be deleting out of a tree the player
// mounted read-only.
func SongRoots(inst Install) []string {
	seen := map[string]bool{}
	var out []string
	add := func(p string) {
		if p == "" {
			return
		}
		abs, err := filepath.Abs(p)
		if err != nil || seen[abs] || !isDir(abs) {
			return
		}
		seen[abs] = true
		out = append(out, abs)
	}
	add(filepath.Join(inst.Root, "Songs"))
	if inst.SaveDir != "" {
		add(filepath.Join(filepath.Dir(inst.SaveDir), "Songs"))
	}
	for _, dir := range AdditionalSongDirs(inst) {
		add(dir)
	}
	return out
}

// safePackDir resolves a pack name to a directory, refusing anything that is
// not a plain folder sitting directly inside one of the song roots. The name
// arrives over HTTP, so a value like "../../Program" must not be able to
// delete anything even though the endpoint is loopback-only.
func safePackDir(inst Install, name string) (string, error) {
	clean := strings.TrimSpace(name)
	if clean == "" {
		return "", fmt.Errorf("empty pack name")
	}
	if clean != filepath.Base(clean) || clean == "." || clean == ".." ||
		strings.ContainsAny(clean, `/\`) || filepath.IsAbs(clean) {
		return "", fmt.Errorf("%q is not a plain folder name", name)
	}

	for _, root := range SongRoots(inst) {
		candidate := filepath.Join(root, clean)
		abs, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		// belt and braces: the resolved path must still be a direct child
		if filepath.Dir(abs) != root {
			continue
		}
		if isDir(abs) {
			return abs, nil
		}
	}
	return "", fmt.Errorf("no folder named %q under %s", clean,
		strings.Join(SongRoots(inst), " or "))
}

// TidyProbeFiles deletes the empty probe files described above, from every
// Songs directory this install has. It is deliberately not scoped to one pack:
// the module cannot reliably learn the folder name an unzip produced (the
// engine's directory listing is cached for thirty seconds), and a sweep needs
// no name. Only empty files whose name ends in the probe suffix are touched.
func TidyProbeFiles(inst Install) ([]string, error) {
	var removed []string
	for _, root := range SongRoots(inst) {
		err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil // one unreadable entry should not abort the sweep
			}
			if d.IsDir() || !strings.HasSuffix(d.Name(), tempDirProbe) {
				return nil
			}
			info, err := d.Info()
			if err != nil || info.Size() != 0 {
				return nil
			}
			if os.Remove(p) == nil {
				removed = append(removed, p)
			}
			return nil
		})
		if err != nil {
			return removed, fmt.Errorf("sweeping %s: %w", root, err)
		}
	}
	return removed, nil
}

// RemovePack deletes one pack directory and returns the path it removed.
// This is the single-pack entry point the loopback helper calls, so the safety
// check that keeps a name from escaping Songs/ is shared with the queue path.
func RemovePack(inst Install, name string) (string, error) {
	dir, err := safePackDir(inst, name)
	if err != nil {
		return "", err
	}
	if err := os.RemoveAll(dir); err != nil {
		return "", fmt.Errorf("removing %s: %w", dir, err)
	}
	return dir, nil
}

// removeNestedModules cleans up the Modules/Modules/ directory an ITGmania
// upgrade can leave behind on Linux.
//
// ITGmania's setup.sh preserves the theme's Modules folder across an upgrade
// with `cp -r -n "<old>/Modules" "<new>/Modules"`. When the new release already
// ships a Modules directory -- Simply Love does, it contains a README -- cp
// copies the source INTO the destination rather than over it, so everything
// ends up one level deeper at Modules/Modules/.
//
// Simply Love lists Modules/ with GetDirListing and loads only names ending
// .lua, so nothing there is ever read: the entry disappears from the title menu
// with no error anywhere. Re-running the installer lays the files down
// correctly again, and this takes the orphaned copy away so it cannot be
// mistaken for the real one later.
//
// Guarded on the nested copy actually being ours. A Modules/Modules that does
// not hold our entry file belongs to somebody else.
func removeNestedModules(modulesDir string) []string {
	nested := filepath.Join(modulesDir, "Modules")
	if !isDir(nested) {
		return nil
	}
	if !isFile(filepath.Join(nested, "ITGmania Content Browser.lua")) {
		return nil
	}
	if err := os.RemoveAll(nested); err != nil {
		return nil
	}
	return []string{"Modules" + string(filepath.Separator) +
		" (nested copy left by an ITGmania upgrade)"}
}
