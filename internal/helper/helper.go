// Package helper is the small loopback service that performs the things the
// game cannot do for itself: delete a song pack from disk, and pull a single
// song out of a pack archive so the browser can play a sample of it.
//
// ITGmania's Lua API has no delete, move or rename anywhere in it -- the file
// manager exposes only Copy, DoesFileExist, GetFileSizeBytes, GetHashForFile,
// GetDirListing and Unzip -- so a theme can never remove a folder from /Songs.
// What a theme CAN do is make an HTTP request, and the engine's allowlist
// matches on host only, so http://127.0.0.1:<port> is reachable once the
// installer has put 127.0.0.1 in HttpAllowHosts.
//
// That is the whole design: the browser asks this service to delete a pack, or
// to fetch a song to listen to, and the player never leaves the game.
//
// The preview half is here for a second reason as well: reading one song out of
// a remote zip takes range requests and an inflate, and Lua has neither -- and
// even if it did, RageFile:Write stops at the first NUL byte, so a theme cannot
// write an audio file even while holding one.
//
// It listens on loopback only, on an OS-assigned port, and every request must
// carry a token that is generated per run and written next to the game's Save
// directory where only the module can read it.
package helper

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ConfigName is the file the module reads to find the service.
const ConfigName = "helper.json"

// Config is what the running service publishes for the module to pick up.
type Config struct {
	Port    int    `json:"port"`
	Token   string `json:"token"`
	Version string `json:"version"`
	PID     int    `json:"pid"`
}

// ConfigPath is where the service publishes itself for a given Save directory.
func ConfigPath(saveDir string) string {
	return filepath.Join(saveDir, "ITGmaniaContentBrowser", ConfigName)
}

// Remover deletes one pack directory. installer.RemovePack satisfies it; the
// tests substitute their own.
type Remover func(pack string) (string, error)

// Sweeper clears the empty probe files the engine leaves behind. It takes no
// arguments and reports what it deleted.
type Sweeper func() ([]string, error)

// Previewer extracts one song's audio from a pack and reports where it landed,
// along with the sample window the pack's author chose. helper wiring wraps
// preview.Fetcher.Get in it -- the concrete return types differ, so the wrap
// is a closure, not an assignment.
type Previewer func(packID int, song string) (any, error)

// PackIniReader reports whether a pack's download carries a Pack.ini and what
// it says about sync. helper wiring wraps preview.Fetcher.PackIni in it.
type PackIniReader func(packID int) (any, error)

// PackModsReader reports which of a pack's songs ship Lua of their own.
// helper wiring wraps preview.Fetcher.PackMods in it.
type PackModsReader func(packID int) (any, error)

// PackCreditsReader reports who charted a pack, read out of the simfiles in
// its archive -- the catalogue's credit index is sparse for older packs, and
// the simfiles are the only account that can be trusted. helper wiring wraps
// preview.Fetcher.PackCredits in it.
type PackCreditsReader func(packID int) (any, error)

// SpaceReader reports how much room is left where packs are installed, and how
// much a pack would need. The game cannot answer either: Lua has no filesystem
// beyond reading, and the install root is a preference this service resolves.
type SpaceReader func() (free int64, root string, ok bool)

// Reporter describes the extraction currently in flight, for a caller that
// wants to draw a progress bar while waiting on Previewer. It must not block on
// whatever lock the extraction holds. helper wiring wraps
// preview.Fetcher.Progress in it.
type Reporter func() any

// Starter begins a pack install and returns without waiting for it. The game
// cannot do this for itself: every song folder is mounted at the same place, so
// its unzip lands in whichever one the engine loaded first rather than the one
// the player configured. packs.Installer.Start satisfies it.
type Starter func(packID int, name string) error

// Watcher reports every install this helper has run. packs.Installer.Status
// satisfies it, once wrapped to return any.
type Watcher func() any

// SongStarter installs one song out of a pack. packs.Installer.StartSong
// satisfies it.
type SongStarter func(packID int, song, sync string) error

