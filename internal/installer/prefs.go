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

// Hosts added to ITGmania's allowlist so the module can reach the pack index.
var Hosts = []string{"stepmaniaonline.net", "*.stepmaniaonline.net"}

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

	body := strings.Join(out, newline) + newline
	if err := writeFileAtomic(res.Path, []byte(body)); err != nil {
		return res, fmt.Errorf("writing %s: %w", res.Path, err)
	}
	res.Changed = true
	return res, nil
}

// writeFileAtomic writes via a temp file in the same directory then renames,
// so an interrupted run cannot leave a half-written Preferences.ini.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
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
