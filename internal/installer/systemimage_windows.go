//go:build windows

package installer

// The ITG System Image is a Linux cabinet OS; there is nothing to find here.
func FindSystemImage(Install) (SystemImage, bool) { return SystemImage{}, false }

func PutSongsDriveBack(Install) (string, bool) { return "", false }