// Updater answers whether a newer browser has been published, and installs it.
// update.Checker satisfies it once its methods are wrapped to return any.
//
// The check lives out here rather than in the game because the engine will only
// talk to hosts on its own allowlist, and asking players to widen that list to
// see an update notice is a poor trade for a file this small.
type Updater struct {
	State    func() any
	Start    func()
	Progress func() any
}

// Server is a running loopback helper.
type Server struct {
	saveDir  string
	token    string
	version  string
	remove   Remover
	tidy     Sweeper
	preview  Previewer
	progress Reporter
	install  Starter
	installs Watcher
	single   SongStarter
	update   Updater
	packIni  PackIniReader
	packMods PackModsReader
	packCred PackCreditsReader
	space    SpaceReader
	ln       net.Listener
	srv      *http.Server
}

func newToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// New binds a loopback port and publishes the config file.
func New(saveDir, version string, remove Remover, tidy Sweeper) (*Server, error) {
	token, err := newToken()
	if err != nil {
		return nil, fmt.Errorf("generating token: %w", err)
	}

	// Port 0: the OS picks a free one. Nothing outside this machine can reach
	// it, and nothing on this machine can use it without the token.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("binding loopback: %w", err)
	}

	s := &Server{
		saveDir: saveDir,
		token:   token,
		version: version,
		remove:  remove,
		tidy:    tidy,
		ln:      ln,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/remove", s.handleRemove)
	mux.HandleFunc("/tidy", s.handleTidy)
	mux.HandleFunc("/preview", s.handlePreview)
	mux.HandleFunc("/preview/progress", s.handleProgress)
	mux.HandleFunc("/install", s.handleInstall)
	mux.HandleFunc("/install/progress", s.handleInstalls)
	mux.HandleFunc("/single", s.handleSingle)
	mux.HandleFunc("/version", s.handleVersion)
	mux.HandleFunc("/update", s.handleUpdate)
	mux.HandleFunc("/update/progress", s.handleUpdates)
	mux.HandleFunc("/packini", s.handlePackIni)
	mux.HandleFunc("/space", s.handleSpace)
	mux.HandleFunc("/fetch", s.handleFetch)
	mux.HandleFunc("/credits", s.handleCredits)
	s.srv = &http.Server{
		Handler:           s.withGuards(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	if err := s.publish(); err != nil {
		ln.Close()
		return nil, err
	}
	return s, nil
}

// SetPreviewer attaches the song-preview extractor. It is separate from New
// because it is the one capability the helper can run without: removal is why
// this service exists, and previews are a convenience layered on top of it.
//
// Call it before Serve.
func (s *Server) SetPreviewer(p Previewer) { s.preview = p }

// SetReporter attaches the progress source /preview/progress reads. Call it
// before Serve.
func (s *Server) SetReporter(r Reporter) { s.progress = r }

// SetInstaller attaches pack installation. Call it before Serve.
func (s *Server) SetInstaller(start Starter, watch Watcher) {
	s.install, s.installs = start, watch
}

// SetSongInstaller attaches single-song installation. Call it before Serve.
func (s *Server) SetSongInstaller(start SongStarter) { s.single = start }

// SetUpdater attaches the self-update check. Call it before Serve.
func (s *Server) SetUpdater(u Updater) { s.update = u }

// SetPackIniReader attaches the archive Pack.ini check. Call it before Serve.
func (s *Server) SetPackIniReader(r PackIniReader) { s.packIni = r }

// SetPackModsReader attaches the archive Lua check. Call it before Serve.
func (s *Server) SetPackModsReader(r PackModsReader) { s.packMods = r }

// SetPackCreditsReader attaches the simfile credit scan. Call it before Serve.
func (s *Server) SetPackCreditsReader(r PackCreditsReader) { s.packCred = r }

// SetSpaceReader attaches the free-space check. Call it before Serve.
func (s *Server) SetSpaceReader(r SpaceReader) { s.space = r }

// Port is the loopback port the service bound.
func (s *Server) Port() int { return s.ln.Addr().(*net.TCPAddr).Port }

// Token is the shared secret the module must present.
func (s *Server) Token() string { return s.token }

func (s *Server) publish() error {
	path := ConfigPath(s.saveDir)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", filepath.Dir(path), err)
	}
	data, err := json.MarshalIndent(Config{
		Port:    s.Port(),
		Token:   s.token,
		Version: s.version,
		PID:     os.Getpid(),
	}, "", "  ")
	if err != nil {
		return err
	}
	// 0600: the token is the only thing standing between a local process and
	// the delete endpoint.
	return os.WriteFile(path, append(data, '\n'), 0o600)
}

// Serve blocks until the server is closed.
func (s *Server) Serve() error {
	err := s.srv.Serve(s.ln)
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}

// Close stops the server. It unlinks the published config only if that config
// is still ours: during an upgrade the replacement publishes over us, and
// deleting its file would take the live helper down with us.
func (s *Server) Close() error {
	if cfg, err := ReadConfig(s.saveDir); err == nil && cfg.Token == s.token {
		os.Remove(ConfigPath(s.saveDir))
	}
	return s.srv.Close()
}

// withGuards rejects anything that is not a token-carrying loopback request.
func (s *Server) withGuards(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			http.Error(w, "loopback only", http.StatusForbidden)
			return
		}
		got := r.Header.Get("X-Browser-Token")
		if got == "" {
			// The game's file-download path cannot set a header -- the engine
			// issues that request itself -- so the token may ride in the query
			// instead. Same token, same comparison; only the envelope differs.
			got = r.URL.Query().Get("t")
		}
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) != 1 {
			http.Error(w, "bad token", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(body)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"version": s.version,
	})
}

