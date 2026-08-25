package update

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestNewer(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"0.2", "0.1", true},
		{"0.1", "0.2", false},
		{"0.1", "0.1", false},
		// the one a string compare gets wrong
		{"0.10", "0.9", true},
		{"0.9", "0.10", false},
		{"1.0", "0.99", true},
		// a missing field is a zero, not a wildcard
		{"1.0.1", "1.0", true},
		{"1.0", "1.0.0", false},
		{"1.0.0", "1.0", false},
		// tags and prefixes
		{"v0.2", "0.1", true},
		{"0.2", "v0.1", true},
		{" 0.2 ", "0.1", true},
		{"1.0-rc2", "1.0", false},
		{"1.1-rc1", "1.0", true},
		// junk sorts old, so it can never trigger an update by itself
		{"banana", "0.1", false},
		{"0.1", "banana", true},
		{"", "0.1", false},
	}
	for _, c := range cases {
		if got := Newer(c.a, c.b); got != c.want {
			t.Errorf("Newer(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

// zipOf builds an archive from a name -> contents map.
func zipOf(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func readerOf(t *testing.T, blob []byte) *zip.Reader {
	t.Helper()
	zr, err := zip.NewReader(bytes.NewReader(blob), int64(len(blob)))
	if err != nil {
		t.Fatal(err)
	}
	return zr
}

func TestPayloadRootFindsTheModule(t *testing.T) {
	cases := []struct {
		name  string
		files map[string]string
		probe string // a path that must be readable in the returned FS
	}{
		{
			name: "at the root",
			files: map[string]string{
				ModuleFile:                    "-- module",
				"ContentBrowserIcons/pad.png": "png",
			},
			probe: ModuleFile,
		},
		{
			name: "under one folder",
			files: map[string]string{
				"payload/" + ModuleFile:               "-- module",
				"payload/ContentBrowserIcons/pad.png": "png",
			},
			probe: "ContentBrowserIcons/pad.png",
		},
		{
			name: "under a versioned checkout path",
			files: map[string]string{
				"browser-0.2/Modules/" + ModuleFile:               "-- module",
				"browser-0.2/Modules/ContentBrowserIcons/pad.png": "png",
			},
			probe: "ContentBrowserIcons/pad.png",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root, err := payloadRoot(readerOf(t, zipOf(t, c.files)))
			if err != nil {
				t.Fatalf("payloadRoot: %v", err)
			}
			if _, err := fs.ReadFile(root, c.probe); err != nil {
				t.Fatalf("reading %s from the rooted archive: %v", c.probe, err)
			}
			if _, err := fs.ReadFile(root, ModuleFile); err != nil {
				t.Fatalf("the module is not at the root: %v", err)
			}
		})
	}
}

func TestPayloadRootPrefersTheShallowestModule(t *testing.T) {
	// A backup copy buried deeper must not become the root, or the payload
	// alongside the real module would be missed.
	root, err := payloadRoot(readerOf(t, zipOf(t, map[string]string{
		"payload/" + ModuleFile:               "current",
		"payload/old/backup/" + ModuleFile:    "stale",
		"payload/ContentBrowserIcons/pad.png": "png",
	})))
	if err != nil {
		t.Fatal(err)
	}
	got, err := fs.ReadFile(root, ModuleFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "current" {
		t.Errorf("rooted on the stale copy: got %q", got)
	}
}

func TestPayloadRootRejectsAnArchiveWithNoModule(t *testing.T) {
	_, err := payloadRoot(readerOf(t, zipOf(t, map[string]string{
		"README.md": "not a module",
	})))
	if err == nil {
		t.Fatal("accepted an archive with no module in it")
	}
	if !strings.Contains(err.Error(), ModuleFile) {
		t.Errorf("the error does not name what is missing: %v", err)
	}
}

// server stands in for the publisher: a manifest and the archive it points at.
type server struct {
	*httptest.Server
	manifest atomic.Value // string
	blob     atomic.Value // []byte
	blobHits atomic.Int32
	manHits  atomic.Int32
}

func newServer(t *testing.T) *server {
	t.Helper()
	s := &server{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/update.json":
			s.manHits.Add(1)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, s.manifest.Load().(string))
		case "/module.zip":
			s.blobHits.Add(1)
			w.Write(s.blob.Load().([]byte))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

// publish sets the archive and a manifest that describes it truthfully.
func (s *server) publish(t *testing.T, version string, files map[string]string) []byte {
	t.Helper()
	blob := zipOf(t, files)
	s.blob.Store(blob)
	sum := sha256.Sum256(blob)
	man := Manifest{Version: version, Notes: "notes for " + version}
	man.Module.URL = s.URL + "/module.zip"
	man.Module.SHA256 = hex.EncodeToString(sum[:])
	man.Module.Bytes = int64(len(blob))
	raw, err := json.Marshal(man)
	if err != nil {
		t.Fatal(err)
	}
	s.manifest.Store(string(raw))
	return blob
}

func (s *server) publishRaw(t *testing.T, body string) {
	t.Helper()
	s.manifest.Store(body)
}

// newChecker returns a Checker writing into a scratch directory.
func newChecker(t *testing.T, s *server, current string) (*Checker, string) {
	t.Helper()
	dir := t.TempDir()
	c := New(s.URL+"/update.json", current, dir, func(d string, files fs.FS, progress func(done, total int)) ([]string, error) {
		var written []string
		err := fs.WalkDir(files, ".", func(p string, e fs.DirEntry, err error) error {
			if err != nil || e.IsDir() {
				return err
			}
			data, err := fs.ReadFile(files, p)
			if err != nil {
				return err
			}
			dest := filepath.Join(d, filepath.FromSlash(p))
			if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
				return err
			}
			written = append(written, p)
			return os.WriteFile(dest, data, 0o644)
		})
		if progress != nil {
			progress(len(written), len(written))
		}
		return written, err
	})
	return c, dir
}

// settle waits for the update job to finish.
func settle(t *testing.T, c *Checker) Progress {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if p := c.Progress(); p != nil && p.Done {
			return *p
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the update never finished")
	return Progress{}
}

func TestStateReportsAnAvailableUpdate(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{ModuleFile: "-- 0.2"})
	c, _ := newChecker(t, s, "0.1")

	st := c.State(context.Background())
	if st.Error != "" {
		t.Fatalf("unexpected error: %s", st.Error)
	}
	if !st.Available {
		t.Error("0.2 over 0.1 is not reported as available")
	}
	if !st.InGame {
		t.Errorf("a complete manifest is not applicable in game: %s", st.Reason)
	}
	if st.Current != "0.1" || st.Latest != "0.2" {
		t.Errorf("versions: current %q latest %q", st.Current, st.Latest)
	}
	if st.Notes != "notes for 0.2" {
		t.Errorf("notes not carried through: %q", st.Notes)
	}
}

func TestStateIsCachedUntilTheTTLPasses(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{ModuleFile: "-- 0.2"})
	c, _ := newChecker(t, s, "0.1")
	c.TTL = 50 * time.Millisecond

	c.State(context.Background())
	c.State(context.Background())
	c.State(context.Background())
	if got := s.manHits.Load(); got != 1 {
		t.Errorf("fetched the manifest %d times inside the TTL, want 1", got)
	}

	time.Sleep(60 * time.Millisecond)
	c.State(context.Background())
	if got := s.manHits.Load(); got != 2 {
		t.Errorf("fetched %d times after the TTL, want 2", got)
	}
}

func TestStateSurvivesAnUnreachableManifest(t *testing.T) {
	c := New("http://127.0.0.1:1/update.json", "0.1", t.TempDir(), nil)
	c.Client = &http.Client{Timeout: 200 * time.Millisecond}

	st := c.State(context.Background())
	if st.Error == "" {
		t.Error("a failed check reported no error")
	}
	if st.Available {
		t.Error("a failed check offered an update anyway")
	}
	if st.Latest != "" {
		t.Errorf("a failed check invented a version: %q", st.Latest)
	}
}

func TestStateRejectsAManifestWithNoVersion(t *testing.T) {
	s := newServer(t)
	s.publishRaw(t, `{"notes":"nothing here"}`)
	c, _ := newChecker(t, s, "0.1")

	if st := c.State(context.Background()); st.Error == "" || st.Available {
		t.Errorf("accepted a versionless manifest: %+v", st)
	}
}

func TestCanApplyExplainsWhatTheInstallerIsFor(t *testing.T) {
	dir := t.TempDir()
	write := func(string, fs.FS, func(int, int)) ([]string, error) { return nil, nil }
	base := func() Manifest {
		var m Manifest
		m.Version = "0.2"
		m.Module.URL = "https://example.invalid/m.zip"
		m.Module.SHA256 = "abc"
		return m
	}
	cases := []struct {
		name  string
		man   func() Manifest
		c     *Checker
		match string
	}{
		{"no url", func() Manifest { m := base(); m.Module.URL = ""; return m },
			&Checker{ModulesDir: dir, Write: write}, "not published"},
		{"no checksum", func() Manifest { m := base(); m.Module.SHA256 = ""; return m },
			&Checker{ModulesDir: dir, Write: write}, "checksum"},
		{"needs a newer helper", func() Manifest { m := base(); m.MinHelper = "0.5"; return m },
			&Checker{ModulesDir: dir, Write: write, HelperVersion: "0.1"}, "installer"},
		{"nowhere to write", base,
			&Checker{ModulesDir: "", Write: write}, "module directory"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ok, why := tc.c.canApply(tc.man())
			if ok {
				t.Fatal("said it could apply")
			}
			if !strings.Contains(why, tc.match) {
				t.Errorf("reason %q does not mention %q", why, tc.match)
			}
		})
	}

	// The same helper version is fine -- only a *newer* requirement blocks.
	c := &Checker{ModulesDir: dir, Write: write, HelperVersion: "0.1"}
	m := base()
	m.MinHelper = "0.1"
	if ok, why := c.canApply(m); !ok {
		t.Errorf("an equal minHelper blocked the update: %s", why)
	}
}

func TestStartWritesThePayload(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{
		"payload/" + ModuleFile:               "-- module 0.2",
		"payload/ContentBrowserIcons/pad.png": "pngbytes",
	})
	c, dir := newChecker(t, s, "0.1")

	c.Start()
	final := settle(t, c)
	if final.Phase != "done" {
		t.Fatalf("finished in %q: %s", final.Phase, final.Error)
	}
	if final.Version != "0.2" {
		t.Errorf("finished on version %q", final.Version)
	}

	got, err := os.ReadFile(filepath.Join(dir, ModuleFile))
	if err != nil {
		t.Fatalf("the module was not written: %v", err)
	}
	if string(got) != "-- module 0.2" {
		t.Errorf("the module holds %q", got)
	}
	if _, err := os.ReadFile(filepath.Join(dir, "ContentBrowserIcons", "pad.png")); err != nil {
		t.Errorf("the artwork beside it was not written: %v", err)
	}

	// The version has moved on, so the browser must stop offering the update.
	if st := c.State(context.Background()); st.Available {
		t.Error("still offering 0.2 after installing it")
	}
}

func TestStartRefusesAPayloadThatFailsItsChecksum(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{ModuleFile: "-- 0.2"})
	// swap the archive for a different one, leaving the manifest's checksum
	// describing the old one
	s.blob.Store(zipOf(t, map[string]string{ModuleFile: "-- tampered"}))

	c, dir := newChecker(t, s, "0.1")
	c.Start()
	final := settle(t, c)

	if final.Phase != "error" {
		t.Fatalf("a bad checksum finished in %q", final.Phase)
	}
	if !strings.Contains(final.Error, "checksum") {
		t.Errorf("the error does not say why: %q", final.Error)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("wrote %d entries despite the mismatch", len(entries))
	}
}

