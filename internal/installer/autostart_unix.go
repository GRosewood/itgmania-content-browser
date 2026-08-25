//go:build !windows

package installer

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

func isWindows() bool { return false }

// detachProcess puts the helper in its own session so it outlives the shell
// the installer was run from.
func detachProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

// How the helper starts on macOS and Linux.
//
// macOS gets a LaunchAgent. Linux gets a systemd USER SERVICE where systemd is
// running, and the old XDG autostart entry only where it is not.
//
// The XDG entry is what this used to be everywhere, and it is the reason a
// cabinet could end up with a browser that would not open. An autostart .desktop
// is run by the DESKTOP SESSION -- GNOME, KDE, XFCE each implement the spec
// themselves -- so a machine that boots into a getty, logs in automatically and
// runs the game from .profile or startx has nothing that reads it. A systemd
// user service, by contrast, is started by the per-user systemd instance, which
// logind starts for ANY login session, desktop or not. That is the fix.
//
// It still needs a login, because without one there is no user instance to
// start the service. `loginctl enable-linger <user>` removes that requirement
// and is the documented answer for a cabinet with no login at all -- it is not
// done here because it needs root.
//
// The unit is enabled by writing the wants symlink directly rather than by
// calling `systemctl --user enable`. That is exactly what enable does on disk,
// and doing it ourselves means the install works with no D-Bus session, no
// running user instance, and no systemctl on PATH -- all of which are normal
// when the installer is run over SSH or from a setup script.

const launchAgentBase = "net.gregtech.itgmania-content-browser.helper"

func launchAgentLabel(inst Install) string {
	return launchAgentBase + "." + installKey(inst)
}

// autostartHome is the home directory of the account the GAME runs as, which is
// not necessarily the one running the installer.
//
// os.UserHomeDir() was the old answer and it is wrong under sudo: it returns
// root's home, so the registration landed in /root and the player's session
// never saw it. candidateHomes is not the answer either -- it is a list of
// GUESSES, and for a root-owned install root under `sudo su -` its first entry
// IS /root: the install owner is skipped when that owner is root, SUDO_USER and
// PKEXEC_UID have been scrubbed by `su -`, and os.UserHomeDir() is consulted
// before the scan of /home.
//
// SaveDir is the answer, because discovery has already done this work: the
// candidates are built as saveUnderHome(home) and pickSaveDir chooses among
// them by which one actually holds a Preferences.ini. So the home whose save
// path equals inst.SaveDir is the account the game really runs as, decided on
// evidence rather than on the order of a list. A portable install falls through
// -- its SaveDir is <root>/Save, under nobody's home -- and keeps the guess.
//
// Getting this wrong is silent and total: the helper is installed under the
// player's home (HelperDir follows SaveDir) while the unit that should start it
// is written to root's, so nothing ever starts it and the browser never opens.
func autostartHome(inst Install) string {
	// Walk up the save path looking for the directory it hangs off. The test is
	// saveUnderHome(dir) == SaveDir, so this cannot drift from the way discovery
	// built that path in the first place, and it needs nothing to exist on disk
	// -- which matters, because the account may have no home on THIS machine's
	// filesystem view at all when the installer runs from a boot script.
	for dir := filepath.Dir(inst.SaveDir); ; dir = filepath.Dir(dir) {
		if dir == "" || dir == "." || dir == string(filepath.Separator) {
			break
		}
		if saveUnderHome(dir) == inst.SaveDir {
			return dir
		}
	}

	// A portable install keeps Save beside the game, under nobody's home, so
	// there is nothing to find and a guess is all there is.
	if homes := candidateHomes(inst.Root); len(homes) > 0 && homes[0] != "" {
		return homes[0]
	}
	home, _ := os.UserHomeDir()
	return home
}

func launchAgentPath(inst Install) string {
	return filepath.Join(autostartHome(inst), "Library", "LaunchAgents",
		launchAgentLabel(inst)+".plist")
}

