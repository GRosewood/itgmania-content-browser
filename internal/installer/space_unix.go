//go:build !windows

package installer

import "syscall"

// FreeBytes is how much room is left on the filesystem holding dir.
//
// The available figure rather than the free one: Unix filesystems keep a
// reserve only root may use, and a player is not root. Reporting the free
// figure would promise space a download cannot actually have.
func FreeBytes(dir string) (int64, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, false
	}
	return int64(st.Bavail) * int64(st.Bsize), true
}
