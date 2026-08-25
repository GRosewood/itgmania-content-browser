// Command itgmania-content-browser-installer installs the ITGMania Content
// Browser module into an ITGmania installation and enables the network
// allowlist it needs.
//
// It is a single self-contained binary: the module payload is embedded, so
// there is nothing to unzip and no files for the user to move by hand.
//
// Copyright (C) 2026 Rosewood <rosewoodsteps@gmail.com>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License, version 3, as published
// by the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <https://www.gnu.org/licenses/>.
package main

import (
	"bufio"
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"itgmania-content-browser/internal/assets"
	"itgmania-content-browser/internal/banner"
	"itgmania-content-browser/internal/branding"
	"itgmania-content-browser/internal/installer"
)

//go:embed all:payload
var payloadFS embed.FS

// version is what this build calls itself. branding.Version is the source of
// truth -- build.sh reads the same constant -- and -ldflags can still override
// it for a one-off build.
var version = branding.Version

func main() {
	var (
		targetFlag    = flag.String("install-dir", "", "ITGmania install directory (default: auto-detect)")
		yesFlag       = flag.Bool("y", false, "do not prompt; use the first detected install")
		uninstallFlag = flag.Bool("uninstall", false, "remove the module files")
		listFlag      = flag.Bool("list", false, "list detected ITGmania installations and exit")
		themeFlag     = flag.String("theme", "", "theme folder to install into (default: the one in use)")
		listThemeFlag = flag.Bool("list-themes", false, "list this install's themes and whether the module can run under them")
		versionFlag   = flag.Bool("version", false, "print version and exit")
		noBannerFlag  = flag.Bool("no-banner", false, "do not draw the artwork banner")
		detectFlag    = flag.Bool("detect", false, "print the best-guess install directory and exit (for GUI front-ends)")
		helperFlag    = flag.Bool("helper", false, "run the local service the in-game browser needs")
		manifestFlag  = flag.String("manifest", "", "where the helper looks for update news (default: the published one)")
		verboseFlag   = flag.Bool("verbose", false, "list every file installed or removed")
		checkFlag     = flag.Bool("check", false, "report whether the browser will actually work on this machine, and exit")
	)
	flag.Parse()

	if *versionFlag {
		fmt.Printf("%s-installer %s (%s/%s)\n", branding.Slug, version, runtime.GOOS, runtime.GOARCH)
		fmt.Printf("%s by %s\n", branding.Name, branding.Author)
		fmt.Println("License GPLv3: GNU GPL version 3 <https://gnu.org/licenses/gpl-3.0.html>")
		fmt.Println("This is free software: you are free to change and redistribute it.")
		fmt.Println("There is NO WARRANTY, to the extent permitted by law.")
		return
	}

	// -detect is consumed by the graphical installers, so it prints nothing
	// but the path (or nothing at all) and never draws chrome.
	if *detectFlag {
		installs := installer.Discover()
		if len(installs) == 0 {
			os.Exit(1)
		}
		fmt.Println(installs[0].Root)
		os.Exit(0)
	}

	// -helper is a long-running service, not an install run; it never draws
	// chrome and never prompts.
	if *helperFlag {
		os.Exit(runHelper(*targetFlag, *manifestFlag))
	}

	// -check changes nothing. It exists because the two ways this goes wrong on
	// a cabinet -- the allowlist and whether anything will start the helper --
	// are both invisible from inside the game, which can only report that it
	// cannot reach the network.
	if *checkFlag {
		os.Exit(runCheck(*targetFlag))
	}

	code := run(*targetFlag, *yesFlag, *uninstallFlag, *listFlag, *noBannerFlag,
		*themeFlag, *listThemeFlag, *verboseFlag)
	// Double-clicked on Windows: keep the console up so the result is readable.
	if runtime.GOOS == "windows" && !*yesFlag && isDoubleClicked() {
		fmt.Print("\nPress Enter to close...")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	os.Exit(code)
}

func run(target string, assumeYes, uninstall, listOnly, noBanner bool,
	wantTheme string, listThemes, verbose bool) int {
	fmt.Println()
	if !noBanner && !listOnly {
		if banner.Render(os.Stdout, assets.FS, assets.BannerPath, banner.TerminalWidth()-2) {
			fmt.Println()
		}
	}
	title := branding.Name + " installer"
	fmt.Println("  " + title)
	fmt.Println("  " + strings.Repeat("=", len(title)))
	fmt.Println("  " + branding.Tagline)
	fmt.Println("  by " + branding.Author)
	fmt.Println()

	modules, err := fs.Sub(payloadFS, "payload/Modules")
	if err != nil {
		return fail("could not read embedded payload: %v", err)
	}

	// Find candidate installations.
	var installs []installer.Install
	if target != "" {
		inst, ok := installer.Inspect(target)
		if !ok {
			return fail("%s does not look like an ITGmania installation\n"+
				"  (expected a Themes/ directory alongside Data/ or Program/)", target)
		}
		installs = []installer.Install{inst}
	} else {
		installs = installer.Discover()
	}

	if len(installs) == 0 {
		fmt.Println("  No ITGmania installation found in the usual places.")
		fmt.Println()
		fmt.Println("  Re-run with the path to your install, for example:")
		switch runtime.GOOS {
		case "windows":
			fmt.Println(`    itgmania-content-browser-installer.exe -install-dir "C:\Games\ITGmania"`)
		case "darwin":
			fmt.Println("    ./itgmania-content-browser-installer -install-dir /Applications/ITGmania.app")
		default:
			fmt.Println("    ./itgmania-content-browser-installer -install-dir ~/.itgmania")
		}
		return 1
	}

	if listOnly {
		for i, inst := range installs {
			fmt.Printf("  [%d] %s\n", i+1, describe(inst))
		}
		return 0
	}

	if listThemes {
		// Also where the settings came from, and which theme they name. When an
		// install goes into the wrong theme it is nearly always because neither
		// of those could be read, and this is the one command that says so
		// without changing anything.
		for _, in := range installs {
			fmt.Printf("  %s\n", in.Root)
			fmt.Printf("    save data:    %s\n", in.SaveDir)
			if installer.RunningAsAnother(in.SaveDir) {
				fmt.Println("    owner:        that profile belongs to another user")
				fmt.Println("                  (running as root; files are handed back)")
			}
			if !in.PrefsFound {
				fmt.Println("    settings:     no Preferences.ini here")
			} else if cur := installer.CurrentTheme(in.SaveDir); cur != "" {
				fmt.Printf("    theme in use: %s\n", cur)
			} else {
				fmt.Println("    theme in use: not named in Preferences.ini")
			}
			if installer.GameRunning() {
				fmt.Println("    note:         ITGmania looks like it is running")
			}
			fmt.Println()
			for _, t := range installer.Themes(in) {
				fmt.Printf("    %-40s %s\n", t.Name, describeTheme(t))
			}
			fmt.Println()
		}
		return 0
	}

	inst := installs[0]
	if len(installs) > 1 && !assumeYes {
		fmt.Println("  More than one ITGmania installation was found:")
		fmt.Println()
		for i, in := range installs {
			fmt.Printf("    [%d] %s\n", i+1, describe(in))
		}
		fmt.Println()
		inst = installs[choose(len(installs))]
	}

	themes := installer.Themes(inst)
	theme, ask, err := installer.PickTheme(themes, wantTheme)
	if err != nil {
		fmt.Printf("  Install:  %s\n\n", inst.Root)
		listThemeTable(themes)
		return fail("%v\n"+
			"  This module is a Simply Love add-on. Any Simply Love fork works,\n"+
			"  so long as it loads Modules/ and has a title menu to add to.", err)
	}
	if ask && !assumeYes {
		// More than one theme here could take it and none of them is the one in
		// use, so there is no answer that is not a preference.
		fmt.Println("  More than one theme here can run the module:")
		fmt.Println()
		var usable []installer.Theme
		for _, t := range themes {
			if t.Compatible() {
				usable = append(usable, t)
			}
		}
		for i, t := range usable {
			fmt.Printf("    [%d] %-36s %s\n", i+1, t.Name, describeTheme(t))
		}
		fmt.Println()
		theme = usable[choose(len(usable))]
	}
	inst.ThemeDir = theme.Path

	fmt.Printf("  Install:  %s\n", inst.Root)
	if inst.Version != "" {
		fmt.Printf("  Version:  ITGmania %s\n", inst.Version)
	}
	fmt.Printf("  Theme:    %s\n", theme.Name)
	if !theme.Current {
		// Installing into a theme that is not switched on is legitimate -- people
		// set one up before moving to it -- but silently doing nothing visible is
		// not, so say it.
		if cur := installer.CurrentTheme(inst.SaveDir); cur != "" {
			fmt.Printf("            (this install currently uses %q; switch to %q to see it)\n",
				cur, theme.Name)
		} else {
			fmt.Println("            (which theme this install uses could not be read)")
		}
	}
	fmt.Printf("  Save:     %s\n", inst.SaveDir)
	if !inst.PrefsFound {
		// Network access is a preference, so it lives in this file. Saying the
		// file was not there is the difference between "it did not work" and
		// "run the game once, then try again".
		fmt.Println("            (no Preferences.ini here yet -- if the browser says")
		fmt.Println("             network access is off, run ITGmania once and")
		fmt.Println("             then this installer again)")
	}
	fmt.Println()

	// ITGmania rewrites Preferences.ini from memory on exit, so a running
	// game would discard the allowlist change.
	if installer.GameRunning() {
		return fail("ITGmania is running. Close it completely, then run this again.")
	}

	if uninstall {
		removed, err := installer.Uninstall(inst, modules)
		if err != nil {
			return fail("%v", err)
		}
		if len(removed) == 0 {
			fmt.Println("  Nothing to remove - the module was not installed here.")
			return 0
		}
		// Edits outside the module's own directory are always named, however
		// quiet the rest of the output is: putting a line into somebody's boot
		// script is not a detail, and neither is taking it out again.
		for _, name := range removed {
			if strings.HasPrefix(name, "helper start removed from") {
				fmt.Printf("  %s\n", name)
			}
		}
		fmt.Printf("  Removed:        %d item(s)\n", len(removed))
		if verbose {
			for _, name := range removed {
				fmt.Printf("       %s\n", name)
			}
		}
		fmt.Println()
		fmt.Println("  Whatever HttpAllowHosts entries the install added were left in")
		fmt.Println("  Preferences.ini (127.0.0.1 on recent installs; older ones also")
		fmt.Println("  named the catalogue hosts). Remove them by hand if you want.")
		return 0
	}

	res, err := installer.Apply(inst, modules)
	if err != nil {
		return fail("%v", err)
	}

	if len(res.Replaced) > 0 {
		fmt.Printf("  Replaced:       %d file(s) from an older version\n", len(res.Replaced))
		if verbose {
			for _, name := range res.Replaced {
				fmt.Printf("       %s\n", name)
			}
		}
		fmt.Println()
	}

	// A count, not a roll call. The payload is 69 files, and listing every
	// one buried the things actually worth reading -- which theme it went
	// into, whether the helper came up -- under screens of scrollback.
	// -verbose brings the names back when something needs chasing.
	fmt.Printf("  Installed:      %d files\n", len(res.Written))
	fmt.Printf("    -> %s\n", res.ModulesDir)
	if verbose {
		for _, name := range res.Written {
			fmt.Printf("       %s\n", name)
		}
	}
	fmt.Println()

	switch {
	case res.Prefs.Created:
		fmt.Println("  Network access: enabled (created Preferences.ini)")
	case res.Prefs.Changed:
		fmt.Println("  Network access: enabled (127.0.0.1 added to HttpAllowHosts -- the helper relays the rest)")
		if res.Prefs.BackupPath != "" {
			fmt.Printf("    backup: %s\n", filepath.Base(res.Prefs.BackupPath))
		}
	default:
		fmt.Println("  Network access: already enabled")
	}

	// The helper is not a nicety any more. With 127.0.0.1 as the only entry on
	// the allowlist it is the browser's only road to the internet, so "the
	// browser still works, only deletion is off" stopped being true when the
	// relay landed. Say what is actually at stake, and say plainly when the
	// thing meant to start it will not.
	switch {
	case res.Helper.Err != nil:
		fmt.Printf("  Local helper:   FAILED (%v)\n", res.Helper.Err)
		fmt.Println("    The browser reaches the internet through it, so it will not open.")
	case res.Helper.Running:
		fmt.Println("  Local helper:   running")
	default:
		fmt.Println("  Local helper:   installed, but not running yet")
	}
	printAutostart(installer.AutostartInfo(inst))

	// A cabinet that boots into the game never logs in, so the registration
	// above never fires there. Say when the game's own launcher was used
	// instead -- it is the thing that makes it work on those machines, and it
	// is somebody's boot path, so it should not happen silently.
	switch {
	case res.Helper.LauncherErr != nil:
		fmt.Printf("    could not add it to the game launcher: %v\n", res.Helper.LauncherErr)
	case res.Helper.LauncherChanged:
		fmt.Printf("    also started from %s\n", res.Helper.Launcher)
		fmt.Println("      (this machine launches the game from there; a backup of the")
		fmt.Println("       original is beside it)")
	case res.Helper.Launcher != "":
		fmt.Printf("    also started from %s\n", res.Helper.Launcher)
	}

	// Say which of the three things is wrong. The old message covered a
	// missing Preferences.ini and a missing host entry with the same words,
	// and only one of them is fixed by re-running the installer.
	if ok, why := installer.AllowlistState(inst.SaveDir); !ok {
		fmt.Println()
		fmt.Println("  WARNING: network access is not set up.")
		fmt.Printf("  %s\n", why)
		return 1
	}

	fmt.Println()
	fmt.Printf("  Done. Start ITGmania - %q is on the title menu, above Exit.\n", branding.MenuLabel)
	return 0
}

// printAutostart says what will start the helper next time, and -- the part
// that matters on a cabinet -- what that mechanism needs before it fires.
func printAutostart(s installer.AutostartStatus) {
	if s.Mechanism == installer.MechNone {
		fmt.Println("    WARNING: nothing is registered to start it again, so it will")
		fmt.Println("    stop working when this machine restarts.")
		return
	}
	fmt.Printf("    starts via a %s\n", s.Mechanism)
	fmt.Printf("      %s\n", s.Path)
	switch s.Starts {
	case installer.StartsAtBoot:
		fmt.Println("      at boot -- no login needed")
	case installer.StartsOnLogin:
		fmt.Println("      when this account logs in (automatic logon counts)")
	default:
		fmt.Println("      only once a DESKTOP session starts, so a cabinet that boots")
		fmt.Println("      straight into the game will not start it")
	}
	for _, line := range wrap(s.Note, 66) {
		fmt.Println("      " + line)
	}
}

// wrap breaks a sentence at word boundaries so a note reads as prose in the
// terminal rather than running off the edge of a narrow console.
func wrap(s string, width int) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	var out []string
	line := ""
	for _, word := range strings.Fields(s) {
		if line == "" {
			line = word
			continue
		}
		if len(line)+1+len(word) > width {
			out = append(out, line)
			line = word
			continue
		}
		line += " " + word
	}
	if line != "" {
		out = append(out, line)
	}
	return out
}

