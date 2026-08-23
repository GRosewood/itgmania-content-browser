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
// along with the sample window the pack's author chose. preview.Fetcher.Get
// satisfies it.
type Previewer func(packID int, song string) (any, error)

// Reporter describes the extraction currently in flight, for a caller that
// wants to draw a progress bar while waiting on Previewer. It must not block on
// whatever lock the extraction holds. preview.Fetcher.Progress satisfies it.
type Reporter func() any

// Server is a running loopback helper.
type Server struct {
	saveDir  string
	token    string
	version  string
	remove   Remover
	tidy     Sweeper
	preview  Previewer
	progress Reporter
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
