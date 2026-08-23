package installer

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// installKey distinguishes one ITGmania installation from another, so two
// installs do not fight over a single login-item slot.
func installKey(inst Install) string {
	sum := sha1.Sum([]byte(strings.ToLower(filepath.Clean(inst.Root))))
	return hex.EncodeToString(sum[:4])
}

// Login registration for the loopback delete helper.
//
// The helper has to be running while ITGmania is, because the game can only
// reach it over HTTP and cannot start a process itself. Registering it as a
// per-user login item is the least invasive way to guarantee that: no service,
// no elevation, and it is removed again on uninstall.

// HelperDir is where the helper's copy of the binary and its published config
// live for a given install. Keeping it beside Save/ makes it per-install and
// keeps the theme directory clean.
func HelperDir(inst Install) string {
	return filepath.Join(inst.SaveDir, "ITGmaniaContentBrowser")
}

// HelperBinary is the path of the helper copy for this install.
func HelperBinary(inst Install) string {
	name := "content-browser-helper"
	if isWindows() {
		name += ".exe"
	}
	return filepath.Join(HelperDir(inst), name)
}

// InstallHelperBinary copies the running installer to the helper location, so
// the helper does not depend on where the installer was run from.
func InstallHelperBinary(inst Install) (string, error) {
	self, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locating this program: %w", err)
	}
	self, err = filepath.EvalSymlinks(self)
	if err != nil {
		return "", err
	}
	dest := HelperBinary(inst)
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", err
	}
	data, err := os.ReadFile(self)
	if err != nil {
		return "", err
	}
	// Windows refuses to delete or overwrite a running executable, and an old
	// helper may still be shutting down. Renaming it out of the way is allowed
	// even while it runs, so upgrades never fail on a live process.
	if isFile(dest) {
		if err := renameAside(dest); err != nil {
			return "", fmt.Errorf("replacing %s: %w", dest, err)
		}
	}
	if err := os.WriteFile(dest, data, 0o755); err != nil {
		return "", fmt.Errorf("writing %s: %w", dest, err)
	}
	return dest, nil
}

// renameAside moves a (possibly running) executable out of the way. Windows
// allows renaming a live image but not deleting or overwriting it, so an
// upgrade renames rather than replaces. A suffix is tried until one is free,
// because a previous aside may still be held by a process that is exiting.
func renameAside(path string) error {
	if err := os.Remove(path); err == nil {
		return nil
	}
	for i := 0; i < 20; i++ {
		stale := fmt.Sprintf("%s.old%d", path, i)
		if isFile(stale) {
			if os.Remove(stale) != nil {
				continue // still locked; try the next name
			}
		}
		if err := os.Rename(path, stale); err == nil {
			return nil
		}
	}
	return fmt.Errorf("could not move the running helper out of the way")
}

// helperArgs is the command line the login item runs.
func helperArgs(inst Install) []string {
	return []string{"-helper", "-install-dir", inst.Root}
}

// StartHelper launches the helper now, so the feature works without a reboot.
func StartHelper(inst Install) error {
	bin := HelperBinary(inst)
	if !isFile(bin) {
		return fmt.Errorf("helper binary not installed")
	}
	cmd := exec.Command(bin, helperArgs(inst)...)
	cmd.Dir = HelperDir(inst)
	detachProcess(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	// Nothing waits on it; releasing avoids leaving a zombie behind us.
	return cmd.Process.Release()
}

// StopHelper asks a running helper to exit and waits for it to let go of its
// executable. Removing the config is the signal; the helper notices within its
// poll interval. Waiting matters because the caller is usually about to replace
// or delete that binary, and Windows refuses either while it is running.
func StopHelper(inst Install) {
	_ = os.Remove(filepath.Join(HelperDir(inst), "helper.json"))

	bin := HelperBinary(inst)
	if isFile(bin) {
		// Renaming a running image succeeds on Windows where deleting does not,
		// so this is the cheapest "has it exited yet" probe available.
		deadline := time.Now().Add(8 * time.Second)
		for time.Now().Before(deadline) {
			probe := bin + ".probe"
			if err := os.Rename(bin, probe); err == nil {
				_ = os.Rename(probe, bin)
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
	}

	// left behind by previous upgrades, once the processes holding them are gone
	_ = os.Remove(bin + ".old")
	for i := 0; i < 20; i++ {
		_ = os.Remove(fmt.Sprintf("%s.old%d", bin, i))
	}
}

// RemoveHelperBinary deletes the helper executable, retrying while a shutting
// -down process still holds it open.
func RemoveHelperBinary(inst Install) bool {
	bin := HelperBinary(inst)
	if !isFile(bin) {
		return false
	}
	deadline := time.Now().Add(8 * time.Second)
	for {
		if err := os.Remove(bin); err == nil {
			// tidy up the directory too, if nothing else lives there
			_ = os.Remove(HelperDir(inst))
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// RegisterAutostart makes the helper start with the user's session.
func RegisterAutostart(inst Install) error { return registerAutostart(inst) }

// UnregisterAutostart removes the login item again.
func UnregisterAutostart(inst Install) error { return unregisterAutostart(inst) }

// AutostartDescription names where this install's login item lives.
func AutostartDescription(inst Install) string { return autostartDescription(inst) }