// runCheck reports whether this machine can actually run the browser, without
// changing anything.
func runCheck(target string) int {
	inst, ok := pickForCheck(target)
	if !ok {
		fmt.Println("  No ITGmania installation found.")
		fmt.Println("  Point at one with -install-dir <path>.")
		return 1
	}

	fmt.Println()
	fmt.Println("  " + branding.Name + " -- checking " + inst.Root)
	fmt.Println()

	problems := 0

	// Where the settings actually are, and which theme they name. An install
	// that went into the wrong theme, or an allowlist warning that is really a
	// missing Preferences.ini, both show up here and nowhere else.
	fmt.Printf("  Save data:      %s\n", inst.SaveDir)
	if cur := installer.CurrentTheme(inst.SaveDir); cur != "" {
		fmt.Printf("  Theme in use:   %s\n", cur)
	} else {
		fmt.Println("  Theme in use:   NOT NAMED in Preferences.ini")
		fmt.Println("    Without it the installer cannot tell which theme you play,")
		fmt.Println("    and falls back to the first compatible one by name.")
		problems++
	}
	fmt.Printf("  Module in:      %s\n", inst.ModuleThemeDir())
	fmt.Println()

	// Three separate failures, three separate answers. Collapsing them into
	// one "the allowlist does not look right" sent people to re-run the
	// installer when the real problem was that no Preferences.ini existed.
	if ok, why := installer.AllowlistState(inst.SaveDir); ok {
		fmt.Println("  Allowlist:      ok (127.0.0.1 allowed, HttpEnabled=1)")
	} else {
		problems++
		fmt.Println("  Allowlist:      NOT SET")
		fmt.Printf("    %s\n", why)
	}

	// Installed, running, and reachable are three different things, and only
	// the last is what the game cares about.
	switch {
	case !installer.HelperInstalled(inst):
		problems++
		fmt.Println("  Local helper:   NOT INSTALLED")
		fmt.Printf("    expected at %s\n", installer.HelperBinary(inst))
		fmt.Println("    Re-run this installer.")
	case installer.HelperRunning(inst):
		fmt.Println("  Local helper:   running and answering on loopback")
	default:
		problems++
		fmt.Println("  Local helper:   installed, but NOT ANSWERING")
		fmt.Printf("    binary:  %s\n", installer.HelperBinary(inst))
		if cfg, err := os.Stat(installer.HelperConfigPath(inst)); err == nil {
			fmt.Printf("    config:  %s (written %s)\n",
				installer.HelperConfigPath(inst), cfg.ModTime().Format("2006-01-02 15:04:05"))
			fmt.Println("    It published a config and then stopped or was killed.")
			fmt.Println("    Run it in the foreground to see why:")
		} else {
			fmt.Printf("    config:  none at %s\n", installer.HelperConfigPath(inst))
			fmt.Println("    It has never started successfully. Run it by hand to see why:")
		}
		fmt.Printf("      %s -helper -install-dir %s\n",
			installer.HelperBinary(inst), inst.Root)
	}

	// Nothing registered is always wrong. Needing a desktop session is only
	// wrong when this machine could do better -- on a plain desktop with no
	// systemd it is the right answer, and failing there would be crying wolf.
	status := installer.AutostartInfo(inst)
	printAutostart(status)
	if status.Mechanism == installer.MechNone || status.Upgradable {
		problems++
	}

	fmt.Println()
	if problems == 0 {
		fmt.Println("  Everything the browser needs is in place.")
		return 0
	}
	fmt.Printf("  %d thing(s) above need attention.\n", problems)
	return 1
}

