// Package packs downloads a song pack and unpacks it where the player's
// library actually is.
//
// The game cannot do this itself. Every song folder -- <install>/Songs and each
// entry of AdditionalSongFoldersWritable -- is mounted at the same place, so
// /Songs inside the game is a union and nothing in Lua can tell the parts
// apart. When the engine writes a file it picks a driver by counting how many
// directories it would have to create, lowest wins, ties going to the
// earliest-loaded. Every driver ties on a pack that does not exist yet, so the
// engine's own unzip always lands in <install>/Songs -- even for a player whose
// library is a mounted drive and whose Songs directory is a stub on a system
// disk that may be small, or read-only, or both.
//
// So the bytes come down here instead, straight into the directory the player
// configured. It also takes the unzip off the game's main thread, which used to
// freeze it for a moment on a large pack.
package packs

import (
	"archive/zip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Progress is one install, as seen from outside while it runs.
type Progress struct {
	Key    string   `json:"key"` // "pack:<id>" or "song:<id>:<song>"
	Pack   int      `json:"pack"`
	Name   string   `json:"name"`
	Song   string   `json:"song"`  // set when this is one song, not a pack
	Phase  string   `json:"phase"` // downloading | unpacking | done | failed
	Done   int64    `json:"done"`
	Total  int64    `json:"total"`
	Frac   float64  `json:"frac"` // 0..1, or -1 when the size is not known
	Root   string   `json:"root"`
	Sync   string   `json:"sync,omitempty"` // which singles folder a song went to
	Groups []string `json:"groups"`
	Err    string   `json:"error,omitempty"`
}

// Installer runs pack installs and remembers how they went.
type Installer struct {
	// Root is asked for each install rather than once at startup: a drive can
	// be plugged in after the helper has already been running for a week.
	Root   func() (string, error)
	Base   string
	Client *http.Client

	// InstallSong lifts one song out of a pack into the given root. It is
	// injected rather than implemented here: the archive reader that can do it
	// without downloading the pack already exists for audio previews.
	InstallSong func(packID int, title, root, sync string) (any, error)

	mu   sync.Mutex
	jobs map[string]*Progress
}

func New(root func() (string, error), base string) *Installer {
	// No overall timeout: a 4 GB pack on a slow line is not a stuck request.
	// But "the transport catches a dead connection" -- which an earlier
	// version of this comment claimed -- is not true of the RESPONSE BODY: a
	// connection that goes silent without an RST blocks Read forever, left a
	// job in "downloading" for good, and Start's dedup then refused every
	// retry until the helper restarted. The header timeout below catches a
	// server that never starts answering; the stall watchdog in download
	// catches one that stops partway.
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = 30 * time.Second
	return &Installer{
		Root:   root,
		Base:   strings.TrimSuffix(base, "/"),
		Client: &http.Client{Transport: transport},
		jobs:   map[string]*Progress{},
	}
}

// Status is every install this helper has run since it started, newest state
// for each pack.
func (in *Installer) Status() []Progress {
	in.mu.Lock()
	defer in.mu.Unlock()
	out := make([]Progress, 0, len(in.jobs))
	for _, p := range in.jobs {
		out = append(out, *p)
	}
	return out
}

func (in *Installer) set(key string, mutate func(*Progress)) {
	in.mu.Lock()
	defer in.mu.Unlock()
	p := in.jobs[key]
	if p == nil {
		p = &Progress{Key: key}
		in.jobs[key] = p
	}
	mutate(p)
}

// Start begins an install and returns immediately. Asking twice for a pack that
// is already on its way is not an error; it is the same install.
func (in *Installer) Start(packID int, name string) error {
	if packID <= 0 {
		return fmt.Errorf("no pack given")
	}
	name = strings.TrimSpace(name)

	key := fmt.Sprintf("pack:%d", packID)
	in.mu.Lock()
	if p := in.jobs[key]; p != nil && (p.Phase == "downloading" || p.Phase == "unpacking") {
		in.mu.Unlock()
		return nil
	}
	in.jobs[key] = &Progress{
		Key: key, Pack: packID, Name: name, Phase: "downloading", Frac: -1,
	}
	in.mu.Unlock()

	go in.run(key, packID, name)
	return nil
}

// StartSong lifts one song out of a pack, into the singles folder for whatever
// sync that pack declares. It reports through the same queue as a whole pack,
// so nothing downstream has to know the difference.
func (in *Installer) StartSong(packID int, title, sync string) error {
	if packID <= 0 || strings.TrimSpace(title) == "" {
		return fmt.Errorf("no song given")
	}
	if in.InstallSong == nil {
		return fmt.Errorf("single songs are unavailable")
	}
	title = strings.TrimSpace(title)
	key := fmt.Sprintf("song:%d:%s", packID, title)

	in.mu.Lock()
	if p := in.jobs[key]; p != nil && p.Phase == "downloading" {
		in.mu.Unlock()
		return nil
	}
	in.jobs[key] = &Progress{
		Key: key, Pack: packID, Name: title, Song: title,
		Phase: "downloading", Frac: -1,
	}
	in.mu.Unlock()

	go func() {
		root, err := in.Root()
		if err != nil {
			in.fail(key, err)
			return
		}
		in.set(key, func(p *Progress) { p.Root = root })
		res, err := in.InstallSong(packID, title, root, sync)
		if err != nil {
			in.fail(key, err)
			return
		}
		in.set(key, func(p *Progress) {
			p.Phase = "done"
			p.Frac = 1
			if s, ok := res.(interface{ Where() (string, string) }); ok {
				folder, sync := s.Where()
				p.Groups = []string{folder}
				p.Sync = sync
			}
		})
	}()
	return nil
}

func (in *Installer) fail(key string, err error) {
	in.set(key, func(p *Progress) {
		p.Phase = "failed"
		p.Err = err.Error()
	})
}

func (in *Installer) run(key string, packID int, name string) {
	root, err := in.Root()
	if err != nil {
		in.fail(key, err)
		return
	}
	in.set(key, func(p *Progress) { p.Root = root })

	// The temp file lives in the destination so the unpack never crosses a
	// filesystem, and so a half-finished download cannot fill the system disk
	// of someone whose library is elsewhere.
	tmp := filepath.Join(root, fmt.Sprintf(".content-browser-%d.part", packID))
	defer os.Remove(tmp)

	if err := in.download(key, packID, tmp); err != nil {
		in.fail(key, err)
		return
	}

	in.set(key, func(p *Progress) {
		p.Phase = "unpacking"
		p.Frac = -1
	})
	groups, err := in.unpack(key, tmp, root)
	if err != nil {
		in.fail(key, err)
		return
	}

	in.set(key, func(p *Progress) {
		p.Phase = "done"
		p.Frac = 1
		p.Groups = groups
	})
}

func (in *Installer) download(key string, packID int, dest string) error {
	url := fmt.Sprintf("%s/download/pack/%d/", in.Base, packID)
	resp, err := in.Client.Get(url)
	if err != nil {
		return fmt.Errorf("could not reach the download server: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the download server said %s", resp.Status)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "" && !strings.Contains(ct, "zip") {
		return fmt.Errorf("the download server did not return a zip (%s)", ct)
	}

	total := resp.ContentLength
	in.set(key, func(p *Progress) {
		p.Total = total
		if total <= 0 {
			p.Frac = -1
		}
	})

	f, err := os.Create(dest)
	if err != nil {
		return fmt.Errorf("could not write to %s: %w", filepath.Dir(dest), err)
	}
	defer f.Close()

	// The stall watchdog: when no byte has arrived for a whole minute, close
	// the body. Closing unblocks the Read below with an error, which flows
	// into the existing stopped-early path -- the job fails visibly and the
	// retry gate reopens. Re-armed on every read, so a slow-but-moving
	// multi-gigabyte download is never the thing that gets killed.
	const stallAfter = 60 * time.Second
	watchdog := time.AfterFunc(stallAfter, func() { resp.Body.Close() })
	defer watchdog.Stop()

	buf := make([]byte, 256<<10)
	var done int64
	last := time.Now()
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			watchdog.Reset(stallAfter)
			if _, werr := f.Write(buf[:n]); werr != nil {
				return fmt.Errorf("could not write to %s: %w", filepath.Dir(dest), werr)
			}
			done += int64(n)
			// Reporting every chunk would lock the map thousands of times a
			// second for a number nobody can read that fast.
			if time.Since(last) > 100*time.Millisecond {
				last = time.Now()
				in.set(key, func(p *Progress) {
					p.Done = done
					if p.Total > 0 {
						p.Frac = float64(done) / float64(p.Total)
					}
				})
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return fmt.Errorf("the download stopped early: %w", rerr)
		}
	}
	in.set(key, func(p *Progress) {
		p.Done = done
		if p.Total > 0 {
			p.Frac = 1
		}
	})
	return f.Sync()
}

// unpack extracts the archive into root and reports the top-level folders it
// created, which are the song groups the game will find.
func (in *Installer) unpack(key string, archivePath, root string) ([]string, error) {
	zr, err := zip.OpenReader(archivePath)
	if err != nil {
		return nil, fmt.Errorf("the download was not a readable zip: %w", err)
	}
	defer zr.Close()

	groups := map[string]bool{}
	var total, done int64
	for _, f := range zr.File {
		total += int64(f.UncompressedSize64)
	}

	for _, f := range zr.File {
		rel, ok := safeRel(f.Name)
		if !ok {
			continue
		}
		if top := strings.SplitN(rel, "/", 2)[0]; top != "" && strings.Contains(rel, "/") {
			groups[top] = true
		}

		dest := filepath.Join(root, filepath.FromSlash(rel))
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(dest, 0o755); err != nil {
				return nil, err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return nil, err
		}
		n, err := extractOne(f, dest)
		if err != nil {
			return nil, err
		}
		done += n
		if total > 0 {
			in.set(key, func(p *Progress) {
				p.Done, p.Total = done, total
				p.Frac = float64(done) / float64(total)
			})
		}
	}

	out := make([]string, 0, len(groups))
	for g := range groups {
		out = append(out, g)
	}
	return out, nil
}

func extractOne(f *zip.File, dest string) (int64, error) {
	rc, err := f.Open()
	if err != nil {
		return 0, err
	}
	defer rc.Close()
	out, err := os.Create(dest)
	if err != nil {
		return 0, err
	}
	defer out.Close()
	return io.Copy(out, rc)
}

// safeRel turns an archive entry name into a path that cannot escape the
// destination. An archive is someone else's data even when it comes from a site
// you trust, and "../.." in an entry name is the oldest trick there is.
func safeRel(name string) (string, bool) {
	clean := strings.ReplaceAll(name, `\`, "/")
	clean = strings.TrimPrefix(clean, "/")
	if clean == "" || strings.HasPrefix(clean, "__MACOSX/") {
		return "", false
	}
	if filepath.IsAbs(clean) || strings.HasPrefix(clean, "../") ||
		strings.Contains(clean, "/../") || clean == ".." ||
		strings.HasSuffix(clean, "/..") {
		return "", false
	}
	// A drive letter would survive IsAbs on the wrong platform.
	if len(clean) > 1 && clean[1] == ':' {
		return "", false
	}
	return clean, true
}
