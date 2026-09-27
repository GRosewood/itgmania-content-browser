//go:build !windows

package installer

import (
	"os"
	"path/filepath"
	"strings"
)

// FindSystemImage recognises the ITG System Image by the script that starts
// its game -- start.sh in the player's home -- and works out what keeping the
// songs drive writable would take there.
func FindSystemImage(inst Install) (SystemImage, bool) {
	home := autostartHome(inst)
	if home == "" {
		return SystemImage{}, false
	}
	path := filepath.Join(home, "start.sh")
	raw, err := os.ReadFile(path)
	if err != nil {
		return SystemImage{}, false
	}
	// read what the image itself says, not what an earlier run added
	lines, ours := withoutSongsDriveBlock(splitLines(string(raw)))
	s, ok := parseImageScript(strings.Join(lines, "\n"))
	if !ok {
		return SystemImage{}, false
	}

	// The image lists one folder here; the drive is the one the first of them
	// is on, and anything else it lists stays read-only.
	img := SystemImage{StartScript: path, SongsDir: s.readOnly[0], Writable: ours}
	img.OtherRO = strings.Join(s.readOnly[1:], ",")
	img.MountPoint, _ = mountOf(img.SongsDir)
	if img.MountPoint == "" || img.MountPoint == "/" {
		return SystemImage{}, false
	}
	return img, true
}

// PutSongsDriveBack takes the block out of the image's start script, for an
// uninstall. The script's own lines make the drive read-only again the next
// time the game starts.
func PutSongsDriveBack(inst Install) (string, bool) {
	home := autostartHome(inst)
	if home == "" {
		return "", false
	}
	path := filepath.Join(home, "start.sh")
	if removed, err := removeSongsDriveBlock(path); err == nil && removed {
		return path, true
	}
	return "", false
}
