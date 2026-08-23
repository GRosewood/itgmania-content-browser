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

// macOS gets a LaunchAgent; everything else gets an XDG autostart entry. Both
// are per-user files, so neither needs elevation and both are removable. The
// install key is in the name so a second ITGmania does not overwrite the first.

const launchAgentBase = "net.gregtech.itgmania-content-browser.helper"

func launchAgentLabel(inst Install) string {
	return launchAgentBase + "." + installKey(inst)
}

func launchAgentPath(inst Install) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", launchAgentLabel(inst)+".plist")
}

func autostartDesktopPath(inst Install) string {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "autostart",
		"itgmania-content-browser-helper-"+installKey(inst)+".desktop")
}

func autostartPath(inst Install) string {
	if runtime.GOOS == "darwin" {
		return launchAgentPath(inst)
	}
	return autostartDesktopPath(inst)
}

// legacyAutostartPath is what builds before per-install naming wrote.
func legacyAutostartPath() string {
	if runtime.GOOS == "darwin" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, "Library", "LaunchAgents", launchAgentBase+".plist")
	}
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "autostart", "itgmania-content-browser-helper.desktop")
}

func registerAutostart(inst Install) error {
	path := autostartPath(inst)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	_ = os.Remove(legacyAutostartPath())

	bin := HelperBinary(inst)
	args := helperArgs(inst)

	var body string
	if runtime.GOOS == "darwin" {
		var argXML strings.Builder
		argXML.WriteString("\t\t<string>" + xmlEscape(bin) + "</string>\n")
		for _, a := range args {
			argXML.WriteString("\t\t<string>" + xmlEscape(a) + "</string>\n")
		}
		body = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + launchAgentLabel(inst) + `</string>
	<key>ProgramArguments</key>
	<array>
` + argXML.String() + `	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
`
	} else {
		body = "[Desktop Entry]\n" +
			"Type=Application\n" +
			"Name=ITGMania Content Browser Helper\n" +
			"Comment=Lets the in-game pack browser delete song packs\n" +
			"Exec=" + desktopExec(bin, args) + "\n" +
			"X-GNOME-Autostart-enabled=true\n" +
			"NoDisplay=true\n"
	}

	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return nil
}

func unregisterAutostart(inst Install) error {
	_ = os.Remove(legacyAutostartPath())
	if err := os.Remove(autostartPath(inst)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func autostartDescription(inst Install) string { return autostartPath(inst) }

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
