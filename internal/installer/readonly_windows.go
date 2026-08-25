//go:build windows

package installer

import "os"

// Windows has no read-only-image story worth detecting here: the cabinet
// images this exists for are Linux. Both answers are the permissive ones, so
// nothing on Windows changes behaviour because of them.
func readOnlyFS(string) bool { return false }

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
