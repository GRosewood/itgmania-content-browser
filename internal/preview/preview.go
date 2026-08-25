// Package preview pulls a single song's audio out of a pack archive so the
// browser can play a sample of it, without downloading the pack.
//
// The audio a player wants to hear is the audio the pack was charted against,
// and it is already sitting in the zip on the download server. SMO serves those
// with Accept-Ranges, and a zip is designed to be read back-to-front -- the
// directory of entries lives at the end -- so archive/zip driven by an
// io.ReaderAt made of range requests can list a hundred-megabyte pack from
// about a hundred kilobytes and then inflate one entry out of the middle of it.
// A representative pack: 100.6 MB on the server, 4.1 MB pulled, 1.2 seconds.
//
// The simfile next to the audio names the sample the pack's author chose --
// #SAMPLESTART and #SAMPLELENGTH, the same fields the music wheel uses -- so
// what the browser plays is the author's own sample of the author's own audio.
package preview

import (
	"archive/zip"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	// Range requests are fetched and cached in blocks, because archive/zip
	// reads the directory in small pieces -- scanning backwards for the
	// end-of-directory record, then walking entry headers field by field. Left
	// unbuffered, every field costs a round trip and listing a pack takes
	// minutes instead of half a second.
	block = 1 << 19 // 512 KB

	// A song's audio. Anything past this is not a song and is not worth the
	// bandwidth of finding out.
	maxAudioBytes = 30 << 20

	// Simfiles are text and small; the cap is only here so a malformed entry
	// cannot make us inflate forever.
	maxSimfileBytes = 4 << 20

	// How many extracted previews to keep on disk before the oldest go.
	maxCached = 12

	// How many packs keep their archive index in memory. Reading that index is
	// most of the cost of the first sample out of a pack -- a HEAD, then a walk
	// back through the end of the zip -- and none of it changes between songs,
	// so holding onto it makes every sample after the first roughly a single
	// ranged read of the audio.
	maxPacks = 3
)

// Sample is one extracted song preview.
type Sample struct {
	Path   string  `json:"path"`   // where the audio was written, as an OS path
	Name   string  `json:"name"`   // just the filename, for the game's own VFS
	Title  string  `json:"title"`  // the song folder it came from
	Start  float64 `json:"start"`  // #SAMPLESTART, seconds into the file
	Length float64 `json:"length"` // #SAMPLELENGTH, seconds
	BPM    float64 `json:"bpm"`    // the song's tempo, for anything that wants to move with it
	Bytes  int64   `json:"bytes"`
	// Every difficulty of this song, with what each is doing during the
	// sample window -- so the browser can show the song being played rather
	// than only describe it, and can switch difficulty without asking again.
	// Empty when the simfile carried no tempo or no dance chart at all.
	Charts []ChartData `json:"charts,omitempty"`
	// Preview is true when the audio is the song's own preview clip -- an SSC
	// #PREVIEW file -- rather than a window cut out of the full song. Such a
	// clip is played from its start, because that is what it is.
	Preview bool `json:"preview,omitempty"`
}

// Progress is what an extraction currently running looks like from outside. It
// is read while Get is still working, so it lives behind its own lock rather
// than the one Get holds for the whole fetch.
type Progress struct {
	Active bool    `json:"active"`
	Phase  string  `json:"phase"` // index | audio | writing
	Song   string  `json:"song"`
	Done   int64   `json:"done"`
	Total  int64   `json:"total"`
	Frac   float64 `json:"frac"` // 0..1, or -1 when the total is not known yet
}

// archive is one pack's zip index, kept between songs.
type archive struct {
	ra     *rangeReaderAt
	files  []*zip.File // every entry, for callers that want more than the audio
	songs  []song
	titles map[string]string // normalised #TITLE -> folder, built on demand
	// The blocks the index itself needed. Everything else a fetch pulled in is
	// one song's audio and is dropped afterwards, or the cache would grow by a
	// few megabytes per sample played.
	dirBlocks map[int64]bool
}

// trimBlocks forgets the blocks that were pulled for entry data, keeping the
// index resident.
func (a *archive) trimBlocks() {
	for idx := range a.ra.blocks {
		if !a.dirBlocks[idx] {
			delete(a.ra.blocks, idx)
		}
	}
}

