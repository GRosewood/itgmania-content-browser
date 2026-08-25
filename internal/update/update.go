// Package update checks whether a newer content browser has been published and
// installs the module half of it in place.
//
// Only the module is replaced in-game. The helper binary is the thing running
// the update, and on Windows a running executable cannot be overwritten -- so
// when a release needs a newer helper too, this says so and points at the
// installer rather than half-applying itself. Everything the player actually
// sees is Lua and artwork, which makes a module-only update the ordinary case
// and a helper bump the rare one.
package update

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ModuleFile is the one file a payload must contain to be a content browser.
// An archive without it is rejected before anything is written.
const ModuleFile = "ITGmania Content Browser.lua"

// maxPayload caps what will be pulled down. The real payload is a few hundred
// kilobytes; this is loose enough never to matter and tight enough that a wrong
// URL cannot fill a disk.
const maxPayload = 32 << 20

// Manifest is the JSON published at the manifest URL.
//
//	{
//	  "version": "0.2",
//	  "notes": "Chart previews now show doubles.",
//	  "module": { "url": "https://.../module-0.2.zip", "sha256": "..." },
//	  "minHelper": "0.1"
//	}
type Manifest struct {
	Version string `json:"version"`
	Notes   string `json:"notes"`
	Module  struct {
		URL    string `json:"url"`
		SHA256 string `json:"sha256"`
		Bytes  int64  `json:"bytes"`
	} `json:"module"`
	// MinHelper is the oldest helper that can run the new module. A release
	// that changes what the module asks the helper for raises it, and the
	// browser then says "run the installer" instead of updating in place.
	MinHelper string `json:"minHelper"`
}

// State is what the browser is told about updates.
type State struct {
	Current   string `json:"current"`
	Latest    string `json:"latest"`
	Notes     string `json:"notes"`
	Available bool   `json:"available"`
	// InGame is whether pressing the button can finish the job. When it is
	// false, Reason says what the player has to do instead.
	InGame bool   `json:"inGame"`
	Reason string `json:"reason,omitempty"`
	Error  string `json:"error,omitempty"`
}

// Progress is the running commentary on an update in flight.
type Progress struct {
	Phase   string  `json:"phase"` // checking, downloading, verifying, writing, done, error
	Pct     float64 `json:"pct"`   // 0..1, or -1 when the size is not known
	Version string  `json:"version,omitempty"`
	Error   string  `json:"error,omitempty"`
	Done    bool    `json:"done"`
}

// Writer puts a payload on disk. helper wiring passes installer.CopyModuleFiles;
// the tests pass their own. It is a field rather than a direct call so this
// package does not depend on the installer.
type Writer func(dir string, files fs.FS, progress func(done, total int)) ([]string, error)

// Checker fetches the manifest, caches the answer, and runs the update.
type Checker struct {
	// URL is where the manifest lives.
	URL string
	// Version is what this build calls itself. It is the FALLBACK answer to
	// "what module is installed", used only when the module carries no
	// VERSION stamp of its own -- installs that predate the stamp. It is set
	// once and never written again: the durable answer lives on disk, where a
	// helper restart cannot lose it.
	Version string
	// HelperVersion is what the running helper calls itself. It is normally
	// the same as Version and differs only on a machine where the module was
	// updated in place and the helper was not.
	HelperVersion string
	// ModulesDir is where the payload is written.
	ModulesDir string
	// Write puts the payload there.
	Write Writer
	// TTL is how long a check is reused. Zero means one hour.
	TTL time.Duration
	// Client is the HTTP client. Zero means a thirty second one.
	Client *http.Client

	mu       sync.Mutex
	cached   State
	cachedAt time.Time
	job      *Progress
}

// New returns a Checker ready to serve.
func New(manifestURL, version, modulesDir string, write Writer) *Checker {
	return &Checker{
		URL:           manifestURL,
		Version:       version,
		HelperVersion: version,
		ModulesDir:    modulesDir,
		Write:         write,
	}
}

func (c *Checker) ttl() time.Duration {
	if c.TTL > 0 {
		return c.TTL
	}
	return time.Hour
}

func (c *Checker) client() *http.Client {
	if c.Client != nil {
		return c.Client
	}
	return &http.Client{Timeout: 30 * time.Second}
}

// installed is what module is actually on this machine, read from the VERSION
// stamp the payload ships inside its parts folder.
//
// This file is the fix for a whole class of amnesia: the helper cannot update
// its own binary, so after an in-game module update the only place the new
// version number used to live was the memory of this process -- and the next
// helper restart forgot it, resurrecting "update available" forever and
// re-downloading a zip that was already installed. The stamp travels WITH the
// module -- the installer copies it, the in-game update writes it, uninstall
// removes it -- so whoever reads it gets the truth however this process has
// been recycled.
//
// The theme never loads it: Simply Love only loadfile()s names ending in
// .lua, which is the same reason the parts folder itself is invisible to it.
func (c *Checker) installed() string {
	stamp, err := os.ReadFile(c.stampPath())
	if err == nil {
		if v := strings.TrimSpace(string(stamp)); v != "" {
			return v
		}
	}
	return c.Version
}

