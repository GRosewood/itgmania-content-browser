//go:build windows

package installer

// Windows cabinets log in -- an automatic logon is still a logon -- so the
// scheduled task fires and there is no launch script to find. Both answers are
// the "nothing to do" ones.

func FindGameLauncher(Install) (string, bool) { return "", false }

func PatchLauncher(Install) (string, bool, error) { return "", false, nil }

func UnpatchLauncher(Install) (string, bool) { return "", false }
