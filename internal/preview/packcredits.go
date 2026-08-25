package preview

import (
	"path"
	"sort"
	"strings"
)

// PackCredits is who actually charted a pack, read from the simfiles
// themselves rather than from any catalogue.
//
// The catalogue's per-chart credit index is sparse for older packs -- a pack
// can be entirely one person's work and show a single credited chart, or none
// -- so a search ranking built on that index miscredits exactly the packs
// their authors care most about. The simfiles do not lie: a chart's author is
// written into the file, in the #CREDIT header and in the per-chart fields,
// and the archive index this fetcher already builds can pull each simfile out
// over ranged reads for a few kilobytes apiece.
type PackCredits struct {
	// Total is how many songs the archive holds.
	Total int `json:"total"`
	// Credited is how many of them name at least one charter.
	Credited int `json:"credited"`
	// Credits is every distinct charter string found, with how many songs
	// each appears in. Keys are the strings as written; the reader decides
	// what matches what.
	Credits map[string]int `json:"credits"`
}

// PackCredits reads who charted a pack, out of the pack's own simfiles.
//
// The answer is remembered: the archive index is cached already, but the scan
// itself is one ranged read per song, and a second search in the same session
// should not pay for it twice.
func (f *Fetcher) PackCredits(packID int) (PackCredits, error) {
	l := f.lockPack(packID)
	l.Lock()
	defer l.Unlock()

	f.mu.Lock()
	if f.credits == nil {
		f.credits = map[int]PackCredits{}
	}
	cached, ok := f.credits[packID]
	f.mu.Unlock()
	if ok {
		return cached, nil
	}

	out := PackCredits{Credits: map[string]int{}}
	a, err := f.openPack(packID)
	if err != nil {
		return out, err
	}
	// A pack-wide scan touches one block per song; without this they all stay
	// resident in the cached archive after the answer is a few dozen strings.
	defer a.trimBlocks()

	for _, s := range a.songs {
		out.Total++
		if s.simfile == nil || s.simfile.UncompressedSize64 > maxSimfileBytes {
			continue
		}
		body, err := readEntry(s.simfile, maxSimfileBytes)
		if err != nil {
			continue
		}
		names := simfileCredits(s.simfile.Name, string(body))
		if len(names) == 0 {
			continue
		}
		out.Credited++
		for _, name := range names {
			out.Credits[name]++
		}
	}
	f.mu.Lock()
	f.credits[packID] = out
	f.mu.Unlock()
	return out, nil
}

// simfileCredits is every distinct charter a simfile names, however the format
// spells it.
//
// Both formats carry a file-level #CREDIT header. Per chart, they diverge: an
// SSC gives each chart its own #CREDIT tag inside a #NOTEDATA section, while
// an SM buries the author in the second field of the #NOTES block -- the
// colon-separated "description" slot, which in practice is where old packs
// put the charter's name when they put it anywhere at all.
func simfileCredits(name, body string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(raw string) {
		v := strings.TrimSpace(raw)
		if v == "" {
			return
		}
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}

	// The file-level header, common to both formats. tagString finds the
	// FIRST #CREDIT:, which in an SSC is the header one -- #NOTEDATA sections
	// come after it and are read separately below.
	if v, ok := tagString(body, "CREDIT"); ok {
		add(v)
	}

	switch strings.ToLower(path.Ext(name)) {
	case ".ssc":
		// every per-chart section, each with its own optional #CREDIT
		rest := body
		for {
			i := strings.Index(rest, "#NOTEDATA")
			if i < 0 {
				break
			}
			rest = rest[i+len("#NOTEDATA"):]
			section := rest
			if j := strings.Index(section, "#NOTEDATA"); j >= 0 {
				section = section[:j]
			}
			if v, ok := tagString(section, "CREDIT"); ok {
				add(v)
			}
		}
	case ".sm":
		// #NOTES: chart-type : description : difficulty : meter : ...
		// The second field is the author slot.
		rest := body
		for {
			i := strings.Index(rest, "#NOTES")
			if i < 0 {
				break
			}
			rest = rest[i+len("#NOTES"):]
			fields := strings.SplitN(rest, ":", 4)
			if len(fields) >= 3 {
				add(fields[2])
			}
		}
	}

	sort.Strings(out)
	return out
}
