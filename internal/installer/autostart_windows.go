//go:build windows

package installer

import (
	"fmt"
	"os/exec"
	"strings"
	"syscall"
)

// On Windows the login item is a HKCU Run value. That needs no elevation and
// is trivially reversible, unlike a service. reg.exe is used rather than a
// registry package so the build stays dependency-free and CGO-free.

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

// One value per installation, so a second ITGmania does not silently take the
// first one's slot. Earlier builds used a single shared name; it is removed on
// sight rather than left behind as a duplicate.
const legacyRunValue = "ITGMania Content Browser Helper"

func runValueFor(inst Install) string {
	return legacyRunValue + " (" + installKey(inst) + ")"
}

func isWindows() bool { return true }

// detachProcess keeps the helper alive after the installer exits and stops it
// from inheriting a console window.
func detachProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x00000008 | 0x00000200, // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
	}
}

func removeRunValue(name string) {
	cmd := exec.Command("reg", "delete", runKey, "/v", name, "/f")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	// a missing value is the state we wanted anyway
	_ = cmd.Run()
}

func registerAutostart(inst Install) error {
	quoted := `"` + HelperBinary(inst) + `" ` + strings.Join(quoteAll(helperArgs(inst)), " ")

	removeRunValue(legacyRunValue)
	cmd := exec.Command("reg", "add", runKey, "/v", runValueFor(inst), "/t", "REG_SZ",
		"/d", quoted, "/f")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("registering login item: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func unregisterAutostart(inst Install) error {
	removeRunValue(runValueFor(inst))
	removeRunValue(legacyRunValue)
	return nil
}

func autostartDescription(inst Install) string {
	return runKey + `\` + runValueFor(inst)
}

func quoteAll(args []string) []string {
	out := make([]string, len(args))
	for i, a := range args {
		if strings.ContainsAny(a, " \t") {
			out[i] = `"` + a + `"`
		} else {
			out[i] = a
		}
	}
	return out
}
