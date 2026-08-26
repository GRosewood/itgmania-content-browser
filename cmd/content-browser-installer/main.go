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
		themeFlag     = flag.String("theme", "", "theme folder to install into: a name, or a full path when the same name exists in more than one place (default: the one in use)")
		listThemeFlag = flag.Bool("list-themes", false, "list this install's themes and whether the module can run under them")
		versionFlag   = flag.Bool("version", false, "print version and exit")
		noBannerFlag  = flag.Bool("no-banner", false, "do not draw the artwork banner")
		detectFlag    = flag.Bool("detect", false, "print the best-guess install directory and exit (for GUI front-ends)")
		userFlag      = flag.String("user", "", "the account ITGmania runs as (default: work it out)")
		verboseFlag   = flag.Bool("verbose", false, "list every file installed or removed")
		checkFlag     = flag.Bool("check", false, "report whether the browser will actually work on this machine, and exit")
	)
	flag.Parse()

	// Pinning the account has to happen before anything inspects an install,
	// because the save profile and any old-helper leftovers to sweep
	// registration all hang off it.
	installer.ForceUser(*userFlag)

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

	// -check changes nothing. It exists because the two ways this goes wrong on
	// a cabinet -- the allowlist and whether the preview relay is reachable --
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
				// The directory, always. A theme can live in the install, in
				// the player's profile, or on a drive mounted through the
				// game's own options, and the name alone cannot tell those
				// apart -- which is the whole reason a module ends up in a
				// copy nobody is running.
				fmt.Printf("      %s\n", t.Path)
				for _, other := range t.AlsoIn {
					fmt.Printf("      also: %s (not loaded)\n", other)
				}
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
	current := installer.CurrentTheme(inst.SaveDir)
	theme, ask, err := installer.PickTheme(themes, wantTheme, current)
	if err != nil {
		fmt.Printf("  Install:  %s\n\n", inst.Root)
		listThemeTable(themes)
		return fail("%v\n"+
			"  This module is a Simply Love add-on. Any Simply Love fork works,\n"+
			"  so long as it loads Modules/ and has a title menu to add to.", err)
	}
	if current != "" && !installer.ThemeListed(themes, current) {
		// The game is drawing a theme that is not in any directory searched.
		// Said whether or not there is a prompt coming, because -y skips the
		// prompt and this is the one thing that makes the result wrong.
		fmt.Printf("  This install is set to use %q, which is not in any theme\n", current)
		fmt.Println("  folder found here. It is probably on a drive mounted through the")
		fmt.Println("  game's own options; add that folder to AdditionalFoldersWritable")
		fmt.Println("  (or pass -theme <full path to the theme folder>) so this can see it.")
		fmt.Println("  Installing into anything else will not be visible in the game.")
		fmt.Println()
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
	// The full path, not just the name. One name can exist in several of the
	// places the engine mounts, and when the module goes into the wrong copy
	// nothing else on this screen looks any different.
	fmt.Printf("  Theme:    %s\n", theme.Path)
	for _, other := range theme.AlsoIn {
		fmt.Printf("            (a theme called %q is also in %s; the game loads\n", theme.Name, other)
		fmt.Printf("             the one above. If it is drawing that one instead, re-run with\n")
		fmt.Printf("             -theme followed by that full path)\n")
	}
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
	// Whose install this is, and why we think so. On a cabinet the installer
	// is usually run with sudo by somebody who is not the player, and every
	// path above belongs to the player -- so if this line names the wrong
	// account, nothing else on screen can be trusted.
	if inst.GameUser.Name != "" {
		fmt.Printf("  For user: %s (%s)\n", inst.GameUser.Name, inst.GameUser.How)
	}
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
	// into, what was cleaned up -- under screens of scrollback.
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
		fmt.Printf("  Network access: enabled (%d hosts added to HttpAllowHosts)\n", len(installer.Hosts))
		if res.Prefs.BackupPath != "" {
			fmt.Printf("    backup: %s\n", filepath.Base(res.Prefs.BackupPath))
		}
	default:
		fmt.Println("  Network access: already enabled")
	}

	// There is no background helper any more: the game fetches, unzips and
	// truncates for itself, and song previews come from the web relay. All an
	// upgrade over an old install has to say is that the old machinery went.
	if len(res.Helper.Removed) > 0 {
		fmt.Println("  Old helper:     removed (" + strings.Join(res.Helper.Removed, ", ") + ")")
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
		fmt.Printf("  Allowlist:      ok (%d hosts allowed, HttpEnabled=1)\n", len(installer.Hosts))
	} else {
		problems++
		fmt.Println("  Allowlist:      NOT SET")
		fmt.Printf("    %s\n", why)
	}

	// The machinery an older version ran in the background. Its presence is
	// not a fault -- the next install run sweeps it -- but it is worth a
	// line, because a scheduled task pointing at a deleted binary is the
	// kind of thing that otherwise gets discovered by accident years on.
	leftovers := installer.AutostartInfo(inst)
	if leftovers.Mechanism != installer.MechNone {
		problems++
		fmt.Printf("  Old helper:     its %s is still registered\n", leftovers.Mechanism)
		fmt.Println("    Run this installer once to take it away.")
	} else if installer.HelperBinaryPresent(inst) {
		problems++
		fmt.Println("  Old helper:     its binary is still on disk")
		fmt.Println("    Run this installer once to take it away.")
	} else {
		fmt.Println("  Old helper:     none -- the game does everything itself")
	}

	// The preview relay: not required for browsing, downloading or deleting,
	// but song previews and single-song installs come through it.
	relay := installer.RelayBase(inst)
	if installer.RelayReachable(relay) {
		fmt.Printf("  Preview relay:  answering at %s\n", relay)
	} else {
		fmt.Printf("  Preview relay:  NOT reachable at %s\n", relay)
		fmt.Println("    Browsing, downloads and deletion work without it; song")
		fmt.Println("    previews and single-song installs do not. Start it, or put")
		fmt.Println("    its URL in Save/ITGmaniaContentBrowser/webapp.txt.")
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
		fmt.Printf("      %s\n", t.Path)
		for _, other := range t.AlsoIn {
			fmt.Printf("      also: %s (not loaded)\n", other)
		}
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