type removeRequest struct {
	Pack string `json:"pack"`
}

func (s *Server) handleRemove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok": false, "error": "POST only",
		})
		return
	}
	var req removeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "bad request body",
		})
		return
	}
	name := strings.TrimSpace(req.Pack)
	if name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "no pack named",
		})
		return
	}

	// The path safety check lives in the remover, which is the only thing that
	// knows where this install's Songs directories actually are.
	path, err := s.remove(name)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "pack": name, "path": path,
	})
}

// handleTidy sweeps the empty probe files the engine leaves behind whenever it
// creates a directory. It takes no arguments: there is nothing to name and so
// nothing to validate beyond the guards every request already passes.
func (s *Server) handleTidy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok": false, "error": "POST only",
		})
		return
	}
	if s.tidy == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "error": "no sweeper configured",
		})
		return
	}
	removed, err := s.tidy()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "removed": len(removed),
	})
}

type previewRequest struct {
	Pack int    `json:"pack"`
	Song string `json:"song"`
}

// handlePreview extracts one song's audio from a pack on the download server
// and hands back the path to play. The extractor holds its own lock, so a
// player leaning on the button queues rather than storming the server.
func (s *Server) handlePreview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok": false, "error": "POST only",
		})
		return
	}
	if s.preview == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "error": "previews are unavailable",
		})
		return
	}
	var req previewRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "bad request body",
		})
		return
	}
	if req.Pack <= 0 || strings.TrimSpace(req.Song) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "no song named",
		})
		return
	}

	sample, err := s.preview(req.Pack, strings.TrimSpace(req.Song))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "sample": sample,
	})
}

// handleProgress reports the extraction in flight. It is polled while a sample
// is being fetched, so it stays a plain GET and never touches the extractor's
// own lock -- a progress request that blocked behind the work it is reporting
// on would defeat the point.
func (s *Server) handleProgress(w http.ResponseWriter, r *http.Request) {
	if s.progress == nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "progress": nil})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "progress": s.progress(),
	})
}

type installRequest struct {
	Pack int    `json:"pack"`
	Name string `json:"name"`
}

// handleInstall starts a download and returns at once. The work outlives the
// request on purpose: a pack can be gigabytes, and the browser wants to carry
// on drawing while it arrives.
func (s *Server) handleInstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok": false, "error": "POST only",
		})
		return
	}
	if s.install == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "error": "installing is unavailable",
		})
		return
	}
	var req installRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "bad request body",
		})
		return
	}
	if req.Pack <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "no pack given",
		})
		return
	}
	if err := s.install(req.Pack, strings.TrimSpace(req.Name)); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "pack": req.Pack})
}

type singleRequest struct {
	Pack int    `json:"pack"`
	Song string `json:"song"`
	// which singles folder to use. The caller decides, because it is the
	// one that knows what SMO says about the pack; empty falls back to what
	// the pack itself declares inside the archive.
	Sync string `json:"sync"`
}