// Fetcher extracts previews into a directory it owns.
type Fetcher struct {
	Dir       string // where extracted audio is written
	Base      string // download host, e.g. https://stepmaniaonline.net
	Client    *http.Client
	mu        sync.Mutex
	cache     map[string]Sample
	recency   []string // cache keys, oldest first
	packs     map[int]*archive
	credits   map[int]PackCredits // per pack, because a scan is one ranged read per song
	packOrder []int               // packIds, oldest first
	locks     map[int]*sync.Mutex // one per pack; mu guards only the map itself

	// Progress is written by the running extraction and read by whoever asks,
	// so it cannot sit behind mu -- that one is held for the whole fetch.
	pmu      sync.Mutex
	progress Progress
}

func (f *Fetcher) setProgress(p Progress) {
	f.pmu.Lock()
	f.progress = p
	f.pmu.Unlock()
}

func (f *Fetcher) advance(done int64) {
	f.pmu.Lock()
	f.progress.Done = done
	if f.progress.Total > 0 {
		f.progress.Frac = float64(done) / float64(f.progress.Total)
		if f.progress.Frac > 1 {
			f.progress.Frac = 1
		}
	}
	f.pmu.Unlock()
}

// Progress reports the extraction currently in flight, if any.
func (f *Fetcher) Progress() Progress {
	f.pmu.Lock()
	defer f.pmu.Unlock()
	return f.progress
}

// New returns a Fetcher writing into dir.
func New(dir, base string) *Fetcher {
	return &Fetcher{
		Dir:    dir,
		Base:   strings.TrimSuffix(base, "/"),
		Client: &http.Client{Timeout: 90 * time.Second},
		cache:  map[string]Sample{},
		packs:  map[int]*archive{},
		locks:  map[int]*sync.Mutex{},
	}
}

// lockPack hands back the mutex that serializes work on ONE pack, leaving
// every other pack free to answer.
//
// The whole-fetcher lock this replaces was held across entire extractions --
// which meant a background single-song install, a multi-megabyte download,
// stood in front of every preview, packini and credits request for any pack
// at all, and behind those the game's single serial HTTP worker. Work on the
// same pack still queues, because it shares one archive and one block cache;
// work on different packs no longer meets.
//
// The map only grows -- one small mutex per distinct pack touched this
// session -- and mu guards the map alone, never the work.
func (f *Fetcher) lockPack(packID int) *sync.Mutex {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.locks == nil {
		f.locks = map[int]*sync.Mutex{}
	}
	l := f.locks[packID]
	if l == nil {
		l = &sync.Mutex{}
		f.locks[packID] = l
	}
	return l
}

// -------------------------------------------------------- range-backed reader

type rangeReaderAt struct {
	url    string
	size   int64
	client *http.Client
	blocks map[int64][]byte
	pulled int64
	onPull func(total int64) // called with the running total after each block
}

func (r *rangeReaderAt) fetch(idx int64) ([]byte, error) {
	if b, ok := r.blocks[idx]; ok {
		return b, nil
	}
	start := idx * block
	end := start + block - 1
	if end >= r.size {
		end = r.size - 1
	}
	req, err := http.NewRequest(http.MethodGet, r.url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
	resp, err := r.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		return nil, fmt.Errorf("server would not serve a range (%s)", resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, block))
	if err != nil {
		return nil, err
	}
	// A block that came back short would poison everything after it: ReadAt
	// slices into blocks at pos%block, and a short one both panics on that
	// slice and, once cached, keeps doing so forever. Refuse it here, where
	// it is one failed request instead of a crash.
	if int64(len(b)) != end-start+1 {
		return nil, fmt.Errorf("range %d-%d answered with %d bytes", start, end, len(b))
	}
	r.blocks[idx] = b
	r.pulled += int64(len(b))
	if r.onPull != nil {
		r.onPull(r.pulled)
	}
	return b, nil
}

func (r *rangeReaderAt) ReadAt(p []byte, off int64) (int, error) {
	got := 0
	for got < len(p) {
		pos := off + int64(got)
		if pos >= r.size {
			return got, io.EOF
		}
		b, err := r.fetch(pos / block)
		if err != nil {
			return got, err
		}
		n := copy(p[got:], b[pos%block:])
		if n == 0 {
			return got, io.EOF
		}
		got += n
	}
	return got, nil
}

// --------------------------------------------------------------- name matching