// xdgConfigHome is the config directory of the account the GAME runs as.
//
// XDG_CONFIG_HOME describes the CURRENT session, and this function is often
// asked about somebody else: a sudo install, or a machine where the game
// belongs to a different account than the one at the keyboard. Trusting the
// variable in that case writes the registration into the installing user's
// profile, where the player's session will never look for it -- the same
// mistake autostartHome used to make, one directory further down.
//
// So the variable is honoured only when the home it would describe is the home
// we actually resolved. Everything else is derived from that home. Testing
// isRoot() alone was not enough: root is not the only way to be somebody else.
func xdgConfigHome(inst Install) string {
	home := autostartHome(inst)
	if dir := os.Getenv("XDG_CONFIG_HOME"); dir != "" && !isRoot() {
		if self, err := os.UserHomeDir(); err == nil && self == home {
			return dir
		}
	}
	return filepath.Join(home, ".config")
}

func autostartDesktopPath(inst Install) string {
	return filepath.Join(xdgConfigHome(inst), "autostart",
		"itgmania-content-browser-helper-"+installKey(inst)+".desktop")
}

func systemdUnitName(inst Install) string {
	return "itgmania-content-browser-helper-" + installKey(inst) + ".service"
}

func systemdUnitPath(inst Install) string {
	return filepath.Join(xdgConfigHome(inst), "systemd", "user", systemdUnitName(inst))
}

// systemdWantsPath is the symlink that makes the unit start by itself. Writing
// it is what `systemctl --user enable` does.
func systemdWantsPath(inst Install) string {
	return filepath.Join(xdgConfigHome(inst), "systemd", "user",
		"default.target.wants", systemdUnitName(inst))
}

// haveSystemd reports whether this machine boots with systemd. The directory is
// systemd's own documented marker (sd_booted), and it is a much better question
// than "is systemctl installed", which is true on plenty of machines running
// something else.
func haveSystemd() bool {
	if runtime.GOOS != "linux" {
		return false
	}
	st, err := os.Stat("/run/systemd/system")
	return err == nil && st.IsDir()
}

func autostartPath(inst Install) string {
	if runtime.GOOS == "darwin" {
		return launchAgentPath(inst)
	}
	if haveSystemd() {
		return systemdUnitPath(inst)
	}
	return autostartDesktopPath(inst)
}

// legacyAutostartPath is what builds before per-install naming wrote.
func legacyAutostartPath(inst Install) string {
	if runtime.GOOS == "darwin" {
		return filepath.Join(autostartHome(inst), "Library", "LaunchAgents",
			launchAgentBase+".plist")
	}
	return filepath.Join(xdgConfigHome(inst), "autostart",
		"itgmania-content-browser-helper.desktop")
}

// writeOwned writes a file and hands it back to whoever owns the tree it went
// into, so a sudo install does not leave the player unable to change it.
func writeOwned(path, body string, inst Install) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	model := autostartHome(inst)
	chownLike(path, model)
	chownLike(dir, model)
	return nil
}

func registerAutostart(inst Install) error {
	_ = os.Remove(legacyAutostartPath(inst))

	if runtime.GOOS == "darwin" {
		return registerLaunchAgent(inst)
	}
	if haveSystemd() {
		// Exactly one mechanism: a leftover .desktop from an older install
		// would otherwise start a second helper beside the service.
		_ = os.Remove(autostartDesktopPath(inst))
		return registerSystemdUser(inst)
	}
	_ = os.Remove(systemdWantsPath(inst))
	_ = os.Remove(systemdUnitPath(inst))
	return registerXDG(inst)
}

// registerSystemdUser writes the unit and the symlink that enables it.
//
// Restart=on-failure rather than always: the helper exits 0 on purpose when its
// config is removed, which is how uninstall and upgrade stop it, and `always`
// would fight both by bringing it straight back.
func registerSystemdUser(inst Install) error {
	if err := writeOwned(systemdUnitPath(inst), systemdUnitBody(inst), inst); err != nil {
		return err
	}

	// The wants symlink IS the enable. Relative, so it survives the home
	// directory being moved or mounted elsewhere.
	link := systemdWantsPath(inst)
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		return err
	}
	_ = os.Remove(link)
	if err := os.Symlink(filepath.Join("..", systemdUnitName(inst)), link); err != nil {
		return fmt.Errorf("enabling %s: %w", systemdUnitName(inst), err)
	}
	chownLike(link, autostartHome(inst))
	chownLike(filepath.Dir(link), autostartHome(inst))

	// Best effort: tell a running user instance about the new unit. Absent or
	// unreachable systemctl is not a failure -- the unit is on disk and the
	// next login picks it up, which is the case this exists for.
	_ = exec.Command("systemctl", "--user", "daemon-reload").Run()
	return nil
}