// pickForCheck resolves an install without prompting: -check is meant to be
// runnable from a cabinet's startup script.
func pickForCheck(target string) (installer.Install, bool) {
	if target != "" {
		return installer.Inspect(target)
	}
	installs := installer.Discover()
	if len(installs) == 0 {
		return installer.Install{}, false
	}
	return installs[0], true
}

func describe(inst installer.Install) string {
	var bits []string
	bits = append(bits, inst.Root)
	if inst.Version != "" {
		bits = append(bits, "ITGmania "+inst.Version)
	}
	if inst.HasSimply {
		bits = append(bits, "Simply Love")
	} else {
		bits = append(bits, "no Simply Love")
	}
	if inst.Portable {
		bits = append(bits, "portable")
	}
	return strings.Join(bits, "  |  ")
}

// describeTheme is the one-line verdict beside a theme in a listing.
func describeTheme(t installer.Theme) string {
	var bits []string
	if t.Current {
		bits = append(bits, "in use")
	}
	if t.Installed {
		bits = append(bits, "module installed")
	}
	if !t.Compatible() {
		bits = append(bits, t.Why())
	} else if len(bits) == 0 {
		bits = append(bits, "compatible")
	}
	return strings.Join(bits, ", ")
}

func listThemeTable(themes []installer.Theme) {
	if len(themes) == 0 {
		return
	}
	fmt.Println("  Themes found:")
	for _, t := range themes {
		fmt.Printf("    %-40s %s\n", t.Name, describeTheme(t))
	}
	fmt.Println()
}

// choose asks which install to use and returns a 0-based index.
func choose(n int) int {
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Printf("  Which one? [1-%d]: ", n)
		line, err := reader.ReadString('\n')
		if err != nil {
			return 0
		}
		i, err := strconv.Atoi(strings.TrimSpace(line))
		if err == nil && i >= 1 && i <= n {
			return i - 1
		}
	}
}

func fail(format string, args ...any) int {
	fmt.Printf("  ERROR: "+format+"\n", args...)
	fmt.Println()
	return 1
}
