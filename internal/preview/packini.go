package preview

import (
	"archive/zip"
	"io"
	"path"
	"regexp"
	"strings"
)

// PackIni is what a pack's archive says about its own sync.
//
// SMO's catalogue carries a sync tag for some packs and nothing for the rest,
// and "nothing" is ambiguous: it can mean the pack has no Pack.ini and the
// machine will decide, or that SMO simply never tagged it. The archive settles
// which, because the file is either in there or it is not.
type PackIni struct {
	// Present is whether the download contains a Pack.ini at all.
	Present bool `json:"present"`
	// Sync is what it says, "ITG" or "NULL", when it says anything readable.
	Sync string `json:"sync,omitempty"`
	// Path is where in the archive it was found, for the curious.
	Path string `json:"path,omitempty"`
}

// A Pack.ini says which sync a pack was written at:
//
//	[Group]
//	SyncOffset=ITG
//
// Read loosely -- case, spacing and the section header all vary in the wild,
// and the only part anyone depends on is the value.
var syncOffset = regexp.MustCompile(`(?i)sync[ _]?offset\s*=\s*([A-Za-z0-9_.+-]+)`)

// maxIni caps what will be read out of the archive. A Pack.ini is a handful of
// lines; anything claiming to be megabytes is not one, and reading it would
// pull the whole thing over ranged requests for nothing.
const maxIni = 64 << 10

// PackIni reports whether a pack's download carries a Pack.ini, and what it
// says.
//
// It costs the archive index and one small read: the index is a HEAD plus the
// central directory, which is the same work a preview of that pack already
// does, and it is kept afterwards -- so asking about a pack whose sample has
// been played is close to free.
func (f *Fetcher) PackIni(packID int) (PackIni, error) {
	var out PackIni

	l := f.lockPack(packID)
	l.Lock()
	defer l.Unlock()

	a, err := f.openPack(packID)
	if err != nil {
		return out, err
	}
	defer a.trimBlocks()

	entry := findPackIni(a)
	if entry == nil {
		// The index is the answer here: no entry means no file, which is a
		// fact about the download rather than a failure to look.
		return out, nil
	}

	out.Present = true
	out.Path = entry.Name

	if entry.UncompressedSize64 > maxIni {
		return out, nil
	}
	rc, err := entry.Open()
	if err != nil {
		// It is there; we just could not read it. Saying so is better than
		// reporting it missing.
		return out, nil
	}
	defer rc.Close()

	body, err := io.ReadAll(io.LimitReader(rc, maxIni))
	if err != nil {
		return out, nil
	}
	if m := syncOffset.FindSubmatch(body); m != nil {
		switch strings.ToUpper(strings.TrimSpace(string(m[1]))) {
		case "NULL", "0":
			out.Sync = "NULL"
		case "ITG":
			out.Sync = "ITG"
		}
	}
	return out, nil
}

// findPackIni picks the pack's own Pack.ini out of the index.
//
// The shallowest one wins. A pack archive is usually one folder holding the
// song folders, so its Pack.ini sits one level down -- but some are packed
// flat, and a song folder can carry files of its own. Depth is what tells the
// pack's file apart from anything deeper that happens to share the name.
func findPackIni(a *archive) *zip.File {
	var best *zip.File
	bestDepth := 1 << 30
	for _, file := range a.files {
		if file.FileInfo().IsDir() {
			continue
		}
		if !strings.EqualFold(path.Base(file.Name), "pack.ini") {
			continue
		}
		depth := strings.Count(strings.Trim(file.Name, "/"), "/")
		if depth < bestDepth {
			best, bestDepth = file, depth
		}
	}
	return best
}
