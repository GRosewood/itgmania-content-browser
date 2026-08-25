//go:build !windows

package installer

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The unit file is what makes a cabinet work, so its contents are pinned here
// rather than left to be discovered on somebody's machine.

func TestSystemdUnitStartsWithTheSession(t *testing.T) {
	body := systemdUnitBody(testInstall("/opt/itgmania"))
	for _, want := range []string{
		"WantedBy=default.target", // this is what the wants symlink points at
		"Type=simple",
		"-install-dir",
		"content-browser-helper",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("unit is missing %q:\n%s", want, body)
		}
	}
}

// Restart=always would fight uninstall: the helper exits 0 on purpose when its
// config is removed, which is exactly how uninstall and upgrade stop it.
func TestSystemdUnitDoesNotFightUninstall(t *testing.T) {
	body := systemdUnitBody(testInstall("/opt/itgmania"))
	if strings.Contains(body, "Restart=always") {
		t.Error("Restart=always would restart a helper that was deliberately stopped")
	}
	if !strings.Contains(body, "Restart=on-failure") {
		t.Error("a helper that crashes should come back")
	}
}

func TestSystemdQuoteHandlesSpacesAndQuotes(t *testing.T) {
	cases := []struct{ in, want string }{
		{"/opt/itgmania", "/opt/itgmania"},
		{"/opt/my games/itg", `"/opt/my games/itg"`},
		{`/opt/we"rd`, `"/opt/we\"rd"`},
		{`/opt/back\slash`, `"/opt/back\\slash"`},
	}
	for _, c := range cases {
		if got := systemdQuote(c.in); got != c.want {
			t.Errorf("systemdQuote(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// A path with a space must survive into ExecStart as one argument, or systemd
// splits it and the helper is started with nonsense.
func TestSystemdUnitQuotesSpacedPaths(t *testing.T) {
	body := systemdUnitBody(testInstall("/opt/my games/itgmania"))
	var exec string
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "ExecStart=") {
			exec = line
		}
	}
	if exec == "" {
		t.Fatal("no ExecStart line")
	}
	if !strings.Contains(exec, `"`) {
		t.Errorf("spaced path was not quoted: %s", exec)
	}
}

func TestDesktopQuoteFollowsTheSpec(t *testing.T) {
	cases := []struct{ in, want string }{
		{"/opt/itg", "/opt/itg"},
		{"/opt/my games/itg", `"/opt/my games/itg"`},
		// A percent is doubled everywhere, quoted or not -- and doubling it is
		// all it needs, so this stays unquoted.
		{"/opt/100%/itg", "/opt/100%%/itg"},
		{"/opt/$HOME/itg", `"/opt/\$HOME/itg"`},
	}
	for _, c := range cases {
		if got := desktopQuote(c.in); got != c.want {
			t.Errorf("desktopQuote(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// Two installs must not share a unit, or uninstalling one stops the other.
func TestUnitNamesArePerInstall(t *testing.T) {
	a := systemdUnitName(testInstall("/opt/itgmania"))
	b := systemdUnitName(testInstall("/opt/itgmania2"))
	if a == b {
		t.Fatal("two installs would share one unit")
	}
	if !strings.HasSuffix(a, ".service") {
		t.Errorf("unit name %q needs a .service suffix", a)
	}
}

// The wants symlink has to live beside the unit, in default.target.wants, or
// nothing enables it. Writing that link is what `systemctl --user enable` does,
// and doing it ourselves is what lets an install work over SSH with no D-Bus.
func TestWantsLinkSitsUnderDefaultTarget(t *testing.T) {
	inst := testInstall("/opt/itgmania")
	link := systemdWantsPath(inst)
	if !strings.Contains(link, "default.target.wants") {
		t.Errorf("wants link %q is not under default.target.wants", link)
	}
	if !strings.HasSuffix(link, systemdUnitName(inst)) {
		t.Errorf("wants link %q does not name the unit", link)
	}
}

// The one that matters on a cabinet: a sudo install over a ROOT-OWNED install
// root must register under the PLAYER's home, not root's.
//
// candidateHomes cannot answer this on its own -- it skips the install owner
// when that owner is root, and `sudo su -` has scrubbed SUDO_USER -- so its
// first entry is root's home. SaveDir is the evidence, because discovery chose
// it by which profile actually holds a Preferences.ini. Registering under root
// is silent and total: the helper is installed under the player's home and the
// unit that should start it is not, so nothing ever starts it.
func TestAutostartHomeFollowsTheSaveDirNotTheGuess(t *testing.T) {
	player := "/home/player"
	inst := Install{
		Root:    "/opt/itgmania", // root-owned, tells you nothing about the user
		SaveDir: saveUnderHome(player),
	}
	if inst.SaveDir == "" {
		t.Skip("no per-home save path on this platform")
	}
	if got := autostartHome(inst); got != player {
		t.Fatalf("autostartHome = %q, want %q -- the registration would land in the wrong home", got, player)
	}
	for _, path := range []string{
		systemdUnitPath(inst), systemdWantsPath(inst), autostartDesktopPath(inst),
	} {
		if !strings.HasPrefix(path, player+"/") {
			t.Errorf("%q is not under the player's home", path)
		}
	}
}

// XDG_CONFIG_HOME describes the CURRENT session. When the game belongs to a
// different account, honouring it writes the registration into the installing
// user's profile, where the player's session never looks.
//
// This is not hypothetical: it is how this first broke. The test above passed
// on a machine with XDG_CONFIG_HOME unset and failed on CI, which sets it --
// autostartHome was right and the directory built from it was not.
func TestXDGConfigHomeIsIgnoredForAnotherAccount(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/home/someone-else/.config")

	player := "/home/player"
	inst := Install{Root: "/opt/itgmania", SaveDir: saveUnderHome(player)}
	if inst.SaveDir == "" {
		t.Skip("no per-home save path on this platform")
	}
	for _, path := range []string{
		systemdUnitPath(inst), systemdWantsPath(inst), autostartDesktopPath(inst),
	} {
		if !strings.HasPrefix(path, player+"/") {
			t.Errorf("%q followed XDG_CONFIG_HOME instead of the game's account", path)
		}
	}
}

// ...but for the account actually at the keyboard, the variable is the right
// answer and must still be honoured -- a session that relocates its config
// directory is entitled to expect things to land there.
func TestXDGConfigHomeIsHonouredForTheCurrentUser(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		t.Skip("no home directory in this environment")
	}
	custom := filepath.Join(home, "custom-config")
	t.Setenv("XDG_CONFIG_HOME", custom)

	inst := Install{Root: "/opt/itgmania", SaveDir: saveUnderHome(home)}
	if inst.SaveDir == "" {
		t.Skip("no per-home save path on this platform")
	}
	if got := systemdUnitPath(inst); !strings.HasPrefix(got, custom+string(filepath.Separator)) {
		t.Errorf("systemdUnitPath = %q, want it under %q", got, custom)
	}
}

// A portable install keeps its Save beside the game, under nobody's home, so
// there is nothing to match and the guess is all there is. It must not crash or
// return empty.
func TestAutostartHomeFallsBackForPortableInstalls(t *testing.T) {
	inst := Install{Root: "/opt/itgmania", SaveDir: "/opt/itgmania/Save"}
	if got := autostartHome(inst); got == "" {
		t.Fatal("autostartHome returned nothing for a portable install")
	}
}

// The macOS agent must not restart a helper that exited cleanly, for the same
// reason the systemd unit must not.
func TestLaunchAgentOnlyRestartsOnFailure(t *testing.T) {
	body := launchAgentBody(testInstall("/Applications/ITGmania"))
	if !strings.Contains(body, "SuccessfulExit") {
		t.Error("KeepAlive should be conditional on how the helper exited")
	}
	if strings.Contains(body, "<key>KeepAlive</key>\n\t<true/>") {
		t.Error("an unconditional KeepAlive would fight uninstall")
	}
	if !strings.Contains(body, "-install-dir") {
		t.Error("the agent must pin the install")
	}
}