// handleSingle lifts one song out of a pack. Like /install it returns as soon
// as the work is scheduled, and reports through the same queue.
func (s *Server) handleSingle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok": false, "error": "POST only",
		})
		return
	}
	if s.single == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "error": "single songs are unavailable",
		})
		return
	}
	var req singleRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "bad request body",
		})
		return
	}
	if req.Pack <= 0 || strings.TrimSpace(req.Song) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "no song given",
		})
		return
	}
	if err := s.single(req.Pack, strings.TrimSpace(req.Song),
		strings.ToUpper(strings.TrimSpace(req.Sync))); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleSpace reports the room left where packs land.
//
// A GET, and cheap: a download that would not fit is worth knowing about before
// it starts rather than when the disk fills, and the browser asks each time it
// is about to offer one.
func (s *Server) handleSpace(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"ok": true, "free": nil, "root": nil}
	if s.space != nil {
		if free, root, fine := s.space(); fine {
			out["free"], out["root"] = free, root
		}
	}
	writeJSON(w, http.StatusOK, out)
}

type packIniRequest struct {
	Pack int `json:"pack"`
}

// handlePackIni answers what a pack's download carries: a Pack.ini, and any
// songs that ship Lua of their own.
//
// The catalogue is ambiguous about the first -- a pack with no sync tag might
// have no Pack.ini, or might simply never have been tagged -- and silent about
// the second. The archive is the only thing that actually knows either. It
// costs the pack's zip index, which is a HEAD and its central directory over
// ranged reads, and which a preview of the same pack has usually already paid
// for.
//
// Both answers ride one request because the game has a single HTTP worker and
// every request is serial: two round trips for two readings of one index would
// be a second wait for nothing.
func (s *Server) handlePackIni(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok": false, "error": "POST only",
		})
		return
	}
	if s.packIni == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "error": "reading pack archives is unavailable",
		})
		return
	}
	var req packIniRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "bad request body",
		})
		return
	}
	if req.Pack <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "no pack given",
		})
		return
	}
	info, err := s.packIni(req.Pack)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	out := map[string]any{"ok": true, "packIni": info, "mods": nil}
	// The index is already open and cached by the read above, so this is a walk
	// over a list in memory. A failure here is not worth failing the Pack.ini
	// answer over -- the browser draws what it was told and leaves out the rest.
	if s.packMods != nil {
		if mods, err := s.packMods(req.Pack); err == nil {
			out["mods"] = mods
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// handleVersion reports what this build is, and whether a newer one exists.
//
// It always answers 200 with whatever it knows. A browser that cannot be told
// about updates should draw itself exactly as it always has, so "the check
// failed" and "there is nothing new" reach the game as the same shape and the
// module has one thing to look at rather than two.
func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"ok": true, "version": s.version, "update": nil}
	if s.update.State != nil {
		out["update"] = s.update.State()
	}
	writeJSON(w, http.StatusOK, out)
}

// handleUpdate starts an update and returns at once, the same way an install
// does: the game polls /update/progress to draw the bar.
func (s *Server) handleUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok": false, "error": "POST only",
		})
		return
	}
	if s.update.Start == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "error": "updating is unavailable",
		})
		return
	}
	s.update.Start()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleUpdates reports how far the update has got.
func (s *Server) handleUpdates(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"ok": true, "progress": nil}
	if s.update.Progress != nil {
		out["progress"] = s.update.Progress()
	}
	writeJSON(w, http.StatusOK, out)
}

// handleInstalls reports where every install has got to. Polled while a
// download runs, so it stays a plain GET that touches no lock the work holds.
func (s *Server) handleInstalls(w http.ResponseWriter, r *http.Request) {
	if s.installs == nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "installs": nil})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "installs": s.installs()})
}

// ReadConfig loads what a running helper published for this install. The
// module uses the same file to find the port and token.
func ReadConfig(saveDir string) (Config, error) {
	var cfg Config
	data, err := os.ReadFile(ConfigPath(saveDir))
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}
	return cfg, nil
}
