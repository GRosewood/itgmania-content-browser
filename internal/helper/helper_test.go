package helper

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func newTestServer(t *testing.T, remove Remover) (*Server, string) {
	t.Helper()
	save := t.TempDir()
	srv, err := New(save, "test", remove, noTidy)
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve()
	t.Cleanup(func() { srv.Close() })
	return srv, fmt.Sprintf("http://127.0.0.1:%d", srv.Port())
}

// the existing tests are not about sweeping, so they get a sweeper that
// reports nothing removed
func noTidy() ([]string, error) { return nil, nil }

func okRemover(pack string) (string, error) { return "/Songs/" + pack, nil }

func TestPublishesConfigWithPortAndToken(t *testing.T) {
	save := t.TempDir()
	srv, err := New(save, "test", okRemover, noTidy)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()

	data, err := os.ReadFile(ConfigPath(save))
	if err != nil {
		t.Fatal(err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.Port != srv.Port() {
		t.Errorf("port %d, want %d", cfg.Port, srv.Port())
	}
	if cfg.Token != srv.Token() || len(cfg.Token) != 64 {
		t.Errorf("token %q", cfg.Token)
	}
}

func TestCloseRemovesConfig(t *testing.T) {
	save := t.TempDir()
	srv, err := New(save, "test", okRemover, noTidy)
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve()
	srv.Close()
	if _, err := os.Stat(ConfigPath(save)); !os.IsNotExist(err) {
		t.Error("config outlived the server")
	}
}

// The token is the only thing between another local process and a recursive
// delete, so every endpoint must demand it.
func TestRequestsWithoutTheTokenAreRefused(t *testing.T) {
	var called bool
	srv, base := newTestServer(t, func(pack string) (string, error) {
		called = true
		return "", nil
	})

	for _, tc := range []struct{ name, token string }{
		{"no token", ""},
		{"wrong token", "0000"},
		{"almost right", srv.Token()[:63] + "0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req, _ := http.NewRequest(http.MethodPost, base+"/remove",
				bytes.NewBufferString(`{"pack":"Anything"}`))
			if tc.token != "" {
				req.Header.Set("X-Browser-Token", tc.token)
			}
			res, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer res.Body.Close()
			if res.StatusCode != http.StatusForbidden {
				t.Errorf("status %d, want 403", res.StatusCode)
			}
		})
	}
	if called {
		t.Error("the remover ran for an unauthenticated request")
	}
}

func TestHealthAndRemoveWithTheToken(t *testing.T) {
	var got string
	srv, base := newTestServer(t, func(pack string) (string, error) {
		got = pack
		return "/Songs/" + pack, nil
	})

	req, _ := http.NewRequest(http.MethodGet, base+"/health", nil)
	req.Header.Set("X-Browser-Token", srv.Token())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("health status %d", res.StatusCode)
	}

	req, _ = http.NewRequest(http.MethodPost, base+"/remove",
		bytes.NewBufferString(`{"pack":"My Pack"}`))
	req.Header.Set("X-Browser-Token", srv.Token())
	res, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()

	var body struct {
		OK   bool   `json:"ok"`
		Path string `json:"path"`
	}
	json.NewDecoder(res.Body).Decode(&body)
	if !body.OK || got != "My Pack" {
		t.Errorf("ok=%v pack=%q", body.OK, got)
	}
}

// A refusal from the remover has to surface as a failure, not a silent success.
func TestRemoverErrorBecomesAFailedResponse(t *testing.T) {
	srv, base := newTestServer(t, func(pack string) (string, error) {
		return "", fmt.Errorf("%q is not a plain folder name", pack)
	})

	req, _ := http.NewRequest(http.MethodPost, base+"/remove",
		bytes.NewBufferString(`{"pack":"../Program"}`))
	req.Header.Set("X-Browser-Token", srv.Token())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("status %d, want 400", res.StatusCode)
	}
	var body struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	json.NewDecoder(res.Body).Decode(&body)
	if body.OK || body.Error == "" {
		t.Errorf("ok=%v error=%q", body.OK, body.Error)
	}
}

func TestRemoveRejectsGetAndEmptyName(t *testing.T) {
	srv, base := newTestServer(t, okRemover)

	req, _ := http.NewRequest(http.MethodGet, base+"/remove", nil)
	req.Header.Set("X-Browser-Token", srv.Token())
	res, _ := http.DefaultClient.Do(req)
	if res.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET status %d, want 405", res.StatusCode)
	}
	res.Body.Close()

	req, _ = http.NewRequest(http.MethodPost, base+"/remove",
		bytes.NewBufferString(`{"pack":"   "}`))
	req.Header.Set("X-Browser-Token", srv.Token())
	res, _ = http.DefaultClient.Do(req)
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("empty-name status %d, want 400", res.StatusCode)
	}
	res.Body.Close()
}

func TestConfigPathLivesUnderSave(t *testing.T) {
	got := ConfigPath(filepath.Join("X", "Save"))
	want := filepath.Join("X", "Save", "ITGmaniaContentBrowser", "helper.json")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// An upgrade starts a replacement before the old helper notices it has been
// superseded. If the old one unlinked the config on its way out it would take
// the live helper down with it, leaving the browser with nothing to talk to.
func TestClosingASupersededHelperLeavesTheLiveConfigAlone(t *testing.T) {
	dir := t.TempDir()

	old, err := New(dir, "old", okRemover, noTidy)
	if err != nil {
		t.Fatal(err)
	}
	go old.Serve()

	replacement, err := New(dir, "new", okRemover, noTidy)
	if err != nil {
		t.Fatal(err)
	}
	go replacement.Serve()
	defer replacement.Close()

	// the old helper's watchdog sees a foreign PID and shuts down
	old.Close()

	cfg, err := ReadConfig(dir)
	if err != nil {
		t.Fatalf("the superseded helper deleted the live config: %v", err)
	}
	if cfg.Port != replacement.Port() || cfg.Token != replacement.Token() {
		t.Errorf("config names port %d, want the replacement's %d", cfg.Port, replacement.Port())
	}
}
