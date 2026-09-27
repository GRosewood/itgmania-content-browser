package installer

// Where a pack downloaded in the game ends up.
//
// The browser downloads through the game, and the game unpacks into /Songs,
// which is every song folder at once: its own, plus the folders the player
// listed -- AdditionalSongFolders* (packs directly inside) and the Songs/ of
// any AdditionalFolders* tree. For a pack folder that does not exist yet, the
// engine tries the newest mount first. It mounts trees before song folders,
// each list in the order written, and never writes into one listed
// ...ReadOnly. So the last writable song folder takes a download, then the
// last writable tree, then the game's own Songs folder -- checked against the
// engine by running it, not read off a comment.
//
// What the engine does not do is say so. A read-only folder, or a writable one
// on a filesystem that refuses the write, is passed over in silence and the
// unzip reports success. So this is the one place outside the game that says
// where downloads go, and why.

import (
	"path/filepath"
)

// Library is one song folder the player listed, as found when checked.
type Library struct {
	Dir          string // where packs are: the folder itself, or a tree's Songs/
	Tree         bool   // listed as a whole game tree (AdditionalFolders*)
	ReadOnlyPref bool   // listed ...ReadOnly, so the game never writes into it
	Writable     bool   // a file could be created there just now
	ReadOnlyFS   bool   // on a filesystem mounted read-only just now (Linux)
	Pending      bool   // listed writable from the game's next start (see WithWritableSongs)
}

// WithWritableSongs is libs as the game will see them once dir -- listed
// read-only today -- is listed as a writable song folder instead: first in
// line for a download. It is how the ITG System Image's songs drive reads right
// after the installer has changed its start script, before the game has
// started again to act on it. A folder that is not read-only today is left as
// it is.
func WithWritableSongs(libs []Library, dir string) []Library {
	at := -1
	for i, lib := range libs {
		if lib.Dir == dir && lib.ReadOnlyPref {
			at = i
		}
	}
	if at < 0 {
		return libs
	}
	out := []Library{{Dir: dir, Pending: true, ReadOnlyFS: libs[at].ReadOnlyFS}}
	for i, lib := range libs {
		if i != at {
			out = append(out, lib)
		}
	}
	return out
}

// Libraries lists the song folders the player listed, in the order the game
// tries them for a new pack -- writable song folders, then writable trees,
// the last-listed of each first -- followed by the read-only ones, which it
// never tries at all.
func Libraries(inst Install) []Library {
	var out []Library
	add := func(dirs []string, tree, readOnly bool, reverse bool) {
		if reverse {
			for i, j := 0, len(dirs)-1; i < j; i, j = i+1, j-1 {
				dirs[i], dirs[j] = dirs[j], dirs[i]
			}
		}
		for _, dir := range dirs {
			lib := Library{Dir: dir, Tree: tree, ReadOnlyPref: readOnly,
				ReadOnlyFS: readOnlyFS(dir)}
			if !readOnly {
				lib.Writable = Writable(dir)
			}
			out = append(out, lib)
		}
	}
	add(AdditionalSongDirs(inst), false, false, true)
	add(AdditionalRootDirs(inst), true, false, true)
	add(prefDirs(inst, "", "AdditionalSongFoldersReadOnly"), false, true, false)
	add(prefDirs(inst, "Songs", "AdditionalFoldersReadOnly"), true, true, false)
	return out
}

// DownloadsGoTo is where the game puts a pack downloaded in it: the first
// folder in libs it may write to, or the game's own Songs folder. Whether
// that folder takes the write is another question -- one on a filesystem
// mounted read-only refuses, and the game moves on to the next -- which is
// why the folders are reported one by one as well.
func DownloadsGoTo(inst Install, libs []Library) string {
	for _, lib := range libs {
		if !lib.ReadOnlyPref {
			return lib.Dir
		}
	}
	return OwnSongsDir(inst)
}

// DownloadsFallBackTo is where a download goes while the folder DownloadsGoTo
// names refuses writes: the next folder the game may write to that is not on
// a read-only filesystem, or the game's own Songs folder.
func DownloadsFallBackTo(inst Install, libs []Library) string {
	first := true
	for _, lib := range libs {
		if lib.ReadOnlyPref {
			continue
		}
		if first {
			first = false
			continue
		}
		if !lib.ReadOnlyFS {
			return lib.Dir
		}
	}
	return OwnSongsDir(inst)
}

// OwnSongsDir is the game's own writable Songs folder -- beside the install on
// a portable one, beside Save/ otherwise.
func OwnSongsDir(inst Install) string {
	if inst.Portable || inst.SaveDir == "" {
		return filepath.Join(inst.Root, "Songs")
	}
	return filepath.Join(filepath.Dir(inst.SaveDir), "Songs")
}
