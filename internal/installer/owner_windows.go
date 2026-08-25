//go:build windows

package installer

import "os"

// Windows has neither the problem nor the mechanism.
//
// There is no sudo to lose track of who is installing, and file ownership does
// not decide who may rewrite a file -- the ACL the file inherits from its
// directory does, and it inherits it whoever wrote it. So these are the
// same-shaped functions doing nothing, which keeps the callers free of build
// tags of their own.

func isRoot() bool { return false }

func chownLike(path, model string) {}

// candidateHomes is the one profile Windows has.
func candidateHomes(installRoot string) []string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return nil
	}
	return []string{home}
}

// RunningAsAnother is always false: see above.
func RunningAsAnother(path string) bool { return false }
