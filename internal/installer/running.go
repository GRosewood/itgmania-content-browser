package installer

import (
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
)

// GameRunning reports whether ITGmania appears to be running.
//
// This matters more than it looks: ITGmania rewrites Preferences.ini from
// memory when it exits, so the network allowlist written while it is running
// is discarded the moment the player quits. The installer refuses rather than
// appearing to succeed and leaving the browser switched off.
func GameRunning() bool {
	switch runtime.GOOS {
	case "windows":
		// tasklist is present on every supported Windows version.
		out, err := exec.Command("tasklist", "/FI", "IMAGENAME eq ITGmania.exe", "/NH").Output()
		if err != nil {
			return false
		}
		return strings.Contains(strings.ToLower(string(out)), "itgmania.exe")
	default:
		return unixGameRunning()
	}
}

// unixGameRunning looks for a process whose name contains "itgmania".
//
// Not an exact match. Cabinet images launch the game under names of their own
// -- itgmania-bin, a wrapper script, a systemd unit's exec name -- and an exact
// match on "itgmania" sees none of them, which is how an install can quietly
// happen underneath a running game and lose the allowlist on the next quit.
//
// The looseness has to be paid for, though: this installer's own binary is
// called itgmania-content-browser-installer, so a plain substring match finds
// itself and reports the game as running forever. Our own process and anything
// that is plainly this tool are dropped.
func unixGameRunning() bool {
	// -l prints "pid name", which is what makes the filtering below possible.
	out, err := exec.Command("pgrep", "-i", "-l", "itgmania").Output()
	if err != nil {
		// pgrep exits non-zero when nothing matched, which is the common case
		// and not an error worth reporting.
		return false
	}
	self := os.Getpid()
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) < 2 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil || pid == self {
			continue
		}
		name := strings.ToLower(fields[1])
		if strings.Contains(name, "content-browser") || strings.Contains(name, "installer") {
			continue
		}
		return true
	}
	return false
}
