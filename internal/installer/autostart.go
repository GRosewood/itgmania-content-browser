package installer

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
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

// Getting the helper started, and being honest about when it will not.
//
// The helper has to be running while ITGmania is, because the game can only
// reach it over HTTP and cannot start a process itself. Since the allowlist
// shrank to 127.0.0.1 this stopped being a convenience: the helper is the
// browser's only road to the internet, so a machine where it never starts has
// a browser that does not open at all.
//
// Every mechanism here is per-user and needs no elevation. They differ in what
// they need from the machine before they fire, and that difference is the whole
// story on a cabinet -- so it is a value the installer can print rather than
// something a reader has to infer.

// StartsWhen says what a mechanism needs before it will run the helper. The
// order is deliberate: later is better, and a cabinet operator only has to ask
// whether their machine gets that far.
type StartsWhen int

const (
	// StartsOnDesktopSession needs a full desktop -- a session manager that
	// implements the XDG autostart spec, or Explorer as the Windows shell. A
	// cabinet that boots into the game and nothing else never gets here.
	StartsOnDesktopSession StartsWhen = iota
	// StartsOnLogin needs somebody to log in, but nothing beyond that. An
	// automatic logon counts, which is how most cabinets are set up.
	StartsOnLogin
	// StartsAtBoot needs no login at all.
	StartsAtBoot
)

// Mechanism is how this install's helper is registered to start.
type Mechanism string

const (
	MechNone    Mechanism = "none"
	MechRunKey  Mechanism = "registry Run value"
	MechTask    Mechanism = "scheduled task"
	MechSystemd Mechanism = "systemd user service"
	MechXDG     Mechanism = "XDG autostart entry"
	MechAgent   Mechanism = "launch agent"
)

// AutostartStatus is what got registered and what it needs to fire.
type AutostartStatus struct {
	Mechanism Mechanism
	Path      string
	Starts    StartsWhen
	// Upgradable means this machine supports a mechanism that needs less of it
	// than the one currently registered -- an install made before that
	// mechanism existed, or one whose registration fell back. It is the
	// difference between "this is as good as it gets here", which is fine, and
	// "re-run the installer", which is worth saying out loud.
	//
	// Needing a desktop session is NOT on its own a fault: on a desktop machine
	// with no systemd an XDG entry is the right answer, and reporting that as a
	// problem would be crying wolf at the very users this tool is asking to
	// trust its reporting.
	Upgradable bool
	// Note is the one sentence worth telling an operator about this mechanism.
	Note string
}

// Describe renders a status the way the installer prints it.
func (s AutostartStatus) Describe() string {
	if s.Mechanism == MechNone {
		return "nothing is registered to start the helper"
	}
	when := "only once a desktop session starts"
	switch s.Starts {
	case StartsOnLogin:
		when = "when this account logs in (automatic logon counts)"
	case StartsAtBoot:
		when = "at boot, with no login needed"
	}
	return string(s.Mechanism) + " at " + s.Path + "\n  starts " + when
}

// AutostartInfo reports what is registered for this install right now.
func AutostartInfo(inst Install) AutostartStatus { return autostartInfo(inst) }

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

// HelperInstalled reports whether this install has a helper binary at all.
func HelperInstalled(inst Install) bool { return isFile(HelperBinary(inst)) }

// HelperRunning asks the helper itself whether it is there.
//
// The config file existing is not the same question: it outlives a crash, and a
// stale one is exactly the state that leaves a browser mysteriously dead. So
// this does what the game does -- read the port and token the helper published,
// and call /health over loopback.
func HelperRunning(inst Install) bool {
	raw, err := os.ReadFile(filepath.Join(HelperDir(inst), "helper.json"))
	if err != nil {
		return false
	}
	var cfg struct {
		Port  int    `json:"port"`
		Token string `json:"token"`
	}
	if json.Unmarshal(raw, &cfg) != nil || cfg.Port <= 0 {
		return false
	}
	req, err := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/health", cfg.Port), nil)
	if err != nil {
		return false
	}
	req.Header.Set("X-Browser-Token", cfg.Token)
	resp, err := (&http.Client{Timeout: 2 * time.Second}).Do(req)
	if err != nil {
		return false
	}
	defer func() { _ = resp.Body.Close() }()
	return resp.StatusCode == http.StatusOK
}

// RegisterAutostart makes the helper start on its own from now on.
func RegisterAutostart(inst Install) error { return registerAutostart(inst) }

// UnregisterAutostart removes whatever RegisterAutostart put in place --
// including the mechanisms older versions used, which is why uninstall clears
// more than it ever registers.
func UnregisterAutostart(inst Install) error { return unregisterAutostart(inst) }

// AutostartDescription names where this install's registration lives.
func AutostartDescription(inst Install) string { return autostartDescription(inst) }
