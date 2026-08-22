// Command find-content-installer installs the SMO Find Content module into an
// ITGmania installation and enables the network allowlist it needs.
//
// It is a single self-contained binary: the module payload is embedded, so
// there is nothing to unzip and no files for the user to move by hand.
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

	"itgmania-find-content/internal/installer"
)

//go:embed all:payload
var payloadFS embed.FS

var version = "dev" // overridden at build time with -ldflags

func main() {
	var (
		targetFlag    = flag.String("install-dir", "", "ITGmania install directory (default: auto-detect)")
		yesFlag       = flag.Bool("y", false, "do not prompt; use the first detected install")
		uninstallFlag = flag.Bool("uninstall", false, "remove the module files")
		listFlag      = flag.Bool("list", false, "list detected ITGmania installations and exit")
		versionFlag   = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()

	if *versionFlag {
		fmt.Printf("find-content-installer %s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH)
		return
	}

	code := run(*targetFlag, *yesFlag, *uninstallFlag, *listFlag)
	// Double-clicked on Windows: keep the console up so the result is readable.
	if runtime.GOOS == "windows" && !*yesFlag && isDoubleClicked() {
		fmt.Print("\nPress Enter to close...")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	os.Exit(code)
}

func run(target string, assumeYes, uninstall, listOnly bool) int {
	fmt.Println()
	fmt.Println("  SMO Find Content installer for ITGmania")
	fmt.Println("  =======================================")
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
			fmt.Println(`    find-content-installer.exe -install-dir "C:\Games\ITGmania"`)
		case "darwin":
			fmt.Println("    ./find-content-installer -install-dir /Applications/ITGmania.app")
		default:
			fmt.Println("    ./find-content-installer -install-dir ~/.itgmania")
		}
		return 1
	}

	if listOnly {
		for i, inst := range installs {
			fmt.Printf("  [%d] %s\n", i+1, describe(inst))
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

	fmt.Printf("  Install:  %s\n", inst.Root)
	if inst.Version != "" {
		fmt.Printf("  Version:  ITGmania %s\n", inst.Version)
	}
	fmt.Printf("  Theme:    %s\n", inst.SimplyLoveDir())
	fmt.Printf("  Save:     %s\n", inst.SaveDir)
	fmt.Println()

	if !inst.HasSimply {
		return fail("the Simply Love theme was not found in %s\n"+
			"  This module is a Simply Love add-on; install that theme first.", inst.ThemesDir)
	}

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
		fmt.Println("  Removed:")
		for _, name := range removed {
			fmt.Printf("    %s\n", name)
		}
		fmt.Println()
		fmt.Println("  The stepmaniaonline.net entries were left in Preferences.ini.")
		fmt.Println("  Remove them by hand if you want them gone.")
		return 0
	}

	res, err := installer.Apply(inst, modules)
	if err != nil {
		return fail("%v", err)
	}

	fmt.Println("  Installed:")
	for _, name := range res.Written {
		fmt.Printf("    %s\n", name)
	}
	fmt.Printf("    -> %s\n", res.ModulesDir)
	fmt.Println()

	switch {
	case res.Prefs.Created:
		fmt.Println("  Network access: enabled (created Preferences.ini)")
	case res.Prefs.Changed:
		fmt.Println("  Network access: enabled (stepmaniaonline.net added to HttpAllowHosts)")
		if res.Prefs.BackupPath != "" {
			fmt.Printf("    backup: %s\n", filepath.Base(res.Prefs.BackupPath))
		}
	default:
		fmt.Println("  Network access: already enabled")
	}

	if !installer.AllowlistSatisfied(inst.SaveDir) {
		fmt.Println()
		fmt.Println("  WARNING: the allowlist still does not look right.")
		fmt.Printf("  Check HttpAllowHosts in %s\n", filepath.Join(inst.SaveDir, "Preferences.ini"))
		return 1
	}

	fmt.Println()
	fmt.Println("  Done. Start ITGmania - \"Find Content\" is on the title menu, below Exit.")
	return 0
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
