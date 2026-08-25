//go:build windows

package installer

// Windows has one profile per logon and no sudo, so there is nothing to
// resolve: the account running the installer is the account that plays.

type GameUser struct {
	Name string
	Uid  int
	Gid  int
	Home string
	How  string
}

var forcedUser string

func ForceUser(name string) { forcedUser = name }

func ResolveGameUser(string) (GameUser, bool) { return GameUser{}, false }
