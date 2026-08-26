package installer

// The preview relay: the web service that reads pack zips on the download
// host and serves the game the things its engine cannot make for itself --
// playable audio, chart windows, single-song archives. It replaced the
// loopback helper this package used to install, register and babysit.

import (
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// RelayBase is where this install's browser will look for the relay: the one
// line of Save/ITGmaniaContentBrowser/webapp.txt when it is there, and the
// deployed relay otherwise -- the same rule the module applies.
func RelayBase(inst Install) string {
	base := "https://itgcontent.net"
	raw, err := os.ReadFile(filepath.Join(HelperDir(inst), "webapp.txt"))
	if err != nil {
		return base
	}
	line := strings.TrimSpace(strings.SplitN(string(raw), "\n", 2)[0])
	line = strings.TrimRight(line, "/")
	if strings.HasPrefix(line, "http://") || strings.HasPrefix(line, "https://") {
		return line
	}
	return base
}

// RelayReachable asks the relay whether it is there at all. Any HTTP answer
// counts: the question is reachability, not health.
func RelayReachable(base string) bool { return reachableWith(base, nil) }

// GameCABundle is the certificate list the ENGINE validates against.
//
// ITGmania does its HTTPS through mbedTLS against Data/ca-bundle.crt, and does
// not consult the operating system's trust store at all. So "this machine can
// reach the relay" and "the game can reach the relay" are different questions,
// and answering the easy one is worse than not asking: a cabinet whose bundle
// predates the relay's certificate chain reports a healthy network from every
// tool on it while the browser says the preview endpoint is not reachable.
func GameCABundle(inst Install) string {
	path := filepath.Join(inst.Root, "Data", "ca-bundle.crt")
	if isFile(path) {
		return path
	}
	return ""
}

// RelayTrustedByGame reports whether the relay's certificate validates against
// the engine's own bundle. ok=false with have=false means the bundle was not
// found and nothing was proven.
func RelayTrustedByGame(inst Install, base string) (ok, have bool) {
	pool, have := gameRoots(inst)
	if !have {
		return false, false
	}
	return reachableWith(base, pool), true
}

func gameRoots(inst Install) (*x509.CertPool, bool) {
	bundle := GameCABundle(inst)
	if bundle == "" {
		return nil, false
	}
	pem, err := os.ReadFile(bundle)
	if err != nil {
		return nil, false
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, false
	}
	return pool, true
}

// TrustHosts is every HTTPS endpoint the browser depends on besides the relay.
// They are listed here rather than derived from the allowlist because the
// allowlist is about permission and this is about trust: a host can be
// perfectly allowed and still fail, and the two produce very different
// symptoms in the game.
var TrustHosts = []string{
	"https://stepmaniaonline.net",
	"https://itgdb.net",
	"https://api.arrowcloud.dance",
	"https://raw.githubusercontent.com",
}

// UntrustedByGame returns the hosts this machine can reach but the ENGINE
// would refuse, because its bundle cannot validate their certificates.
//
// Reachability is tested first with the system roots, so a host that is simply
// down or blocked is not reported as a certificate problem -- those need
// different answers, and guessing between them is how a network fault gets
// chased as a trust fault.
func UntrustedByGame(inst Install, bases []string) (bad []string, checked bool) {
	pool, have := gameRoots(inst)
	if !have {
		return nil, false
	}
	type result struct {
		base      string
		reachable bool
		trusted   bool
	}
	ch := make(chan result, len(bases))
	for _, base := range bases {
		go func(b string) {
			ch <- result{b, reachableWith(b, nil), reachableWith(b, pool)}
		}(base)
	}
	for range bases {
		r := <-ch
		if r.reachable && !r.trusted {
			bad = append(bad, r.base)
		}
	}
	sort.Strings(bad)
	return bad, true
}

func reachableWith(base string, roots *x509.CertPool) bool {
	transport := &http.Transport{}
	if roots != nil {
		transport.TLSClientConfig = &tls.Config{RootCAs: roots}
	}
	client := &http.Client{Timeout: 6 * time.Second, Transport: transport}
	resp, err := client.Get(base + "/")
	if err != nil {
		return false
	}
	_ = resp.Body.Close()
	return true
}

// HelperBinaryPresent reports whether an old install's helper binary is still
// on disk -- a leftover for -check to point at, nothing more.
func HelperBinaryPresent(inst Install) bool { return isFile(HelperBinary(inst)) }
