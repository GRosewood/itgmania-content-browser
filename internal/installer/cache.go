package installer

import (
	"fmt"
	"os"
	"path/filepath"
)

// CacheDir is the OS path of the game's Cache directory, resolved through any
// symlink on the way to it.
//
// The engine mounts /Cache from a sibling of the Save directory in every
// layout it has: beside the game on a portable install, under the platform's
// user-data folder otherwise (Windows %APPDATA%/ITGmania, Linux ~/.itgmania,
// macOS ~/Library/Application Support/ITGmania -- all three ArchHooks mount
// the same directory list from one base). Save is already resolved by
// discovery, so Cache is one Dir() away from it and inherits every case that
// logic got right.
//
// The resolving matters on cabinets. A dedicated machine routinely points
// Cache at a bigger or faster drive -- a symlink to a mounted partition is
// how the Linux cabinet image does it -- and the game reads straight through
// that without noticing. This helper writes with OS paths rather than the
// game's mounted filesystem, so it resolves the link itself and hands back
// the real target: space checks then measure the right volume, and files land
// where the game will actually look for them.
//
// A Cache that cannot be written to is reported, not worked around. The
// engine writes its own song cache constantly; a machine where /Cache is not
// writable does not have a working game on it, and quietly stashing files
// somewhere else would only mean the game and this helper disagree about
// where things are.
func CacheDir(inst Install) (string, error) {
	if inst.SaveDir == "" {
		return "", fmt.Errorf("no Save directory known, so no Cache beside it")
	}
	dir := filepath.Join(filepath.Dir(inst.SaveDir), "Cache")

	// The game creates this folder on boot, so on any machine that has run it
	// exists already. Creating it here covers a helper started before the
	// game's first run -- and fails honestly where the folder is a symlink to
	// a drive that is not mounted, which is the failure worth hearing about.
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("the Cache directory is not usable: %w", err)
	}

	// Follow the symlink, if the folder is one, so everything downstream works
	// on the real target rather than on the pointer to it.
	if resolved, err := filepath.EvalSymlinks(dir); err == nil {
		dir = resolved
	}

	// Prove it takes writes. A read-only mount answers MkdirAll fine (the
	// directory exists) and then eats every file; better to find that out now
	// with one probe than later with a preview that never plays.
	probe, err := os.CreateTemp(dir, ".content-browser-probe-*")
	if err != nil {
		return "", fmt.Errorf("the Cache directory refuses writes: %w", err)
	}
	name := probe.Name()
	probe.Close()
	os.Remove(name)

	return dir, nil
}