func TestStartRefusesAnArchiveWithoutAModule(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{"README.md": "wrong archive"})
	c, dir := newChecker(t, s, "0.1")

	c.Start()
	if final := settle(t, c); final.Phase != "error" {
		t.Fatalf("accepted an archive with no module: %q", final.Phase)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("wrote %d entries from an archive with no module", len(entries))
	}
}

func TestStartDoesNothingWhenAlreadyCurrent(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.1", map[string]string{ModuleFile: "-- 0.1"})
	c, dir := newChecker(t, s, "0.1")

	c.Start()
	if final := settle(t, c); final.Phase != "done" {
		t.Fatalf("finished in %q: %s", final.Phase, final.Error)
	}
	if s.blobHits.Load() != 0 {
		t.Error("downloaded the payload even though nothing was newer")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("wrote %d entries with nothing to install", len(entries))
	}
}

func TestStartIgnoresASecondPressWhileRunning(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{ModuleFile: "-- 0.2"})
	c, _ := newChecker(t, s, "0.1")

	c.Start()
	c.Start()
	c.Start()
	settle(t, c)

	// Three presses, one download: the archive is fetched once.
	if got := s.blobHits.Load(); got != 1 {
		t.Errorf("downloaded %d times for three presses, want 1", got)
	}
}