func systemdUnitBody(inst Install) string {
	quoted := make([]string, 0, len(helperArgs(inst))+1)
	for _, a := range append([]string{HelperBinary(inst)}, helperArgs(inst)...) {
		quoted = append(quoted, systemdQuote(a))
	}

	return "[Unit]\n" +
		"Description=ITGMania Content Browser helper\n" +
		"Documentation=https://github.com/GRosewood/itgmania-content-browser\n" +
		"\n" +
		"[Service]\n" +
		"Type=simple\n" +
		"ExecStart=" + strings.Join(quoted, " ") + "\n" +
		"WorkingDirectory=" + systemdQuote(HelperDir(inst)) + "\n" +
		"Restart=on-failure\n" +
		"RestartSec=5\n" +
		"\n" +
		"[Install]\n" +
		"WantedBy=default.target\n"
}

func registerXDG(inst Install) error {
	body := "[Desktop Entry]\n" +
		"Type=Application\n" +
		"Name=ITGMania Content Browser Helper\n" +
		"Comment=The local service the in-game pack browser needs\n" +
		"Exec=" + desktopExec(HelperBinary(inst), helperArgs(inst)) + "\n" +
		"X-GNOME-Autostart-enabled=true\n" +
		"NoDisplay=true\n"
	return writeOwned(autostartDesktopPath(inst), body, inst)
}

// registerLaunchAgent writes the macOS plist.
//
// KeepAlive is a dictionary rather than a bare false so launchd restarts a
// helper that DIED but leaves alone one that exited cleanly -- the deliberate
// stop is an exit 0, and a bare true would fight uninstall.
func registerLaunchAgent(inst Install) error {
	return writeOwned(launchAgentPath(inst), launchAgentBody(inst), inst)
}

func launchAgentBody(inst Install) string {
	var argXML strings.Builder
	argXML.WriteString("\t\t<string>" + xmlEscape(HelperBinary(inst)) + "</string>\n")
	for _, a := range helperArgs(inst) {
		argXML.WriteString("\t\t<string>" + xmlEscape(a) + "</string>\n")
	}
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + launchAgentLabel(inst) + `</string>
	<key>ProgramArguments</key>
	<array>
` + argXML.String() + `	</array>
	<key>WorkingDirectory</key>
	<string>` + xmlEscape(HelperDir(inst)) + `</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
</dict>
</plist>
`
}

