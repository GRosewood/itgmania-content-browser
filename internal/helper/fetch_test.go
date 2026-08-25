package helper

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
)

// The relay must fetch the browser's hosts and nothing else -- a token-gated
// loopback service that fetched arbitrary URLs would be an SSRF hop.
func TestUpstreamAllowedIsAnAllowlistNotAPattern(t *testing.T) {
	yes := []string{
		"stepmaniaonline.net", "search.stepmaniaonline.net",
		"arrowcloud.dance", "api.arrowcloud.dance", "itgdb.net", "www.itgdb.net",
	}
	no := []string{
		"example.com", "stepmaniaonline.net.evil.com", "evilstepmaniaonline.net",
		"localhost", "127.0.0.1", "169.254.169.254", "itgdb.net.attacker.io",
	}
	for _, h := range yes {
		if !upstreamAllowed(h) {
			t.Errorf("upstreamAllowed(%q) = false, want true", h)
		}
	}
	for _, h := range no {
		if upstreamAllowed(h) {
			t.Errorf("upstreamAllowed(%q) = true, want false", h)
		}
	}
}

func TestFetchRefusesForeignHostsAndRelaysAllowedOnes(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			body, _ := io.ReadAll(r.Body)
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte("posted:" + string(body)))
			return
		}
		w.Header().Set("Content-Type", "text/csv")
		w.Write([]byte("id,name\n1,test"))
	}))
	defer upstream.Close()

	srv, err := New(t.TempDir(), "test", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve()
	defer srv.Close()

	// The test upstream is on 127.0.0.1, which the allowlist refuses -- so the
	// relay's own filter is what this exercises. To test the pass-through, the
	// allowlist is widened to the test server's host for the duration.
	saved := upstreamHosts
	defer func() { upstreamHosts = saved }()

	base := "http://127.0.0.1:" + strconv.Itoa(srv.Port())
	get := func(target string) (*http.Response, string) {
		u := base + "/fetch?t=" + srv.Token() + "&u=" + url.QueryEscape(target)
		resp, err := http.Get(u)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp, string(body)
	}

	// A host not on the list is refused before any connection is made.
	if resp, body := get("https://example.com/anything"); resp.StatusCode != http.StatusForbidden {
		t.Errorf("foreign host: status %d body %q, want 403", resp.StatusCode, body)
	}
	// So is the loopback itself -- the relay must not re-enter this machine.
	if resp, _ := get("http://127.0.0.1:1/x"); resp.StatusCode != http.StatusForbidden {
		t.Errorf("loopback target: status %d, want 403", resp.StatusCode)
	}
	// And a missing token is refused by the same guard as everything else.
	nok, err := http.Get(base + "/fetch?u=" + url.QueryEscape("https://stepmaniaonline.net/"))
	if err != nil {
		t.Fatal(err)
	}
	nok.Body.Close()
	if nok.StatusCode != http.StatusForbidden {
		t.Errorf("no token: status %d, want 403", nok.StatusCode)
	}

	// Widened, the relay hands back body, status and content type untouched.
	hostOnly := strings.TrimPrefix(upstream.URL, "http://")
	hostOnly, _ = splitHostMaybePort(hostOnly)
	upstreamHosts = append(upstreamHosts, hostOnly)

	resp, body := get(upstream.URL + "/api/packs")
	if resp.StatusCode != http.StatusOK || body != "id,name\n1,test" {
		t.Errorf("relay: status %d body %q", resp.StatusCode, body)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "text/csv" {
		t.Errorf("relay content type = %q, want text/csv", ct)
	}

	// POST bodies pass through with their method.
	post, err := http.Post(
		base+"/fetch?t="+srv.Token()+"&u="+url.QueryEscape(upstream.URL+"/dt"),
		"application/x-www-form-urlencoded", strings.NewReader("draw=1"))
	if err != nil {
		t.Fatal(err)
	}
	pbody, _ := io.ReadAll(post.Body)
	post.Body.Close()
	if post.StatusCode != http.StatusCreated || string(pbody) != "posted:draw=1" {
		t.Errorf("relay POST: status %d body %q", post.StatusCode, pbody)
	}
}

// A redirect must not walk the relay off its allowlist -- the check on the
// first URL means nothing if hop two can go anywhere.
func TestFetchRefusesRedirectsOffTheAllowlist(t *testing.T) {
	// The destination that must never be reached.
	var leaked bool
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		leaked = true
	}))
	defer target.Close()

	// An "allowlisted" upstream that redirects off the list...
	bouncer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/inside" {
			// ...and one path that redirects within the same host, which is
			// the redirect the real sites legitimately use.
			http.Redirect(w, r, "/landed", http.StatusFound)
			return
		}
		if r.URL.Path == "/landed" {
			w.Write([]byte("stayed home"))
			return
		}
		// Redirect to the same machine under a DIFFERENT name -- the widened
		// allowlist entry is the IP literal, and "localhost" is not on it, so
		// this hop is exactly an escape even though both servers are local.
		http.Redirect(w, r, strings.Replace(target.URL, "127.0.0.1", "localhost", 1)+"/steal", http.StatusFound)
	}))
	defer bouncer.Close()

	srv, err := New(t.TempDir(), "test", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve()
	defer srv.Close()

	saved := upstreamHosts
	defer func() { upstreamHosts = saved }()
	host := strings.TrimPrefix(bouncer.URL, "http://")
	host, _ = splitHostMaybePort(host)
	upstreamHosts = append(upstreamHosts, host)
	// upstreamAllowed ignores ports, so the widened "127.0.0.1" entry covers
	// every local server reached BY THAT NAME -- which is why the bouncer
	// redirects to "localhost" instead: same machine, different hostname,
	// off the list.

	base := "http://127.0.0.1:" + strconv.Itoa(srv.Port())
	resp, err := http.Get(base + "/fetch?t=" + srv.Token() + "&u=" + url.QueryEscape(bouncer.URL+"/out"))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Errorf("off-list redirect: status %d body %q, want 502", resp.StatusCode, body)
	}
	if leaked {
		t.Error("the off-list target was actually fetched")
	}

	// The legitimate same-host redirect still works.
	resp2, err := http.Get(base + "/fetch?t=" + srv.Token() + "&u=" + url.QueryEscape(bouncer.URL+"/inside"))
	if err != nil {
		t.Fatal(err)
	}
	body2, _ := io.ReadAll(resp2.Body)
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK || string(body2) != "stayed home" {
		t.Errorf("same-host redirect: status %d body %q", resp2.StatusCode, body2)
	}
}
