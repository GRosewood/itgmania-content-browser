package preview

import (
	"archive/zip"
	"path"
	"sort"
	"strings"
)

// PackMods is which songs in a pack ship Lua of their own.
//
// A song folder holding a .lua file is a modfile chart: the Lua is the mod, run
// by the theme during gameplay. Plenty of players want exactly that and plenty
// want nothing to do with it, and neither group can tell from a listing --
// the catalogue does not say and the pack's name usually does not either.
//
// Read out of the archive index alone. The central directory names every entry
// in the pack, so this costs no reads beyond the index a preview of the same
// pack already builds.
type PackMods struct {
	// Songs is the folder name of each song that carries Lua, sorted.
	Songs []string `json:"songs"`
	// Count is how many there are, which stays useful even when those folder
	// names do not line up with the titles a listing shows.
	Count int `json:"count"`
	// Total is how many songs the pack holds, so "3 of 40" can be said rather
	// than a bare 3.
	Total int `json:"total"`
}

// PackMods reports which of a pack's songs ship Lua.
func (f *Fetcher) PackMods(packID int) (PackMods, error) {
	l := f.lockPack(packID)
	l.Lock()
	defer l.Unlock()

	a, err := f.openPack(packID)
	if err != nil {
		return PackMods{}, err
	}
	return modSongs(a.files), nil
}

// modSongs is the reading itself, over a list already in memory.
//
// A song is a folder with a simfile in it, and it is a modfile if that same
// folder holds a .lua. Going by folder rather than by depth is deliberate:
// packs nest to no fixed depth, and a .lua sitting at the top of the pack is a
// theme or a helper script rather than a chart's mod, so it does not count.
func modSongs(files []*zip.File) PackMods {
	songDirs := map[string]bool{}
	modDirs := map[string]bool{}
	for _, file := range files {
		if file.FileInfo().IsDir() {
			continue
		}
		dir := path.Dir(file.Name)
		if isSimfile(file.Name) {
			songDirs[dir] = true
		} else if strings.EqualFold(path.Ext(file.Name), ".lua") {
			modDirs[dir] = true
		}
	}

	var out PackMods
	for dir := range songDirs {
		if modDirs[dir] {
			out.Songs = append(out.Songs, path.Base(dir))
		}
	}
	sort.Strings(out.Songs)
	out.Count = len(out.Songs)
	out.Total = len(songDirs)
	return out
}
