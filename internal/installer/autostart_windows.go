//go:build windows

package installer

import (
	"os"
	"os/exec"
	"syscall"
)

// How the helper starts on Windows, and why it is a scheduled task.
//
// It used to be a HKCU ...\CurrentVersion\Run value. That is dispatched by the
// shell, so it fires only once Explorer is running -- and a cabinet that
// replaces the shell with the game, or launches the game from anything other
// than a normal desktop logon, never runs it. The task scheduler is a service
// and dispatches its own triggers, so a logon-triggered task fires for a logon
// that has no Explorer at all.
//
// Measured on Windows 11 (standard user, not elevated):
//
//	schtasks /Create /SC ONLOGON ...          ERROR: Access is denied
//	schtasks /Create /SC ONLOGON /RU <me> ... ERROR: Access is denied
//	schtasks /Create /SC ONSTART ...          ERROR: Access is denied
//	schtasks /Create /XML <file>              SUCCESS
//
// So the shorthand is not an option -- it wants the privilege to register a
// task for an arbitrary principal. The XML form, which pins both the trigger
// and the principal to the current user's own account at least privilege, is
// allowed without elevation. Anything here that reaches for /SC ONLOGON would
// fail for every player who is not an administrator.
//
// A task cannot start the helper before somebody logs in. An ONSTART task
// could, but it needs elevation to register AND it would run in session 0,
// where APPDATA resolves into the system profile -- so a non-portable install
// would publish helper.json somewhere the game never looks. Automatic logon is
// the supported answer for a Windows cabinet, and it is what the README says.

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

// One value per installation, so a second ITGmania does not silently take the
// first one's slot. Earlier builds used a single shared name; it is removed on
// sight rather than left behind as a duplicate.
const legacyRunValue = "ITGMania Content Browser Helper"

func runValueFor(inst Install) string {
	return legacyRunValue + " (" + installKey(inst) + ")"
}

// taskName is the task's path in the scheduler's own namespace. The leading
// backslash keeps it at the root rather than under a vendor folder, which is
// where a per-user task can be registered without elevation.
func taskName(inst Install) string {
	return `\ITGMania Content Browser Helper (` + installKey(inst) + `)`
}

func isWindows() bool { return true }

func hidden(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd
}

func removeRunValue(name string) {
	// a missing value is the state we wanted anyway
	_ = hidden(exec.Command("reg", "delete", runKey, "/v", name, "/f")).Run()
}

func runValuePresent(name string) bool {
	return hidden(exec.Command("reg", "query", runKey, "/v", name)).Run() == nil
}

func taskPresent(inst Install) bool {
	return hidden(exec.Command("schtasks", "/Query", "/TN", taskName(inst))).Run() == nil
}

// currentUser is DOMAIN\user, which is what both the trigger and the principal
// want. os/user would do it too, but this avoids pulling it in for one string.
func currentUser() string {
	domain := os.Getenv("USERDOMAIN")
	name := os.Getenv("USERNAME")
	if name == "" {
		return ""
	}
	if domain == "" {
		return name
	}
	return domain + `\` + name
}

// utf16LE encodes with a BOM, which is what schtasks expects. The input is
// ASCII apart from whatever is in a path, and Go strings are UTF-8, so this
// walks runes and emits surrogate pairs for anything outside the BMP.
func utf16LE(s string) []byte {
	out := []byte{0xFF, 0xFE}
	put := func(u uint16) { out = append(out, byte(u), byte(u>>8)) }
	for _, r := range s {
		if r > 0xFFFF {
			r -= 0x10000
			put(uint16(0xD800 + (r >> 10)))
			put(uint16(0xDC00 + (r & 0x3FF)))
			continue
		}
		put(uint16(r))
	}
	return out
}

func unregisterAutostart(inst Install) error {
	_ = hidden(exec.Command("schtasks", "/Delete", "/TN", taskName(inst), "/F")).Run()
	removeRunValue(runValueFor(inst))
	removeRunValue(legacyRunValue)
	return nil
}

func autostartInfo(inst Install) AutostartStatus {
	if taskPresent(inst) {
		return AutostartStatus{
			Mechanism: MechTask,
			Path:      taskName(inst),
			Starts:    StartsOnLogin,
			Note: "The task scheduler dispatches this itself, so it does not need " +
				"Explorer and works under a kiosk or shell-replacement setup. It " +
				"does need somebody to log in; set the cabinet to log in automatically.",
		}
	}
	if runValuePresent(runValueFor(inst)) || runValuePresent(legacyRunValue) {
		return AutostartStatus{
			Mechanism: MechRunKey,
			Path:      runKey + `\` + runValueFor(inst),
			Starts:    StartsOnDesktopSession,
			// Always worth acting on: a scheduled task is available on every
			// Windows this runs on, so a Run value means either an install
			// predating the task or a registration that fell back.
			Upgradable: true,
			Note: "A Run value is dispatched by Explorer, so it will not fire if the " +
				"cabinet replaces the shell with the game. Re-run the installer to " +
				"move to a scheduled task.",
		}
	}
	return AutostartStatus{Mechanism: MechNone, Starts: StartsOnDesktopSession}
}
