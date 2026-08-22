package installer

import (
	"os/exec"
	"runtime"
	"strings"
)

// GameRunning reports whether ITGmania appears to be running.
//
// This matters: ITGmania rewrites Preferences.ini from memory when it exits,
// so an edit made while it is running would simply be discarded.
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
		// pgrep -x matches the exact process name; -i ignores case so both
		// "itgmania" (Linux) and "ITGmania" (macOS) are caught.
		if err := exec.Command("pgrep", "-x", "-i", "itgmania").Run(); err == nil {
			return true
		}
		return false
	}
}