func unregisterAutostart(inst Install) error {
	_ = os.Remove(legacyAutostartPath(inst))
	// Clear every mechanism, not just the one this machine would register now:
	// an install made before systemd support, or on a machine since changed,
	// must not leave something behind that keeps starting the helper.
	_ = os.Remove(autostartDesktopPath(inst))
	_ = os.Remove(systemdWantsPath(inst))

	unit := systemdUnitPath(inst)
	hadUnit := isFile(unit)
	_ = os.Remove(unit)
	if hadUnit {
		_ = exec.Command("systemctl", "--user", "daemon-reload").Run()
	}

	if runtime.GOOS == "darwin" {
		if err := os.Remove(launchAgentPath(inst)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func autostartInfo(inst Install) AutostartStatus {
	if runtime.GOOS == "darwin" {
		if isFile(launchAgentPath(inst)) {
			return AutostartStatus{
				Mechanism: MechAgent,
				Path:      launchAgentPath(inst),
				Starts:    StartsOnLogin,
				Note: "A launch agent loads when this account logs in; automatic " +
					"login counts. A Mac with nobody logged in will not start it.",
			}
		}
		return AutostartStatus{Mechanism: MechNone, Starts: StartsOnLogin}
	}

	if isFile(systemdUnitPath(inst)) && isSymlink(systemdWantsPath(inst)) {
		starts, note := StartsOnLogin, "A systemd user service starts for any login "+
			"session, desktop or not -- so a cabinet that logs in automatically and "+
			"runs the game from a script is fine. For a cabinet with no login at all, "+
			"run: sudo loginctl enable-linger "+baseName(autostartHome(inst))
		// Do not hand somebody a command that cannot work. On a read-only
		// image /var/lib/systemd cannot be written, so enable-linger fails with
		// "read-only file system" and no hint about what to do instead.
		if readOnlyFS(lingerDir) {
			note = "A systemd user service starts for any login session, desktop " +
				"or not -- but NOT for a machine that boots straight into the game " +
				"without logging anybody in. Lingering would fix that, and cannot " +
				"be enabled here: " + lingerDir + " is on a read-only filesystem. " +
				"Start the helper from whatever launches ITGmania instead, by " +
				"adding this line before the game: " + HelperCommand(inst)
		}
		if lingering(autostartHome(inst)) {
			starts = StartsAtBoot
			note = "Lingering is enabled for this account, so the service starts at " +
				"boot whether anybody logs in or not."
		}
		return AutostartStatus{
			Mechanism: MechSystemd,
			Path:      systemdUnitPath(inst),
			Starts:    starts,
			Note:      note,
		}
	}
	if isFile(autostartDesktopPath(inst)) {
		note := "An XDG autostart entry is run by the desktop session, so a cabinet " +
			"that boots straight into the game never runs it."
		if haveSystemd() {
			note += " This machine runs systemd, which can do better: re-run the " +
				"installer to move to a user service."
		} else {
			note += " This machine does not run systemd, so this is the best " +
				"available here; start the helper from the game's launch script " +
				"if the cabinet has no desktop."
		}
		return AutostartStatus{
			Mechanism:  MechXDG,
			Path:       autostartDesktopPath(inst),
			Starts:     StartsOnDesktopSession,
			Upgradable: haveSystemd(),
			Note:       note,
		}
	}
	return AutostartStatus{Mechanism: MechNone, Starts: StartsOnDesktopSession}
}

// lingerDir is where logind records which accounts linger.
const lingerDir = "/var/lib/systemd/linger"

// lingering reports whether logind will start this user's systemd instance at
// boot. The marker file is logind's own record of it.
func lingering(home string) bool {
	user := baseName(home)
	if user == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(lingerDir, user))
	return err == nil
}

func baseName(path string) string {
	if path == "" {
		return ""
	}
	return filepath.Base(path)
}

func isSymlink(path string) bool {
	st, err := os.Lstat(path)
	return err == nil && st.Mode()&os.ModeSymlink != 0
}

func autostartDescription(inst Install) string { return autostartPath(inst) }

// systemdQuote quotes a value for a unit file's ExecStart.
//
// Not shell quoting: systemd splits on whitespace and understands double quotes
// with backslash escapes inside them, so an argument with a space is wrapped and
// backslashes and quotes within it are escaped.
func systemdQuote(s string) string {
	if s != "" && !strings.ContainsAny(s, " \t\n\"'\\") {
		return s
	}
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}

// desktopExec builds an Exec= value per the XDG Desktop Entry spec, which is
// not shell quoting: an argument with spaces is wrapped in double quotes, and
// inside those quotes backslash, double quote, backtick and dollar are escaped
// with a backslash. Percent signs are doubled everywhere, quoted or not.
func desktopExec(bin string, args []string) string {
	parts := make([]string, 0, len(args)+1)
	for _, a := range append([]string{bin}, args...) {
		parts = append(parts, desktopQuote(a))
	}
	return strings.Join(parts, " ")
}

func desktopQuote(s string) string {
	s = strings.ReplaceAll(s, "%", "%%")
	if !strings.ContainsAny(s, " \t\n\"'\\><~|&;$*?#()`") {
		return s
	}
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "`", "\\`", `$`, `\$`)
	return `"` + r.Replace(s) + `"`
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}
