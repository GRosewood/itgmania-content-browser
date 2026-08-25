package preview

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The property the per-pack locking exists for: one pack's stalled work must
// not stop another pack's answers. Before it, a single fetcher mutex was held
// across whole extractions, so a wedged download stood in front of every
// request for every pack -- and behind those, the game's only HTTP worker.
func TestASlowPackDoesNotBlockAnotherPack(t *testing.T) {
	release := make(chan struct{})
	fast := buildPack(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// pack 1 hangs until released; pack 2 answers like a normal server
		if r.URL.Path == "/download/pack/1/" {
			<-release
			http.NotFound(w, r)
			return
		}
		http.ServeContent(w, r, "pack.zip", time.Unix(0, 0), bytes.NewReader(fast))
	}))
	defer srv.Close()
	defer close(release)

	f := New(t.TempDir(), srv.URL)

	// Wedge pack 1 in a background goroutine, the way a background install
	// wedges: inside its HEAD, holding whatever locks it holds.
	stuck := make(chan struct{})
	go func() {
		f.PackIni(1)
		close(stuck)
	}()

	// Give the goroutine time to be inside the hanging request.
	time.Sleep(50 * time.Millisecond)

	// Pack 2 must answer while pack 1 is still hanging.
	done := make(chan error, 1)
	go func() {
		_, err := f.PackIni(2)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("pack 2 failed: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("pack 2 was blocked behind pack 1's stalled request")
	}

	select {
	case <-stuck:
		t.Fatal("pack 1 finished early; the test proved nothing")
	default:
	}
}
