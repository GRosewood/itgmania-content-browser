//go:build !windows

package installer

// Who this install belongs to, when the installer is not being run as them.
//
// Two things go wrong when a cabinet is set up with sudo, and both are quiet.
//
// The first is that per-user paths stop meaning anything: HOME is root's, so
// ~/.itgmania/Save is root's profile, and the installer reads a Preferences.ini
// the game has never seen -- which is how it fails to learn the active theme
// and writes the network allowlist into the void. SUDO_USER covers `sudo cmd`,
// but a root shell opened with `sudo su -` or `su -` has had the environment
// scrubbed and carries no trace of who opened it. So the environment is only
// one of several answers here, and not the one trusted first.
//
// The second is ownership. A file created by root is owned by root, and the
// game runs as the cabinet user: a Preferences.ini rewritten by the atomic
// replace below stops being writable by the player, so their settings silently
// stop persisting on exit, and module files owned by root cannot be replaced by
// the in-game updater, which runs as them. Anything written here is handed back
// to whoever owned the place it was written into.

import (
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
)

// isRoot reports whether this process can change file ownership at all.
func isRoot() bool { return os.Geteuid() == 0 }

// fileOwner is the uid and gid of a path.
func fileOwner(path string) (uid, gid int, ok bool) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, 0, false
	}
	st, fine := info.Sys().(*syscall.Stat_t)
	if !fine {
		return 0, 0, false
	}
	return int(st.Uid), int(st.Gid), true
}

// chownLike gives path the owner of model.
//
// Best effort and silent: not being able to hand a file back is not a reason to
// fail an install that otherwise worked, and the common case -- running as the
// same user the game does -- has nothing to hand back.
func chownLike(path, model string) {
	if !isRoot() {
		return
	}
	uid, gid, ok := fileOwner(model)
	if !ok || uid == os.Geteuid() {
		return
	}
	_ = os.Lchown(path, uid, gid)
}

// homeOf is a user's home directory, by uid.
func homeOf(uid int) string {
	u, err := user.LookupId(strconv.Itoa(uid))
	if err != nil || u.HomeDir == "" {
		return ""
	}
	return u.HomeDir
}

// candidateHomes lists the home directories a game profile might be under,
// most likely first.
//
// The owner of the install comes first and is the only one that needs no
// environment at all: a game unpacked into somebody's home is owned by them,
// whatever shell the installer was started from. The environment variables come
// next, for an install that lives somewhere system-wide. The scan of /home is
// last and exists for the case this is really about -- a root shell with no
// history, over an install in /opt that tells you nothing.
func candidateHomes(installRoot string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(dir string) {
		if dir == "" || seen[dir] {
			return
		}
		seen[dir] = true
		out = append(out, dir)
	}

	if uid, _, ok := fileOwner(installRoot); ok && uid != 0 {
		add(homeOf(uid))
	}
	if who := os.Getenv("SUDO_USER"); who != "" && who != "root" {
		if u, err := user.Lookup(who); err == nil {
			add(u.HomeDir)
		}
	}
	if raw := os.Getenv("PKEXEC_UID"); raw != "" {
		if uid, err := strconv.Atoi(raw); err == nil && uid != 0 {
			add(homeOf(uid))
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		add(home)
	}

	// Last resort: every home on the machine. Ordered by the directory listing,
	// which is alphabetical, and narrowed afterwards by which of them actually
	// holds a Preferences.ini -- so a machine with several users does not get
	// somebody else's profile picked on a coin toss.
	if entries, err := os.ReadDir("/home"); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				add(filepath.Join("/home", e.Name()))
			}
		}
	}
	return out
}

// RunningAsAnother reports whether this process is root and the path belongs to
// somebody else. It is what tells a listing that the profile it found is not
// the account at the keyboard -- worth saying, because that is exactly the
// situation where a wrong guess would otherwise be invisible.
func RunningAsAnother(path string) bool {
	if !isRoot() {
		return false
	}
	uid, _, ok := fileOwner(path)
	return ok && uid != os.Geteuid()
}

// chownToGameUser hands a path to the account that plays.
//
// chownLike copies the owner of a neighbouring path, which is right for
// Preferences.ini -- it lives in the player's own profile -- and wrong for the
// module. ITGmania's own Linux installer requires root and unpacks the game
// into /opt/itgmania, so the theme directory and everything under it is owned
// by root. Copying that owner left the module root-owned, and the in-game
// updater runs as the player through the helper: it could see an update, fetch
// it, and then fail to replace a single file.
//
// Directories matter more than files here. Replacing a file means unlinking
// and creating it, which needs write permission on the DIRECTORY, so the
// Modules directory and our parts folder are the ones that have to belong to
// the player.
func chownToGameUser(path string, u GameUser) {
	if !isRoot() || u.Uid <= 0 {
		return
	}
	_ = os.Lchown(path, u.Uid, u.Gid)
}

// runAsGameUser makes a command run as the account that plays.
//
// Only meaningful when this installer is root and installing for somebody
// else, which is the cabinet case: ITGmania's own Linux installer requires
// root and unpacks into /opt, so an operator setting a machine up is root and
// the player is not. A helper started as root publishes a root-owned config
// into the player's profile, which the helper that starts properly at the next
// boot then cannot overwrite -- so the machine works until it is rebooted and
// then quietly stops working.
func runAsGameUser(cmd *exec.Cmd, u GameUser) {
	if !isRoot() || u.Uid <= 0 {
		return
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Credential = &syscall.Credential{
		Uid: uint32(u.Uid),
		Gid: uint32(u.Gid),
	}
	// The helper resolves nothing from HOME, but anything it shells out to
	// might, and a HOME of /root inside another account's session is a trap.
	cmd.Env = append(os.Environ(), "HOME="+u.Home, "USER="+u.Name, "LOGNAME="+u.Name)
}
