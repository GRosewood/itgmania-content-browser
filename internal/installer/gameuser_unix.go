//go:build !windows

package installer

// Who actually runs ITGmania.
//
// Everything this installer writes belongs to that account: Preferences.ini,
// the theme it reads to know which theme is in use, the helper binary, the
// autostart registration, the launcher edit. Get the account wrong and all of
// it lands somewhere the player never looks, while the installer reports
// success.
//
// The environment cannot answer this. Run under `sudo su`, HOME is /root and
// SUDO_USER is whoever opened the shell -- which on a cabinet is very often
// not the account the game runs as. The old code consulted exactly those and
// then fell back to "the first profile we would have looked in", which is how
// a cabinet whose game runs as `dance` ended up with a fresh Preferences.ini
// under /root and a helper registered for root.
//
// So this asks for evidence instead, strongest first, and never settles for
// root while a non-root answer is available.

import (
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// GameUser is the account the game runs as, and how that was decided.
type GameUser struct {
	Name string
	Uid  int
	Gid  int
	Home string
	How  string // the evidence, for the installer to show its working
}

// forcedUser is set from -user. An explicit answer beats every guess.
var forcedUser string

// ForceUser pins the account to install for.
func ForceUser(name string) { forcedUser = name }

func userByName(name string) (GameUser, bool) {
	u, err := user.Lookup(name)
	if err != nil {
		return GameUser{}, false
	}
	uid, _ := strconv.Atoi(u.Uid)
	gid, _ := strconv.Atoi(u.Gid)
	return GameUser{Name: u.Username, Uid: uid, Gid: gid, Home: u.HomeDir}, true
}

func userByUID(uid int) (GameUser, bool) {
	u, err := user.LookupId(strconv.Itoa(uid))
	if err != nil || u.HomeDir == "" {
		return GameUser{}, false
	}
	gid, _ := strconv.Atoi(u.Gid)
	return GameUser{Name: u.Username, Uid: uid, Gid: gid, Home: u.HomeDir}, true
}

// runningGameUID is the owner of a running ITGmania, if one is running.
//
// The strongest evidence there is -- the process is the game -- and it costs
// nothing to look. The installer refuses to run while the game is up, but the
// refusal can then name the account instead of leaving somebody guessing.
func runningGameUID() (int, bool) {
	procs, err := os.ReadDir("/proc")
	if err != nil {
		return 0, false
	}
	self := os.Getpid()
	for _, p := range procs {
		pid, err := strconv.Atoi(p.Name())
		if err != nil || pid == self {
			continue
		}
		raw, err := os.ReadFile(filepath.Join("/proc", p.Name(), "cmdline"))
		if err != nil {
			continue
		}
		line := strings.ToLower(strings.ReplaceAll(string(raw), "\x00", " "))
		if !strings.Contains(line, "itgmania") {
			continue
		}
		// our own binaries mention itgmania in their names
		if strings.Contains(line, "content-browser") {
			continue
		}
		st, err := os.Stat(filepath.Join("/proc", p.Name()))
		if err != nil {
			continue
		}
		if sys, ok := st.Sys().(*syscall.Stat_t); ok {
			return int(sys.Uid), true
		}
	}
	return 0, false
}

// homesOnThisMachine is every real home directory, with its owner.
func homesOnThisMachine() []GameUser {
	var out []GameUser
	seen := map[int]bool{}
	add := func(dir string) {
		uid, gid, ok := fileOwner(dir)
		if !ok || seen[uid] {
			return
		}
		seen[uid] = true
		u, found := userByUID(uid)
		if !found {
			u = GameUser{Uid: uid, Gid: gid, Home: dir, Name: strconv.Itoa(uid)}
		}
		out = append(out, u)
	}
	for _, base := range []string{"/home", "/Users"} {
		entries, err := os.ReadDir(base)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				add(filepath.Join(base, e.Name()))
			}
		}
	}
	return out
}

// ResolveGameUser works out which account to install for.
func ResolveGameUser(root string) (GameUser, bool) {
	if forcedUser != "" {
		if u, ok := userByName(forcedUser); ok {
			u.How = "named with -user"
			return u, true
		}
		return GameUser{}, false
	}

	// 1. The game itself, if it is up. Nothing beats watching it run.
	if uid, ok := runningGameUID(); ok {
		if u, found := userByUID(uid); found && u.Uid != 0 {
			u.How = "ITGmania is running as this account"
			return u, true
		}
	}

	// 2. A profile that already holds a Preferences.ini. That file is written
	//    by the game, so whoever owns it is whoever plays.
	var best GameUser
	var bestWhen int64 = -1
	for _, u := range homesOnThisMachine() {
		if u.Uid == 0 {
			continue
		}
		prefs := filepath.Join(saveUnderHome(u.Home), "Preferences.ini")
		info, err := os.Stat(prefs)
		if err != nil {
			continue
		}
		if info.ModTime().Unix() > bestWhen {
			bestWhen = info.ModTime().Unix()
			best = u
			best.How = "owns " + prefs
		}
	}
	if bestWhen >= 0 {
		return best, true
	}

	// 3. Whoever owns the install itself.
	if uid, _, ok := fileOwner(root); ok && uid != 0 {
		if u, found := userByUID(uid); found {
			u.How = "owns " + root
			return u, true
		}
	}

	// 4. Whoever owns a login script that launches the game.
	for _, u := range homesOnThisMachine() {
		if u.Uid == 0 {
			continue
		}
		if path, ok := launcherIn(u.Home); ok {
			u.How = "launches the game from " + path
			return u, true
		}
	}

	// 5. The environment, which is the weakest answer and the one that was
	//    wrong on the machine this was written for. Non-root only.
	for _, env := range []string{"SUDO_USER", "PKEXEC_UID"} {
		v := os.Getenv(env)
		if v == "" {
			continue
		}
		var u GameUser
		var ok bool
		if env == "PKEXEC_UID" {
			uid, err := strconv.Atoi(v)
			if err != nil {
				continue
			}
			u, ok = userByUID(uid)
		} else {
			u, ok = userByName(v)
		}
		if ok && u.Uid != 0 {
			u.How = "named by " + env
			return u, true
		}
	}

	// 6. Ourselves, if we are not root. Running as the player is the ordinary
	//    desktop case and needs no evidence at all.
	if os.Geteuid() != 0 {
		if u, ok := userByUID(os.Geteuid()); ok {
			u.How = "the account running this installer"
			return u, true
		}
	}

	// Deliberately no root fallback. Installing for root on a machine where
	// somebody else plays is the failure this exists to prevent, and a refusal
	// that says so is worth more than a success that is not one.
	return GameUser{}, false
}

// launcherIn is FindGameLauncher for a home directory, without needing an
// Install to ask about.
func launcherIn(home string) (string, bool) {
	for _, path := range launcherCandidates(home) {
		body, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if strings.Contains(strings.ToLower(string(body)), "itgmania") {
			return path, true
		}
	}
	return "", false
}