func TestProgressIsNilBeforeAnythingStarts(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{ModuleFile: "-- 0.2"})
	c, _ := newChecker(t, s, "0.1")
	if p := c.Progress(); p != nil {
		t.Errorf("reported progress before starting: %+v", p)
	}
}

func TestStartReportsAWriteFailureRatherThanClaimingSuccess(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{ModuleFile: "-- 0.2"})
	c, _ := newChecker(t, s, "0.1")
	c.Write = func(string, fs.FS, func(int, int)) ([]string, error) {
		return nil, fmt.Errorf("the disk is full")
	}

	c.Start()
	final := settle(t, c)
	if final.Phase != "error" {
		t.Fatalf("a failed write finished in %q", final.Phase)
	}
	if !strings.Contains(final.Error, "disk is full") {
		t.Errorf("the error was swallowed: %q", final.Error)
	}
	// and the version must not have moved
	if c.Version != "0.1" {
		t.Errorf("claimed version %q after a failed write", c.Version)
	}
}

// The bug this pins: the helper cannot replace its own binary, so after an
// in-game module update the new version number used to live only in this
// process's memory. The next helper restart forgot it, resurrected "update
// available", and re-applying re-downloaded a zip that was already installed
// -- forever. The VERSION stamp inside the parts folder is the cure, and a
// fresh Checker over the same modules directory is exactly what a restarted
// helper is.
func TestARestartedHelperRemembersAnInstalledUpdate(t *testing.T) {
	s := newServer(t)
	parts := strings.TrimSuffix(ModuleFile, ".lua")
	s.publish(t, "0.2", map[string]string{
		"payload/" + ModuleFile:          "-- module 0.2",
		"payload/" + parts + "/VERSION":  "0.2\n",
		"payload/" + parts + "/01 x.lua": "-- a part",
	})
	c, dir := newChecker(t, s, "0.1")

	c.Start()
	if final := settle(t, c); final.Phase != "done" {
		t.Fatalf("finished in %q: %s", final.Phase, final.Error)
	}

	// The helper restarts: a brand-new Checker, still compiled as 0.1, over
	// the same modules directory.
	restarted := New(s.URL+"/update.json", "0.1", dir, nil)
	st := restarted.State(context.Background())
	if st.Current != "0.2" {
		t.Errorf("a restarted helper thinks the module is %q, want 0.2", st.Current)
	}
	if st.Available {
		t.Error("a restarted helper re-offers the update that is already installed")
	}
}

// An archive from before stamps existed still must not loop: run() writes the
// stamp itself after a successful install.
func TestAnUnstampedArchiveStillLeavesADurableVersion(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{
		"payload/" + ModuleFile: "-- module 0.2",
	})
	c, dir := newChecker(t, s, "0.1")

	c.Start()
	if final := settle(t, c); final.Phase != "done" {
		t.Fatalf("finished in %q: %s", final.Phase, final.Error)
	}

	restarted := New(s.URL+"/update.json", "0.1", dir, nil)
	if st := restarted.State(context.Background()); st.Available || st.Current != "0.2" {
		t.Errorf("restart sees Current=%q Available=%v, want 0.2/false", st.Current, st.Available)
	}
}

// With no stamp at all -- an install that predates stamps, never updated --
// the compiled version answers, exactly as before the stamp existed.
func TestStampFallsBackToTheCompiledVersion(t *testing.T) {
	s := newServer(t)
	s.publish(t, "0.2", map[string]string{"payload/" + ModuleFile: "-- m"})
	c, _ := newChecker(t, s, "0.1")
	if st := c.State(context.Background()); st.Current != "0.1" || !st.Available {
		t.Errorf("Current=%q Available=%v, want 0.1/true", st.Current, st.Available)
	}
}
