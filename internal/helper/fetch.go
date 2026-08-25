package helper

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// The fetch endpoint: the game's window to the three sites the browser reads.
//
// ITGmania will not let a theme talk to a host unless the player's
// Preferences.ini allowlists it, which is right -- themes are untrusted -- but
// it means an install writes four entries into a file players are told never
// to edit. This helper is already reachable at 127.0.0.1 with a token, and it
// can talk to anything. Routing the browser's reads through it shrinks what an
// install has to touch to the one loopback entry the helper needs anyway.
//
// It is NOT an open proxy. Only the hosts the browser actually reads may be
// fetched -- anything else is refused before a connection is made -- because a
// token-gated loopback service that fetched arbitrary URLs would still be a
// nicer SSRF hop than any piece of a rhythm game has a right to be.

// upstreamHosts is every host the browser reads, and nothing else. A
// subdomain of a listed host passes ("search.stepmaniaonline.net"); an
// unrelated host does not, however it is dressed up.
var upstreamHosts = []string{
	"stepmaniaonline.net", // the catalogue, pack pages, downloads
	"arrowcloud.dance",    // what people are actually playing
	"itgdb.net",           // the doubles-pack category
}

func upstreamAllowed(host string) bool {
	host = strings.ToLower(host)
	// a literal port never appears in these URLs, but cheap to strip
	host, _ = splitHostMaybePort(host)
	for _, allowed := range upstreamHosts {
		if host == allowed || strings.HasSuffix(host, "."+allowed) {
			return true
		}
	}
	return false
}

func splitHostMaybePort(host string) (string, string) {
	if !strings.Contains(host, ":") {
		return host, ""
	}
	i := strings.LastIndex(host, ":")
	return host[:i], host[i+1:]
}

// fetchClient keeps its own timeouts rather than trusting the caller's. The
// engine's HTTP layer has one worker thread; a proxy request that hung forever
// would wedge every request the game makes after it.
//
// The redirect policy is the other half of the allowlist. Checking only the
// URL the game asked for is checking nothing: Go follows up to ten redirects
// by default, so one open-redirect endpoint on an allowlisted community site
// -- or a tampered plain-http response -- would walk this relay straight off
// its list to any address it can reach. Every hop is held to the same rule as
// the first, and a hop that escapes fails the whole fetch, which reaches the
// game as the 502 any transport failure already does.
var fetchClient = &http.Client{
	Timeout: 3 * time.Minute, // a pack download through here can be legitimately slow
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
			return fmt.Errorf("redirected to a %s url", req.URL.Scheme)
		}
		if !upstreamAllowed(req.URL.Host) {
			return fmt.Errorf("redirected to %s, which is not a host this browser reads", req.URL.Host)
		}
		if len(via) >= 10 {
			return fmt.Errorf("too many redirects")
		}
		return nil
	},
}

// handleFetch relays one request to an allowlisted host and hands back the
// body and status exactly as they arrived, so the Lua that parses the answer
// does not know or care that the helper was in the middle.
//
// The target rides in the "u" query parameter. The upstream's status code
// becomes this response's status code; a transport failure -- refused, DNS,
// timeout -- is 502 with the reason in the body, which the module's existing
// error paths already treat as "the fetch failed".
func (s *Server) handleFetch(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("u")
	if raw == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "no url given",
		})
		return
	}
	target, err := url.Parse(raw)
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "not an http url",
		})
		return
	}
	if !upstreamAllowed(target.Host) {
		writeJSON(w, http.StatusForbidden, map[string]any{
			"ok": false, "error": target.Host + " is not a host this browser reads",
		})
		return
	}

	// The method and body pass through, so the one POST the catalogue's
	// datatables endpoint wants works the same as every GET.
	req, err := http.NewRequestWithContext(r.Context(), r.Method, target.String(), r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	if ct := r.Header.Get("Content-Type"); ct != "" {
		req.Header.Set("Content-Type", ct)
	}

	resp, err := fetchClient.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	defer resp.Body.Close()

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// handleCredits answers who charted a pack, from the pack's own simfiles.
//
// It exists because the catalogue's credit index cannot be trusted for older
// packs: a pack that is entirely one charter's work can show a single
// credited chart there, and a search ranking built on that misfiles exactly
// the packs an author would search for. Reading the simfiles costs the pack's
// zip index plus one small ranged read per song, all of it cached with the
// same archive the previews use.
func (s *Server) handleCredits(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok": false, "error": "POST only",
		})
		return
	}
	if s.packCred == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok": false, "error": "reading pack archives is unavailable",
		})
		return
	}
	var req struct {
		Pack int `json:"pack"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil || req.Pack <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"ok": false, "error": "no pack given",
		})
		return
	}
	info, err := s.packCred(req.Pack)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"ok": false, "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "credits": info})
}