// normalize reduces a title to the letters and digits in it, so that "Stupid
// For You" matches a folder called "stupid_for_you" or "[16] Stupid For You".
func normalize(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		// Any letter or digit, not just ASCII. Keeping only [a-z0-9] reduced
		// every fully non-Latin title -- CJK, kana, Cyrillic, a real slice of
		// the catalogue -- to an empty key, and an empty key matches nothing:
		// those songs could never be previewed or single-installed at all.
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func isAudio(name string) bool {
	switch strings.ToLower(path.Ext(name)) {
	case ".ogg", ".mp3", ".wav":
		return true
	}
	return false
}

func isSimfile(name string) bool {
	switch strings.ToLower(path.Ext(name)) {
	case ".ssc", ".sm":
		return true
	}
	return false
}

// song is one folder inside the pack: its audio and its simfile.
type song struct {
	dir     string
	audio   *zip.File
	simfile *zip.File
}

// collect groups the archive's entries by the folder each one sits in. Depth is
// not assumed: a song is any folder that has audio in it.
func collect(files []*zip.File) []song {
	byDir := map[string]*song{}
	for _, f := range files {
		name := f.Name
		if strings.HasSuffix(name, "/") {
			continue
		}
		// Mac archive noise, and anything hidden.
		if strings.Contains(name, "__MACOSX/") || strings.HasPrefix(path.Base(name), ".") {
			continue
		}
		dir := path.Dir(name)
		switch {
		case isAudio(name):
			s := byDir[dir]
			if s == nil {
				s = &song{dir: dir}
				byDir[dir] = s
			}
			// Prefer the smallest audio in a folder: packs sometimes ship a
			// full track next to a short preview clip, and where there is a
			// choice the clip is the better sample and the cheaper fetch.
			if s.audio == nil || f.CompressedSize64 < s.audio.CompressedSize64 {
				s.audio = f
			}
		case isSimfile(name):
			s := byDir[dir]
			if s == nil {
				s = &song{dir: dir}
				byDir[dir] = s
			}
			// .ssc wins over .sm when a folder has both.
			if s.simfile == nil || strings.EqualFold(path.Ext(name), ".ssc") {
				s.simfile = f
			}
		}
	}

	out := make([]song, 0, len(byDir))
	for _, s := range byDir {
		if s.audio != nil && s.audio.UncompressedSize64 <= maxAudioBytes {
			out = append(out, *s)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].dir < out[j].dir })
	return out
}

// pick finds the song folder that best answers to title. Exact normalized
// equality first, then containment either way, longest match winning so that
// "Stupid For You" prefers its own folder over one merely containing it.
func pick(songs []song, title string) (song, bool) {
	want := normalize(title)
	if want == "" {
		return song{}, false
	}
	var best song
	bestScore := -1
	for _, s := range songs {
		got := normalize(path.Base(s.dir))
		score := -1
		switch {
		case got == want:
			score = 1 << 20
		case strings.Contains(got, want):
			score = len(want)
		case strings.Contains(want, got):
			score = len(got)
		}
		if score > bestScore {
			best, bestScore = s, score
		}
	}
	// A containment match on a couple of characters is a coincidence, not a
	// match. Require either exact, or enough overlap to mean something.
	if bestScore >= 1<<20 || bestScore >= 4 {
		return best, true
	}
	return song{}, false
}

// ------------------------------------------------------------ simfile parsing

// tempo reads a usable BPM out of simfile text. #DISPLAYBPM is what the author
// wanted shown, so it wins; otherwise the first entry of #BPMS, which is the
// tempo the song opens at. A range ("150:170") reduces to its low end -- one
// number is all a pulse needs.
func tempo(body string) float64 {
	if v, ok := tagString(body, "DISPLAYBPM"); ok {
		v = strings.TrimSpace(v)
		if i := strings.IndexAny(v, ":-"); i > 0 {
			v = v[:i]
		}
		if f, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil && f > 0 {
			return f
		}
	}
	if v, ok := tagString(body, "BPMS"); ok {
		// "0.000=150.000,32.000=175.000" -- take the first beat=bpm pair
		if i := strings.IndexByte(v, ','); i >= 0 {
			v = v[:i]
		}
		if i := strings.IndexByte(v, '='); i >= 0 {
			if f, err := strconv.ParseFloat(strings.TrimSpace(v[i+1:]), 64); err == nil && f > 0 {
				return f
			}
		}
	}
	return 0
}

