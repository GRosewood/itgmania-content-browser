package helper

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"testing"
	"time"
)

func newPaused(t *testing.T) (*Server, chan error) {
	t.Helper()
	save := t.TempDir()
	srv, err := New(save, "test", nil, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- srv.Serve() }()
	return srv, done
}

// health asks the helper whether it is there, the way the game does.
//
// Keep-alives are off on purpose. With the shared default transport, an earlier
// check leaves an idle connection behind and the next one rides it -- so a
// server whose listener had been closed still answered, and the test that meant
// to prove the pause works proved only that Go pools sockets.
func health(t *testing.T, srv *Server, port int) (int, error) {
	t.Helper()
	req, err := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/health", port), nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("X-Browser-Token", srv.Token())
	client := &http.Client{
		Timeout:   3 * time.Second,
		Transport: &http.Transport{DisableKeepAlives: true},
	}
	defer client.CloseIdleConnections()
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	return resp.StatusCode, nil
}

// refused reports whether a fresh TCP connection to that port is refused. This
// is the question a pause is actually answering -- nothing is listening -- and
// unlike an HTTP round trip it cannot be satisfied by a pooled socket.
func refused(port int) bool {
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
	if err != nil {
		return true
	}
	_ = c.Close()
	return false
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// The whole point of the pause: an http.Server whose listener is closed has to
// be usable again afterwards. It is not obvious that it is -- Close() on the
// server is permanent -- so this pins the behaviour the design rests on.
func TestServerServesAgainAfterAPause(t *testing.T) {
	srv, done := newPaused(t)
	defer func() { _ = srv.Close() }()

	first := srv.Port()
	waitFor(t, "the first port to answer", func() bool {
		code, err := health(t, srv, first)
		return err == nil && code == http.StatusOK
	})

	srv.Pause()
	if got := srv.Port(); got != 0 {
		t.Errorf("port while paused = %d, want 0", got)
	}
	if !srv.Paused() {
		t.Error("Paused() = false just after Pause()")
	}
	// Serve must still be parked, not returned: the process outlives the pause.
	select {
	case err := <-done:
		t.Fatalf("Serve returned during a pause: %v", err)
	case <-time.After(200 * time.Millisecond):
	}

	// and nothing is listening on the old port any more
	if !refused(first) {
		t.Errorf("port %d still accepted a connection after the pause", first)
	}
	if _, err := health(t, srv, first); err == nil {
		t.Errorf("port %d still served a request after the pause", first)
	}

	if err := srv.Resume(); err != nil {
		t.Fatalf("Resume: %v", err)
	}
	second := srv.Port()
	if second == 0 {
		t.Fatal("no port after Resume")
	}
	if srv.Paused() {
		t.Error("Paused() = true after Resume()")
	}
	waitFor(t, "the second port to answer", func() bool {
		code, err := health(t, srv, second)
		return err == nil && code == http.StatusOK
	})
}

// A paused helper publishes a port of zero rather than nothing. The module
// reads that as no helper and keeps re-reading, and -- the part that would
// otherwise break -- the two-second check that stops this process on an
// uninstall or an upgrade still has a file to read.
func TestPausePublishesAZeroPortAndResumeRepublishes(t *testing.T) {
	save := t.TempDir()
	srv, err := New(save, "test", nil, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer func() { _ = srv.Close() }()
	go func() { _ = srv.Serve() }()

	cfg, err := ReadConfig(save)
	if err != nil {
		t.Fatalf("reading the published config: %v", err)
	}
	if cfg.Port != srv.Port() {
		t.Errorf("config port %d, server port %d", cfg.Port, srv.Port())
	}

	srv.Pause()
	paused, err := ReadConfig(save)
	if err != nil {
		t.Fatalf("no config while paused, so nothing could ever stop this helper: %v", err)
	}
	if paused.Port != 0 {
		t.Errorf("paused port = %d, want 0", paused.Port)
	}
	if paused.Token != srv.Token() {
		t.Error("the paused config carries a different token, so the helper would stop itself")
	}

	if err := srv.Resume(); err != nil {
		t.Fatalf("Resume: %v", err)
	}
	again, err := ReadConfig(save)
	if err != nil {
		t.Fatalf("reading the republished config: %v", err)
	}
	if again.Port != srv.Port() {
		t.Errorf("republished port %d, server port %d", again.Port, srv.Port())
	}
	if again.Token != srv.Token() {
		t.Error("the token changed across a pause")
	}
}

// An uninstall arriving between games must still end the process, so Close has
// to wake a Serve that is parked with no listener at all.
func TestCloseWakesAServeParkedInAPause(t *testing.T) {
	srv, done := newPaused(t)
	srv.Pause()

	select {
	case err := <-done:
		t.Fatalf("Serve returned before Close: %v", err)
	case <-time.After(100 * time.Millisecond):
	}

	if err := srv.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Serve after Close returned %v, want nil", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve never returned after Close")
	}
}