func (c *Checker) stampPath() string {
	return filepath.Join(c.ModulesDir, strings.TrimSuffix(ModuleFile, ".lua"), "VERSION")
}

// State reports what is known about updates, fetching the manifest if the last
// answer has gone stale.
//
// A failed check is not an error to the caller: not being able to reach the
// manifest is the normal condition of a cabinet on a closed network, and the
// browser should draw itself the way it always does rather than show a fault.
func (c *Checker) State(ctx context.Context) State {
	c.mu.Lock()
	if !c.cachedAt.IsZero() && time.Since(c.cachedAt) < c.ttl() {
		out := c.cached
		c.mu.Unlock()
		return out
	}
	c.mu.Unlock()

	cur := c.installed()
	st := State{Current: cur}
	man, err := c.fetch(ctx)
	if err != nil {
		st.Error = err.Error()
	} else {
		st.Latest = man.Version
		st.Notes = man.Notes
		st.Available = Newer(man.Version, cur)
		st.InGame, st.Reason = c.canApply(man)
	}

	c.mu.Lock()
	// An update may have finished while the fetch was out. If the installed
	// version moved, this answer was computed against the old one -- hand it
	// back uncached rather than pinning a stale "update available" for a
	// whole TTL.
	if c.installed() == cur {
		c.cached, c.cachedAt = st, time.Now()
	}
	c.mu.Unlock()
	return st
}

// canApply reports whether this manifest can be installed without the player
// running the installer again, and why not when it cannot.
func (c *Checker) canApply(man Manifest) (bool, string) {
	if man.Module.URL == "" {
		return false, "this release is not published as an in-game update"
	}
	if man.Module.SHA256 == "" {
		return false, "this release has no checksum to verify against"
	}
	if man.MinHelper != "" && Newer(man.MinHelper, c.HelperVersion) {
		return false, "this release needs a newer helper -- run the installer once"
	}
	if c.ModulesDir == "" || c.Write == nil {
		return false, "the module directory could not be found"
	}
	return true, ""
}

func (c *Checker) fetch(ctx context.Context) (Manifest, error) {
	var man Manifest
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.URL, nil)
	if err != nil {
		return man, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.client().Do(req)
	if err != nil {
		return man, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return man, fmt.Errorf("manifest: http %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return man, err
	}
	if err := json.Unmarshal(body, &man); err != nil {
		return man, fmt.Errorf("manifest: %w", err)
	}
	if man.Version == "" {
		return man, fmt.Errorf("manifest: no version")
	}
	return man, nil
}

// Progress reports the update in flight, or nil when none has been started.
func (c *Checker) Progress() *Progress {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.job == nil {
		return nil
	}
	out := *c.job
	return &out
}

// Start begins an update and returns at once. A second call while one is
// already running is ignored rather than queued.
func (c *Checker) Start() {
	c.mu.Lock()
	if c.job != nil && !c.job.Done {
		c.mu.Unlock()
		return
	}
	c.job = &Progress{Phase: "checking", Pct: -1}
	c.mu.Unlock()

	go c.run()
}

func (c *Checker) set(p Progress) {
	c.mu.Lock()
	c.job = &p
	c.mu.Unlock()
}

func (c *Checker) fail(format string, args ...any) {
	c.set(Progress{Phase: "error", Pct: -1, Done: true,
		Error: fmt.Sprintf(format, args...)})
}

func (c *Checker) run() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	man, err := c.fetch(ctx)
	if err != nil {
		c.fail("could not reach the update: %v", err)
		return
	}
	if ok, why := c.canApply(man); !ok {
		c.fail("%s", why)
		return
	}
	if cur := c.installed(); !Newer(man.Version, cur) {
		c.set(Progress{Phase: "done", Pct: 1, Done: true, Version: cur})
		return
	}

	// ---- download ------------------------------------------------------
	c.set(Progress{Phase: "downloading", Pct: -1, Version: man.Version})
	blob, err := c.download(ctx, man)
	if err != nil {
		c.fail("%v", err)
		return
	}

	// ---- verify --------------------------------------------------------
	c.set(Progress{Phase: "verifying", Pct: -1, Version: man.Version})
	sum := sha256.Sum256(blob)
	if got := hex.EncodeToString(sum[:]); !strings.EqualFold(got, man.Module.SHA256) {
		c.fail("the download did not match its checksum; nothing was changed")
		return
	}

	zr, err := zip.NewReader(bytes.NewReader(blob), int64(len(blob)))
	if err != nil {
		c.fail("the download is not a readable archive: %v", err)
		return
	}
	payload, err := payloadRoot(zr)
	if err != nil {
		c.fail("%v", err)
		return
	}

	// ---- write ---------------------------------------------------------
	//
	// Past this line files are being replaced, so everything that could have
	// gone wrong has already been checked: the checksum matched, the archive
	// opened, and it holds a module.
	c.set(Progress{Phase: "writing", Pct: 0, Version: man.Version})
	_, err = c.Write(c.ModulesDir, payload, func(done, total int) {
		if total <= 0 {
			return
		}
		c.set(Progress{Phase: "writing", Version: man.Version,
			Pct: float64(done) / float64(total)})
	})
	if err != nil {
		c.fail("writing the update: %v", err)
		return
	}

	// The payload just written normally carries its own VERSION stamp; write
	// it again regardless, so even an archive from before stamps existed
	// leaves a durable record and can never start the re-offer loop. The
	// MkdirAll matters for exactly those old archives: with no parts folder
	// in the payload there is no directory to put the stamp in yet.
	if dir := filepath.Dir(c.stampPath()); os.MkdirAll(dir, 0o755) == nil {
		os.WriteFile(c.stampPath(), []byte(man.Version+"\n"), 0o644)
	}

	// The cached answer is wrong now -- the current version has moved, and
	// there is no longer an update waiting.
	c.mu.Lock()
	c.cachedAt = time.Time{}
	c.mu.Unlock()

	c.set(Progress{Phase: "done", Pct: 1, Done: true, Version: man.Version})
}

