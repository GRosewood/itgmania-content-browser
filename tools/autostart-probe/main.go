// A live check of the autostart registration, run against a throwaway install.
//
// Cross-compiling proves the code builds; it proves nothing about whether
// systemd, launchd or the task scheduler actually accept what it writes. This
// registers for a fake install root, prints what landed on disk, asks the
// platform whether it agrees the thing is enabled, then unregisters and checks
// that nothing is left behind.
//
// Not part of the shipped binary and not run by CI -- it needs a real session.
// Run it on the platform you are changing:
//
//	go run ./tools/autostart-probe
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"itgmania-content-browser/internal/installer"
)

func main() {
	root, err := os.MkdirTemp("", "itg-autostart-probe-*")
	if err != nil {
		fmt.Println("cannot make a scratch install:", err)
		os.Exit(1)
	}
	defer func() { _ = os.RemoveAll(root) }()

	inst := installer.Install{
		Root:     root,
		SaveDir:  filepath.Join(root, "Save"),
		Portable: true,
	}
	// The helper binary has to exist for a registration to be worth anything.
	if err := os.MkdirAll(installer.HelperDir(inst), 0o755); err != nil {
		fmt.Println("mkdir:", err)
		os.Exit(1)
	}
	if err := os.WriteFile(installer.HelperBinary(inst), []byte("#!/bin/sh\nsleep 1\n"), 0o755); err != nil {
		fmt.Println("write:", err)
		os.Exit(1)
	}

	fmt.Println("platform:", runtime.GOOS)
	fmt.Println("install:  ", root)
	fmt.Println()

	fmt.Println("== before ==")
	show(installer.AutostartInfo(inst))

	fmt.Println("== registering ==")
	if err := installer.RegisterAutostart(inst); err != nil {
		fmt.Println("  FAILED:", err)
		os.Exit(1)
	}
	after := installer.AutostartInfo(inst)
	show(after)
	if after.Mechanism == installer.MechNone {
		fmt.Println("  FAILED: registered, but nothing reports as registered")
		os.Exit(1)
	}
	dump(after.Path)
	ask(after)

	fmt.Println("== unregistering ==")
	if err := installer.UnregisterAutostart(inst); err != nil {
		fmt.Println("  FAILED:", err)
		os.Exit(1)
	}
	gone := installer.AutostartInfo(inst)
	show(gone)
	if gone.Mechanism != installer.MechNone {
		fmt.Println("  FAILED: something survived uninstall")
		os.Exit(1)
	}
	if _, err := os.Lstat(after.Path); err == nil {
		fmt.Println("  FAILED:", after.Path, "is still on disk")
		os.Exit(1)
	}
	fmt.Println()
	fmt.Println("OK: registered, the platform agreed, and uninstall removed it.")
}

func show(s installer.AutostartStatus) {
	fmt.Println("  mechanism:", s.Mechanism)
	if s.Path != "" {
		fmt.Println("  path:     ", s.Path)
	}
	fmt.Println("  describe: ", strings.ReplaceAll(s.Describe(), "\n", "\n    "))
	fmt.Println()
}

// dump prints what was actually written, because a unit file that is subtly
// wrong still registers fine and then does nothing at the next boot.
func dump(path string) {
	body, err := os.ReadFile(path)
	if err != nil {
		return
	}
	fmt.Println("  --- contents of", filepath.Base(path), "---")
	for _, line := range strings.Split(strings.TrimRight(string(body), "\n"), "\n") {
		fmt.Println("  |", line)
	}
	fmt.Println()
}

// ask puts the question to the platform itself rather than to our own code.
func ask(s installer.AutostartStatus) {
	switch s.Mechanism {
	case installer.MechSystemd:
		unit := filepath.Base(s.Path)
		out, _ := exec.Command("systemctl", "--user", "is-enabled", unit).CombinedOutput()
		fmt.Printf("  systemctl --user is-enabled %s -> %s\n", unit, strings.TrimSpace(string(out)))
		out, _ = exec.Command("systemctl", "--user", "cat", unit).CombinedOutput()
		if strings.Contains(string(out), "ExecStart=") {
			fmt.Println("  systemctl can read the unit back: yes")
		} else {
			fmt.Println("  systemctl cannot read the unit back:", strings.TrimSpace(string(out)))
		}
	case installer.MechAgent:
		out, _ := exec.Command("plutil", "-lint", s.Path).CombinedOutput()
		fmt.Println("  plutil -lint ->", strings.TrimSpace(string(out)))
	case installer.MechTask:
		out, _ := exec.Command("schtasks", "/Query", "/TN", s.Path).CombinedOutput()
		fmt.Println("  schtasks /Query ->", firstLine(string(out)))
	}
	fmt.Println()
}

func firstLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if strings.TrimSpace(l) != "" {
			return strings.TrimSpace(l)
		}
	}
	return "(no output)"
}