// tagString reads the raw text of a #TAG:value; pair.
func tagString(body, tag string) (string, bool) {
	i := strings.Index(body, "#"+tag+":")
	if i < 0 {
		return "", false
	}
	rest := body[i+len(tag)+2:]
	if j := strings.IndexByte(rest, ';'); j >= 0 {
		rest = rest[:j]
	}
	return rest, true
}

// tagFloat reads a #TAG:value; pair out of simfile text.
func tagFloat(body, tag string) (float64, bool) {
	i := strings.Index(body, "#"+tag+":")
	if i < 0 {
		return 0, false
	}
	rest := body[i+len(tag)+2:]
	if j := strings.IndexByte(rest, ';'); j >= 0 {
		rest = rest[:j]
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(rest), 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

// ------------------------------------------------------------------- fetching

func (f *Fetcher) packURL(packID int) string {
	return fmt.Sprintf("%s/download/pack/%d/", f.Base, packID)
}

func cacheKey(packID int, title string) string {
	return fmt.Sprintf("%d/%s", packID, normalize(title))
}

// Get extracts the named song's audio from the pack and returns where it landed.
// Repeat calls for the same song reuse the file already on disk.
func (f *Fetcher) Get(packID int, title string) (Sample, error) {
	if packID <= 0 {
		return Sample{}, fmt.Errorf("no pack given")
	}
	if strings.TrimSpace(title) == "" {
		return Sample{}, fmt.Errorf("no song given")
	}

	// One at a time. The browser only ever plays one preview, and serialising
	// keeps a held-down key from starting a dozen multi-megabyte fetches.
	l := f.lockPack(packID)
	l.Lock()
	defer l.Unlock()

	key := cacheKey(packID, title)
	f.mu.Lock()
	if s, ok := f.cache[key]; ok {
		if _, err := os.Stat(s.Path); err == nil {
			f.mu.Unlock()
			return s, nil
		}
		// The file went away underneath us -- a hand-emptied cache folder,
		// an eager cleanup tool. The recency entry has to go with it, or the
		// re-extraction below appends the same key twice and the LRU's count
		// drifts away from what is actually on disk.
		delete(f.cache, key)
		for i, k := range f.recency {
			if k == key {
				f.recency = append(f.recency[:i], f.recency[i+1:]...)
				break
			}
		}
	}
	f.mu.Unlock()

	f.setProgress(Progress{Active: true, Phase: "index", Song: title, Frac: -1})
	defer f.setProgress(Progress{})

	sample, err := f.extract(packID, title)
	if err != nil {
		return Sample{}, err
	}
	f.mu.Lock()
	f.cache[key] = sample
	f.recency = append(f.recency, key)
	f.trim()
	f.mu.Unlock()
	return sample, nil
}

// openPack returns the pack's archive index, reading it only the first time.
//
// The caller holds this pack's lock, which is what stops two builders racing
// on one pack; mu is taken only around the map touches, so the network reads
// in the middle hold nothing anybody else wants.
func (f *Fetcher) openPack(packID int) (*archive, error) {
	f.mu.Lock()
	a := f.packs[packID]
	f.mu.Unlock()
	if a != nil {
		return a, nil
	}
	url := f.packURL(packID)

	head, err := f.Client.Head(url)
	if err != nil {
		return nil, fmt.Errorf("could not reach the download server: %w", err)
	}
	head.Body.Close()
	if head.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the pack is not downloadable (%s)", head.Status)
	}
	if !strings.Contains(strings.ToLower(head.Header.Get("Accept-Ranges")), "bytes") {
		return nil, fmt.Errorf("the download server will not serve part of a file")
	}
	size, err := strconv.ParseInt(head.Header.Get("Content-Length"), 10, 64)
	if err != nil || size <= 0 {
		return nil, fmt.Errorf("the download server did not say how big the pack is")
	}

	ra := &rangeReaderAt{url: url, size: size, client: f.Client, blocks: map[int64][]byte{}}
	zr, err := zip.NewReader(ra, size)
	if err != nil {
		return nil, fmt.Errorf("could not read the pack's contents: %w", err)
	}
	songs := collect(zr.File)
	if len(songs) == 0 {
		return nil, fmt.Errorf("no audio in this pack")
	}

	dir := map[int64]bool{}
	for idx := range ra.blocks {
		dir[idx] = true
	}
	a = &archive{ra: ra, files: zr.File, songs: songs, dirBlocks: dir}

	f.mu.Lock()
	f.packs[packID] = a
	f.packOrder = append(f.packOrder, packID)
	for len(f.packOrder) > maxPacks {
		// Eviction only forgets the map entry. A goroutine still working on
		// the evicted pack holds its own pointer and finishes unharmed; the
		// memory goes when the last holder does.
		delete(f.packs, f.packOrder[0])
		f.packOrder = f.packOrder[1:]
	}
	f.mu.Unlock()
	return a, nil
}

func (f *Fetcher) extract(packID int, title string) (Sample, error) {
	a, err := f.openPack(packID)
	if err != nil {
		return Sample{}, err
	}
	// Whatever path this leaves by -- including "could not find the song"
	// after the title matcher has read every simfile -- the block cache goes
	// back to just the archive directory.
	defer a.trimBlocks()
	ra := a.ra
	indexBytes := int64(0)
	found, ok := f.find(a, title)
	if !ok {
		return Sample{}, fmt.Errorf("could not find %q in the pack", title)
	}

	// The sample window and the tempo the pack's author chose, if the simfile
	// says. The tempo is not needed to play anything -- it is there so the
	// browser can move something in time with what is coming out.
	start, length, bpm := 0.0, 0.0, 0.0
	var charts []ChartData
	// Which audio to take. The song's music unless the simfile names a preview
	// clip of its own, which is the thing the author actually chose to have
	// heard -- and is usually a fraction of the size, so it arrives sooner too.
	audio := found.audio
	preview := false
	if found.simfile != nil && found.simfile.UncompressedSize64 <= maxSimfileBytes {
		if body, err := readEntry(found.simfile, maxSimfileBytes); err == nil {
			text := string(body)
			if v, ok := tagFloat(text, "SAMPLESTART"); ok {
				start = v
			}
			if v, ok := tagFloat(text, "SAMPLELENGTH"); ok {
				length = v
			}
			bpm = tempo(text)

			// A tag is text somebody typed, and "nan" and "inf" both parse as
			// float64s. They pass every "is it positive" test, reach the JSON
			// encoder, and fail it -- which the caller sees as a 200 with an
			// empty body and nothing at all to say what went wrong. So the
			// window is made a real number before anything else uses it.
			if !finite(start) || start < 0 {
				start = 0
			}
			if !finite(length) || length < 0 {
				length = 0
			}
			if !finite(bpm) || bpm < 0 {
				bpm = 0
			}

			// A pack that never declared a sample still gets one: a little way
			// in, which is where a song has usually started doing something.
			// Decided here rather than in the browser, so that the window the
			// audio plays and the window the notes come from are the same one.
			if length <= 0 {
				if start < 20 {
					start = 20
				}
				length = 20
			}
			charts = chartsForWindow(text, start, length)

			// #PREVIEW names a file beside the simfile. Taken only when it is
			// really there and really audio: the tag outlives edits, and a
			// missing clip should fall back to the song rather than fail.
			//
			// The note window is left as the simfile declared it. A preview
			// clip is normally cut from exactly that stretch, so the steps
			// scrolling past are the steps being played; where an author
			// supplied one without saying where it came from, this is still the
			// best either of us can do -- the game itself knows no better.
			if name, ok := tagString(text, "PREVIEW"); ok {
				if clip := findBeside(a, found.dir, name); clip != nil {
					audio, preview = clip, true
				}
			}
		}
	}

	// From here the work is a known size, so the bar can mean something. What
	// has already been spent on the index and the simfile is subtracted out,
	// otherwise the bar would start somewhere past zero.
	indexBytes = ra.pulled
	f.setProgress(Progress{
		Active: true, Phase: "audio", Song: title,
		Total: int64(audio.CompressedSize64), Frac: 0,
	})
	ra.onPull = func(total int64) { f.advance(total - indexBytes) }

	body, err := readEntry(audio, maxAudioBytes)
	ra.onPull = nil
	if err != nil {
		return Sample{}, fmt.Errorf("could not read the song's audio: %w", err)
	}
	f.setProgress(Progress{Active: true, Phase: "writing", Song: title, Frac: 1})

	if err := os.MkdirAll(f.Dir, 0o755); err != nil {
		return Sample{}, err
	}
	// Named from the pack and song rather than from the entry, so nothing out
	// of the archive ever reaches the filesystem as a path.
	sum := sha1.Sum([]byte(cacheKey(packID, title)))
	name := "preview-" + hex.EncodeToString(sum[:8]) + strings.ToLower(path.Ext(audio.Name))
	out := filepath.Join(f.Dir, name)
	if err := os.WriteFile(out, body, 0o644); err != nil {
		return Sample{}, err
	}

	return Sample{
		Path:    out,
		Name:    name,
		Title:   path.Base(found.dir),
		Start:   start,
		Length:  length,
		BPM:     bpm,
		Charts:  charts,
		Preview: preview,
		Bytes:   int64(len(body)),
	}, nil
}

// findBeside is the file a simfile tag names, in the song's own folder.
//
// Case-insensitive on the whole path, because a tag is typed by hand and the
// archive was probably built on a case-insensitive filesystem where the
// difference never showed. Any directory part in the tag is dropped: the tag
// addresses the song's folder, and honouring a path from it would let a
// simfile reach anywhere in the archive.
func findBeside(a *archive, dir, name string) *zip.File {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	name = path.Base(strings.ReplaceAll(name, "\\", "/"))
	if name == "" || name == "." || name == ".." {
		return nil
	}
	for _, file := range a.files {
		if file.FileInfo().IsDir() {
			continue
		}
		if !strings.EqualFold(path.Dir(file.Name), dir) {
			continue
		}
		if strings.EqualFold(path.Base(file.Name), name) && isAudio(file.Name) {
			return file
		}
	}
	return nil
}

// SongInstall is one song lifted out of a pack and put somewhere playable.
type SongInstall struct {
	Song   string `json:"song"`
	Folder string `json:"folder"`
	Sync   string `json:"sync"`
	Files  int    `json:"files"`
	Bytes  int64  `json:"bytes"`
}

// packSync reads the sync the pack declares for itself.
// Where reports the folder a song landed in and the sync that decided it.
func (s SongInstall) Where() (string, string) { return s.Folder, s.Sync }

// packSync is the sync a pack states for itself.
//
// A song taken out of a pack keeps the pack's sync, and the pack states it in
// its own Pack.ini. Without one the answer is ITG: that is what packs carried
// before Pack.ini existed to say otherwise, and it is what the engine applies
// by default anyway.
func packSync(files []*zip.File) string {
	for _, f := range files {
		if !strings.EqualFold(path.Base(f.Name), "pack.ini") {
			continue
		}
		// the pack's own, at the top of the archive -- not one inside a song
		if strings.Count(strings.Trim(f.Name, "/"), "/") > 1 {
			continue
		}
		body, err := readEntry(f, maxSimfileBytes)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(body), "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(strings.ToLower(line), "syncoffset") {
				continue
			}
			if j := strings.Index(line, "="); j > 0 {
				switch strings.ToUpper(strings.TrimSpace(line[j+1:])) {
				case "NULL":
					return "NULL"
				case "ITG":
					return "ITG"
				}
			}
		}
	}
	return "ITG"
}