func (c *Checker) download(ctx context.Context, man Manifest) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, man.Module.URL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.client().Do(req)
	if err != nil {
		return nil, fmt.Errorf("downloading the update: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("downloading the update: http %d", resp.StatusCode)
	}

	total := man.Module.Bytes
	if total <= 0 {
		if n, err := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64); err == nil {
			total = n
		}
	}

	var buf bytes.Buffer
	chunk := make([]byte, 64<<10)
	for {
		n, readErr := resp.Body.Read(chunk)
		if n > 0 {
			if buf.Len()+n > maxPayload {
				return nil, fmt.Errorf("the update is larger than expected")
			}
			buf.Write(chunk[:n])
			pct := -1.0
			if total > 0 {
				pct = float64(buf.Len()) / float64(total)
				if pct > 1 {
					pct = 1
				}
			}
			c.set(Progress{Phase: "downloading", Pct: pct, Version: man.Version})
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return nil, fmt.Errorf("downloading the update: %w", readErr)
		}
	}
	return buf.Bytes(), nil
}

// payloadRoot finds the directory inside the archive that holds the module and
// returns the archive rooted there.
//
// Release zips get built in different ways -- straight from the payload folder,
// from a checkout with the path still on the front, from a directory named for
// the version -- and all of them are fine as long as the module is somewhere
// inside. Anchoring on the module file rather than on a fixed prefix means the
// archive can be produced however is convenient.
func payloadRoot(zr *zip.Reader) (fs.FS, error) {
	best := ""
	found := false
	for _, f := range zr.File {
		if path.Base(f.Name) != ModuleFile {
			continue
		}
		dir := path.Dir(f.Name)
		// the shallowest match, so a stray copy deeper in cannot win
		if !found || len(dir) < len(best) {
			best, found = dir, true
		}
	}
	if !found {
		return nil, fmt.Errorf("the download does not contain %s", ModuleFile)
	}
	if best == "." {
		return zr, nil
	}
	return fs.Sub(zr, best)
}

// Newer reports whether version a is later than version b.
//
// Versions here are dotted numbers -- 0.1, 0.2, 1.0.3 -- compared field by
// field, so 0.10 is later than 0.9 rather than earlier as a string compare
// would have it. A field that is not a number counts as zero, which makes an
// unreadable version look older and so never triggers an update on its own.
func Newer(a, b string) bool {
	return compare(a, b) > 0
}

func compare(a, b string) int {
	as, bs := strings.Split(trimV(a), "."), strings.Split(trimV(b), ".")
	n := len(as)
	if len(bs) > n {
		n = len(bs)
	}
	for i := 0; i < n; i++ {
		x, y := field(as, i), field(bs, i)
		if x != y {
			if x > y {
				return 1
			}
			return -1
		}
	}
	return 0
}

func trimV(s string) string {
	return strings.TrimPrefix(strings.TrimSpace(s), "v")
}

func field(parts []string, i int) int {
	if i >= len(parts) {
		return 0
	}
	// "1-rc2" and the like: take the leading digits and ignore the rest
	s := parts[i]
	end := 0
	for end < len(s) && s[end] >= '0' && s[end] <= '9' {
		end++
	}
	n, err := strconv.Atoi(s[:end])
	if err != nil {
		return 0
	}
	return n
}
