package installer

// The preview relay: the web service that reads pack zips on the download
// host and serves the game the things its engine cannot make for itself --
// playable audio, chart windows, single-song archives. It replaced the
// loopback helper this package used to install, register and babysit.

import (
	"net/http"
	"os"
	"path/filepath"
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
func RelayReachable(base string) bool {
	client := &http.Client{Timeout: 4 * time.Second}
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