// ensureSinglesPack makes the folder singles land in, and gives it a Pack.ini
// so the engine applies the right offset to everything inside. Songs are
// grouped by the sync they were authored with precisely so that one file can
// be right for all of them.
func ensureSinglesPack(dir, sync string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	ini := filepath.Join(dir, "Pack.ini")
	if _, err := os.Stat(ini); err == nil {
		return nil
	}
	body := "[Group]\n" +
		"# Written by the ITGmania Content Browser.\n" +
		"# Songs downloaded one at a time land here, grouped by the sync they\n" +
		"# were authored with, so this offset is right for every song in it.\n" +
		"Version=1\n" +
		"SyncOffset=" + sync + "\n"
	return os.WriteFile(ini, []byte(body), 0o644)
}

// InstallSong copies one song out of a pack into the singles folder for its
// sync, without downloading the pack. The archive index is the same one the
// audio previews use, so a song from a pack already previewed costs only the
// ranged reads its own files need.
func (f *Fetcher) InstallSong(packID int, title, root, sync string) (SongInstall, error) {
	if packID <= 0 || strings.TrimSpace(title) == "" {
		return SongInstall{}, fmt.Errorf("no song given")
	}

	l := f.lockPack(packID)
	l.Lock()
	defer l.Unlock()

	a, err := f.openPack(packID)
	if err != nil {
		return SongInstall{}, err
	}
	defer a.trimBlocks()
	found, ok := f.find(a, title)
	if !ok {
		return SongInstall{}, fmt.Errorf("could not find %q in the pack", title)
	}

	if sync != "ITG" && sync != "NULL" {
		sync = packSync(a.files)
	}
	folder := "Content Browser Singles - " + sync + " Sync"
	dest := filepath.Join(root, folder)
	if err := ensureSinglesPack(dest, sync); err != nil {
		return SongInstall{}, err
	}

	songName := path.Base(found.dir)
	songDir := filepath.Join(dest, songName)
	if err := os.MkdirAll(songDir, 0o755); err != nil {
		return SongInstall{}, err
	}

	prefix := found.dir + "/"
	var count int
	var written int64
	for _, e := range a.files {
		if e.FileInfo().IsDir() || !strings.HasPrefix(e.Name, prefix) {
			continue
		}
		rel := strings.TrimPrefix(e.Name, prefix)
		// the archive is someone else's data: nothing in it may climb out
		if rel == "" || strings.Contains(rel, "..") || path.IsAbs(rel) {
			continue
		}
		out := filepath.Join(songDir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return SongInstall{}, err
		}
		n, err := extractTo(e, out)
		if err != nil {
			return SongInstall{}, err
		}
		count++
		written += n
	}
	if count == 0 {
		return SongInstall{}, fmt.Errorf("%q had no files in it", songName)
	}
	return SongInstall{
		Song: songName, Folder: folder, Sync: sync,
		Files: count, Bytes: written,
	}, nil
}

