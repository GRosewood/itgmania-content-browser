//go:build !windows

package installer

// Everywhere except Windows the helper listens the whole time it runs.
//
// Not for want of a way to watch: Linux has pidfds and macOS has kqueue. It is
// that the thing being solved does not exist there. The complaint was a console
// window appearing at every Windows logon and a socket outliving the game that
// used it; on a Linux cabinet the helper is a systemd user service that the
// machine already manages, and on macOS a launch agent, and neither shows the
// player anything. Adding a second lifecycle underneath one that works would be
// two things to be wrong instead of one.

// GameWatchSupported says whether this platform gates the socket on the game.
func GameWatchSupported() bool { return false }

// WaitForGame is never called where the watch is unsupported. It returns at
// once rather than blocking, so a caller that ignores GameWatchSupported spins
// visibly instead of hanging silently.
func WaitForGame(stop <-chan struct{}) (uint32, bool) { return 0, false }

// WaitForGameExit likewise does nothing here.
func WaitForGameExit(pid uint32) {}
