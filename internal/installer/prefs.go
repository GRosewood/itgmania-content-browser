package installer

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Hosts added to ITGmania's allowlist. The game reads all of these directly:
// NETWORK:HttpRequest streams pack downloads to disk, FILEMAN:Unzip lands
// them in /Songs, and the preview relay serves song samples the engine can
// write byte-for-byte. Nothing local relays anything any more.
var Hosts = []string{
	// The catalogue, pack pages and downloads. The browser now fetches these
	// itself: NETWORK:HttpRequest streams a pack straight to disk and
	// FILEMAN:Unzip lands it in /Songs, so there is nothing left for a local
	// relay to carry.
	"stepmaniaonline.net",
	"*.stepmaniaonline.net",
	// What people are actually playing, and the doubles-pack category.
	"arrowcloud.dance",
	"*.arrowcloud.dance",
	"itgdb.net",
	"*.itgdb.net",
	// The song-preview relay, deployed -- audio, chart windows, pack facts
	// and single-song archives all come through it.
	"itgcontent.net",
	"*.itgcontent.net",
	// ...and the same relay running beside a development machine. localhost
	// rather than 127.0.0.1 is deliberate: on Windows, WSL's port forwarding
	// listens on ::1, which localhost resolves to and the address does not --
	// and the engine matches allowlist entries against the URL's host as a
	// string, so the two are different entries.
	"localhost",
	// The in-game updater: the manifest lives on raw.githubusercontent.com
	// and the module archive on github.com, whose download redirects land on
	// objects.githubusercontent.com -- the wildcard covers both content hosts.
	"github.com",
	"*.githubusercontent.com",
}

// Both the bare host and the wildcard are listed on purpose. The engine's
// IsUrlAllowed treats "*.example.com" as a suffix match that REQUIRES at least
// one leading label, so it matches api.example.com and never example.com
// itself. Listing only the wildcard would silently fail for the bare domain,
// and listing only the bare one would fail for every subdomain.

// PrefsResult describes what EnsureAllowlist did.
type PrefsResult struct {
	Path       string
	Changed    bool
	Created    bool
	BackupPath string
	AllowHosts string
}

// mergeHosts folds Hosts into an existing comma-separated allowlist,
// preserving the original order and skipping duplicates case-insensitively.
func mergeHosts(current string) (string, bool) {
	var list []string
	seen := map[string]bool{}
	for _, h := range strings.Split(current, ",") {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		k := strings.ToLower(h)
		if seen[k] {
			continue
		}
		seen[k] = true
		list = append(list, h)
	}
	added := false
	for _, h := range Hosts {
		if seen[strings.ToLower(h)] {
			continue
		}
		seen[strings.ToLower(h)] = true
		list = append(list, h)
		added = true
	}
	return strings.Join(list, ","), added
}

// splitKV splits "Key=Value" honouring leading whitespace. ok is false for
// section headers, comments and blank lines.
func splitKV(line string) (key, value string, ok bool) {
	t := strings.TrimSpace(line)
	if t == "" || strings.HasPrefix(t, "[") || strings.HasPrefix(t, "#") || strings.HasPrefix(t, ";") {
		return "", "", false
	}
	i := strings.Index(t, "=")
	if i < 0 {
		return "", "", false
	}
	return strings.TrimSpace(t[:i]), strings.TrimSpace(t[i+1:]), true
}

// EnsureAllowlist makes sure Preferences.ini allows our hosts and has HTTP
// enabled. It preserves every other line, writes a timestamped backup before
// changing anything, and is safe to run repeatedly.
//
// ITGmania rewrites Preferences.ini from memory when it exits, so this must
// only be called while the game is not running (see GameRunning).
func EnsureAllowlist(saveDir string) (PrefsResult, error) {
	res := PrefsResult{Path: filepath.Join(saveDir, "Preferences.ini")}

	raw, err := os.ReadFile(res.Path)
	if err != nil {
		if !os.IsNotExist(err) {
			return res, fmt.Errorf("reading %s: %w", res.Path, err)
		}
		// First run: create a minimal Options section. ITGmania merges this
		// with its defaults on load and rewrites the full file on exit.
		if err := os.MkdirAll(saveDir, 0o755); err != nil {
			return res, fmt.Errorf("creating %s: %w", saveDir, err)
		}
		hosts, _ := mergeHosts("")
		body := "[Options]\nHttpEnabled=1\nHttpAllowHosts=" + hosts + "\n"
		if err := os.WriteFile(res.Path, []byte(body), 0o644); err != nil {
			return res, fmt.Errorf("writing %s: %w", res.Path, err)
		}
		// a Preferences.ini made for somebody else has to belong to them
		chownLike(res.Path, saveDir)
		res.Changed, res.Created, res.AllowHosts = true, true, hosts
		return res, nil
	}

	// Preserve the file's existing line endings.
	crlf := bytes.Contains(raw, []byte("\r\n"))
	newline := "\n"
	if crlf {
		newline = "\r\n"
	}

	var lines []string
	sc := bufio.NewScanner(bytes.NewReader(raw))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		lines = append(lines, strings.TrimRight(sc.Text(), "\r"))
	}
	if err := sc.Err(); err != nil {
		return res, fmt.Errorf("reading %s: %w", res.Path, err)
	}

	changed := false
	sawHosts, sawEnabled := false, false
	out := make([]string, 0, len(lines)+2)

	for _, line := range lines {
		key, value, ok := splitKV(line)
		if !ok {
			out = append(out, line)
			continue
		}
		switch strings.ToLower(key) {
		case "httpallowhosts":
			sawHosts = true
			merged, added := mergeHosts(value)
			if added {
				changed = true
			}
			res.AllowHosts = merged
			out = append(out, "HttpAllowHosts="+merged)
		case "httpenabled":
			sawEnabled = true
			if value != "1" {
				changed = true
			}
			out = append(out, "HttpEnabled=1")
		default:
			out = append(out, line)
		}
	}

	// Keys missing entirely: insert them under [Options].
	if !sawHosts || !sawEnabled {
		inserted := false
		rebuilt := make([]string, 0, len(out)+2)
		for _, line := range out {
			rebuilt = append(rebuilt, line)
			if !inserted && strings.EqualFold(strings.TrimSpace(line), "[Options]") {
				if !sawEnabled {
					rebuilt = append(rebuilt, "HttpEnabled=1")
				}
				if !sawHosts {
					hosts, _ := mergeHosts("")
					res.AllowHosts = hosts
					rebuilt = append(rebuilt, "HttpAllowHosts="+hosts)
				}
				inserted = true
				changed = true
			}
		}
		if !inserted {
			// No [Options] section at all: prepend one.
			head := []string{"[Options]"}
			if !sawEnabled {
				head = append(head, "HttpEnabled=1")
			}
			if !sawHosts {
				hosts, _ := mergeHosts("")
				res.AllowHosts = hosts
				head = append(head, "HttpAllowHosts="+hosts)
			}
			rebuilt = append(head, out...)
			changed = true
		}
		out = rebuilt
	}

	if !changed {
		return res, nil
	}

	res.BackupPath = res.Path + ".bak-" + time.Now().Format("20060102-150405")
	if err := os.WriteFile(res.BackupPath, raw, 0o644); err != nil {
		return res, fmt.Errorf("writing backup %s: %w", res.BackupPath, err)
	}
	chownLike(res.BackupPath, res.Path)

	body := strings.Join(out, newline) + newline
	if err := writeFileAtomic(res.Path, []byte(body)); err != nil {
		return res, fmt.Errorf("writing %s: %w", res.Path, err)
	}
	res.Changed = true
	return res, nil
}