func extractTo(f *zip.File, dest string) (int64, error) {
	rc, err := f.Open()
	if err != nil {
		return 0, err
	}
	defer rc.Close()
	out, err := os.Create(dest)
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(out, rc)
	// Close is where a full disk finally says so -- buffered writes succeed
	// and the flush fails. Swallowing it reported a truncated file as a
	// finished one.
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return n, err
}

// find locates a song by what SMO calls it, falling back from folder names to
// the titles the simfiles themselves declare.
func (f *Fetcher) find(a *archive, title string) (song, bool) {
	if s, ok := pick(a.songs, title); ok {
		return s, true
	}
	if a.titles == nil {
		a.titles = map[string]string{}
		for _, s := range a.songs {
			if s.simfile == nil || s.simfile.UncompressedSize64 > maxSimfileBytes {
				continue
			}
			body, err := readEntry(s.simfile, maxSimfileBytes)
			if err != nil {
				continue
			}
			if v, ok := tagString(string(body), "TITLE"); ok {
				if key := normalize(v); key != "" && a.titles[key] == "" {
					a.titles[key] = s.dir
				}
			}
		}
	}
	dir := a.titles[normalize(title)]
	if dir == "" {
		return song{}, false
	}
	for _, s := range a.songs {
		if s.dir == dir {
			return s, true
		}
	}
	return song{}, false
}

func readEntry(f *zip.File, limit uint64) ([]byte, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(io.LimitReader(rc, int64(limit)))
}

// trim keeps the preview directory from growing without bound.
func (f *Fetcher) trim() {
	for len(f.recency) > maxCached {
		old := f.recency[0]
		f.recency = f.recency[1:]
		if s, ok := f.cache[old]; ok {
			os.Remove(s.Path)
			delete(f.cache, old)
		}
	}
}

// Clear removes every preview this fetcher has written.
func (f *Fetcher) Clear() {
	f.mu.Lock()
	defer f.mu.Unlock()
	// The DIRECTORY is swept, not the in-memory cache -- at startup the cache
	// is empty by definition, so walking it removed nothing, and every file a
	// crashed or killed helper left behind survived forever. Anything in this
	// folder is this fetcher's own refetchable output; all of it can go.
	if entries, err := os.ReadDir(f.Dir); err == nil {
		for _, e := range entries {
			if !e.IsDir() {
				os.Remove(filepath.Join(f.Dir, e.Name()))
			}
		}
	}
	f.cache = map[string]Sample{}
	f.recency = nil
	f.packs = map[int]*archive{}
	f.packOrder = nil
}