// A pause left holding somebody else's config would delete it on the way out.
// Close already guards this; Pause takes the same care and is checked the same.
func TestPauseLeavesAnotherHelpersConfigAlone(t *testing.T) {
	save := t.TempDir()
	srv, err := New(save, "test", nil, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer func() { _ = srv.Close() }()

	// a replacement helper publishes over us
	other := []byte(`{"port":1,"token":"someone-else","version":"x","pid":2}`)
	if err := os.WriteFile(ConfigPath(save), other, 0o600); err != nil {
		t.Fatal(err)
	}

	srv.Pause()
	got, err := ReadConfig(save)
	if err != nil {
		t.Fatalf("the other helper's config was removed: %v", err)
	}
	if got.Token != "someone-else" {
		t.Errorf("token = %q, want the other helper's", got.Token)
	}
}

// Repeated pauses and resumes must not leak sockets or deadlock -- this runs
// every time the player starts and quits the game.
func TestPauseResumeIsRepeatable(t *testing.T) {
	srv, done := newPaused(t)
	defer func() { _ = srv.Close() }()

	seen := map[int]bool{srv.Port(): true}
	for i := 0; i < 5; i++ {
		srv.Pause()
		if err := srv.Resume(); err != nil {
			t.Fatalf("round %d: Resume: %v", i, err)
		}
		port := srv.Port()
		if port == 0 {
			t.Fatalf("round %d: no port", i)
		}
		seen[port] = true
		waitFor(t, fmt.Sprintf("round %d to answer", i), func() bool {
			code, err := health(t, srv, port)
			return err == nil && code == http.StatusOK
		})
	}
	select {
	case err := <-done:
		t.Fatalf("Serve gave up partway through: %v", err)
	default:
	}
}

// Resume on a closed server must fail rather than bind a socket nothing will
// ever serve -- the uninstall case, where the watcher is still in its loop.
func TestResumeAfterCloseDoesNotBind(t *testing.T) {
	srv, _ := newPaused(t)
	if err := srv.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := srv.Resume(); err == nil {
		t.Error("Resume succeeded after Close")
	}
	if got := srv.Port(); got != 0 {
		t.Errorf("port after a refused Resume = %d, want 0", got)
	}
}

// Sanity: the ports really are being released, not just forgotten.
func TestPauseReleasesThePort(t *testing.T) {
	srv, _ := newPaused(t)
	defer func() { _ = srv.Close() }()

	port := srv.Port()
	srv.Pause()

	waitFor(t, "the port to become bindable again", func() bool {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			return false
		}
		_ = ln.Close()
		return true
	})
}

// Close deletes the config outright, where Pause only zeroes the port. That
// difference is what separates "come back later" from "this install is gone".
func TestCloseRemovesTheConfigAPauseLeftBehind(t *testing.T) {
	save := t.TempDir()
	srv, err := New(save, "test", nil, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	go func() { _ = srv.Serve() }()

	srv.Pause()
	if _, err := ReadConfig(save); err != nil {
		t.Fatalf("a pause should leave a config: %v", err)
	}
	if err := srv.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if _, err := os.Stat(ConfigPath(save)); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("config survived Close: %v", err)
	}
}

// A helper that was replaced while the game was running must not take the
// config back when the game next starts -- the replacement is the one the
// game has to find.
func TestResumeStandsDownWhenAnotherHelperOwnsTheConfig(t *testing.T) {
	save := t.TempDir()
	srv, err := New(save, "test", nil, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer func() { _ = srv.Close() }()
	go func() { _ = srv.Serve() }()

	srv.Pause()
	// the replacement publishes over the paused config
	other := []byte(`{"port":40404,"token":"the-replacement","version":"x","pid":2}`)
	if err := os.WriteFile(ConfigPath(save), other, 0o600); err != nil {
		t.Fatal(err)
	}

	if err := srv.Resume(); err == nil {
		t.Fatal("Resume took over an install another helper owns")
	}
	if !srv.Paused() {
		t.Error("a refused Resume left the server unpaused")
	}
	if got := srv.Port(); got != 0 {
		t.Errorf("a refused Resume left port %d bound", got)
	}
	cfg, err := ReadConfig(save)
	if err != nil {
		t.Fatalf("the replacement's config was disturbed: %v", err)
	}
	if cfg.Token != "the-replacement" || cfg.Port != 40404 {
		t.Errorf("config = %+v, want the replacement's untouched", cfg)
	}
}

// And a config that has gone entirely means the uninstaller took it: coming
// back would be refusing to die.
func TestResumeStandsDownWhenTheConfigIsGone(t *testing.T) {
	save := t.TempDir()
	srv, err := New(save, "test", nil, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer func() { _ = srv.Close() }()
	go func() { _ = srv.Serve() }()

	srv.Pause()
	if err := os.Remove(ConfigPath(save)); err != nil {
		t.Fatal(err)
	}
	if err := srv.Resume(); err == nil {
		t.Fatal("Resume rebound after the config had been removed")
	}
	if _, err := os.Stat(ConfigPath(save)); !errors.Is(err, os.ErrNotExist) {
		t.Error("Resume put the config back")
	}
}

// The regression this pins: closing a listener stops new connections and does
// nothing to established ones. A client holding a keep-alive connection went on
// being served by a "paused" helper -- which is not paused, it is just harder to
// reach. Caught by CI on Linux, where the pooled socket got reused and Windows
// happened not to.
func TestAPausedServerStopsAnsweringAKeptAliveConnection(t *testing.T) {
	srv, _ := newPaused(t)
	defer func() { _ = srv.Close() }()

	port := srv.Port()
	// deliberately the pooling kind, unlike health()
	client := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{}}
	defer client.CloseIdleConnections()

	ask := func() (int, error) {
		req, err := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/health", port), nil)
		if err != nil {
			return 0, err
		}
		req.Header.Set("X-Browser-Token", srv.Token())
		resp, err := client.Do(req)
		if err != nil {
			return 0, err
		}
		// read to completion so the connection really does go back in the pool
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		return resp.StatusCode, nil
	}

	waitFor(t, "the first request to succeed", func() bool {
		code, err := ask()
		return err == nil && code == http.StatusOK
	})

	srv.Pause()

	if code, err := ask(); err == nil {
		t.Errorf("a paused helper served a kept-alive connection: HTTP %d", code)
	}
}
