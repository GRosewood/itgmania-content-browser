//go:build !windows

package installer

import (
	"os"
	"path/filepath"
	"strings"
)

// Is this path on a filesystem nothing can be written to?
//
// Cabinet images are often shipped read-only, and the advice this installer
// gives is worthless there: telling somebody to run `loginctl enable-linger`
// when /var/lib/systemd cannot be written just produces "read-only file
// system" and no explanation. Knowing in advance lets the advice change
// instead of being handed over to fail.
//
// Answered from /proc/mounts rather than by trying a write: the interesting
// paths belong to root, so a failed write from an ordinary user proves nothing
// about the filesystem. The longest mount point that prefixes the path is the
// one it lives on.
func readOnlyFS(path string) bool {
	mounts, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return false // not Linux, or no procfs: do not guess
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}

	best, ro := "", false
	for _, line := range strings.Split(string(mounts), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		// /proc/mounts escapes spaces and tabs in the mount point as octal.
		point := strings.NewReplacer(`\040`, " ", `\011`, "\t").Replace(fields[1])
		if !underMount(point, abs) {
			continue
		}
		if len(point) < len(best) {
			continue
		}
		best = point
		ro = false
		for _, opt := range strings.Split(fields[3], ",") {
			if opt == "ro" {
				ro = true
			}
		}
	}
	return best != "" && ro
}

// underMount reports whether path sits at or below a mount point.
func underMount(point, path string) bool {
	if point == "/" {
		return true
	}
	if path == point {
		return true
	}
	return strings.HasPrefix(path, strings.TrimSuffix(point, "/")+"/")
}

// writableDir reports whether a directory can be created and written here.
// Unlike readOnlyFS this is about permissions as well, and it is only asked
// about paths this installer owns, so an actual attempt is the honest test.
func writableDir(dir string) bool {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return false
	}
	f, err := os.CreateTemp(dir, ".cb-write-probe-*")
	if err != nil {
		return false
	}
	name := f.Name()
	_ = f.Close()
	_ = os.Remove(name)
	return true
}