// writeFileAtomic writes via a temp file in the same directory then renames,
// so an interrupted run cannot leave a half-written Preferences.ini.
// The rename is also what makes ownership a problem worth handling: the file
// that ends up in place is the temp one, created by whoever is running this. On
// a cabinet set up with sudo that is root, and a root-owned Preferences.ini
// cannot be rewritten by the player's game -- which rewrites the whole file
// every time it exits, so their settings would quietly stop persisting from
// here on. The new file is handed back to whoever owned the old one.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	model := path
	if _, err := os.Stat(model); err != nil {
		// no file to inherit from; the directory it lives in will do
		model = dir
	}
	tmp, err := os.CreateTemp(dir, ".fc-tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	chownLike(tmpName, model)
	// Windows will not rename onto an existing file.
	_ = os.Remove(path)
	return os.Rename(tmpName, path)
}

// AllowlistSatisfied reports whether Preferences.ini already grants access.
func AllowlistSatisfied(saveDir string) bool {
	raw, err := os.ReadFile(filepath.Join(saveDir, "Preferences.ini"))
	if err != nil {
		return false
	}
	enabled, allowed := false, false
	sc := bufio.NewScanner(bytes.NewReader(raw))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		key, value, ok := splitKV(sc.Text())
		if !ok {
			continue
		}
		switch strings.ToLower(key) {
		case "httpenabled":
			enabled = value == "1"
		case "httpallowhosts":
			for _, h := range strings.Split(value, ",") {
				if strings.EqualFold(strings.TrimSpace(h), Hosts[0]) {
					allowed = true
				}
			}
		}
	}
	return enabled && allowed
}

// AllowlistState is AllowlistSatisfied with the reason it is not.
//
// Three different failures used to arrive as one "the allowlist does not look
// right": the file not being there at all, HttpEnabled being off, and the
// loopback entry being absent. They need different answers -- the first is
// usually the wrong save directory or a game that has never been run, and
// telling someone to re-run the installer for that is a dead end -- so the
// caller gets to say which one happened.
func AllowlistState(saveDir string) (ok bool, reason string) {
	path := filepath.Join(saveDir, "Preferences.ini")
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, "there is no Preferences.ini at " + path +
				" -- run ITGmania once so it writes one, then install again"
		}
		return false, "cannot read " + path + ": " + err.Error()
	}
	enabled := false
	present := map[string]bool{}
	sc := bufio.NewScanner(bytes.NewReader(raw))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		key, value, fine := splitKV(sc.Text())
		if !fine {
			continue
		}
		switch strings.ToLower(key) {
		case "httpenabled":
			enabled = value == "1"
		case "httpallowhosts":
			for _, h := range strings.Split(value, ",") {
				present[strings.ToLower(strings.TrimSpace(h))] = true
			}
		}
	}
	// Every host, not just the first. The browser reaches the catalogue, the
	// pack downloads and two smaller services directly now, so a file carrying
	// some of them and not others is a browser that half works -- and calling
	// that "ok" because one entry matched is how a partial allowlist gets
	// mistaken for a network fault.
	var missing []string
	for _, h := range Hosts {
		if !present[strings.ToLower(h)] {
			missing = append(missing, h)
		}
	}

	switch {
	case !enabled && len(missing) > 0:
		return false, "HttpEnabled is not 1, and HttpAllowHosts is missing " +
			strings.Join(missing, ", ")
	case !enabled:
		return false, "HttpEnabled is not 1 (the hosts are fine)"
	case len(missing) > 0:
		return false, "HttpAllowHosts is missing " + strings.Join(missing, ", ") +
			" (HttpEnabled is fine)"
	}
	return true, ""
}
