package installer

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// all returns the stock allowlist as one comma-separated string, so the cases
// below describe behaviour rather than restating the list. Spelling it out per
// case meant adding one host broke six tests that were not about that host.
func all(prefix ...string) string {
	return strings.Join(append(append([]string{}, prefix...), Hosts...), ",")
}

func TestMergeHosts(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		want    string
		changed bool
	}{
		{
			name:    "adds to the stock allowlist, keeping what was there",
			in:      "*.groovestats.com,*.itgmania.com",
			want:    all("*.groovestats.com", "*.itgmania.com"),
			changed: true,
		},
		{
			name:    "already present is a no-op",
			in:      all("*.groovestats.com"),
			want:    all("*.groovestats.com"),
			changed: false,
		},
		{
			name:    "case-insensitive match is a no-op",
			in:      "StepManiaOnline.NET,*.StepManiaOnline.NET,arrowcloud.dance,*.arrowcloud.dance,itgdb.net,*.itgdb.net,itgcontent.net,*.itgcontent.net,LOCALHOST,127.0.0.1,github.com,*.githubusercontent.com",
			want:    "StepManiaOnline.NET,*.StepManiaOnline.NET,arrowcloud.dance,*.arrowcloud.dance,itgdb.net,*.itgdb.net,itgcontent.net,*.itgcontent.net,LOCALHOST,127.0.0.1,github.com,*.githubusercontent.com",
			changed: false,
		},
		{
			name:    "empty list gets the whole allowlist",
			in:      "",
			want:    all(),
			changed: true,
		},
		{
			name:    "whitespace and duplicates are cleaned up",
			in:      " *.groovestats.com , *.groovestats.com ,, ",
			want:    all("*.groovestats.com"),
			changed: true,
		},
		{
			// One host already there, the rest added, and no duplicate of the
			// one that was. mergeHosts de-duplicates case-insensitively, so an
			// entry the file already carries is kept in its original position
			// and not appended a second time.
			name: "partial presence adds only what is missing",
			in:   "stepmaniaonline.net",
			want: "stepmaniaonline.net,*.stepmaniaonline.net,arrowcloud.dance," +
				"*.arrowcloud.dance,itgdb.net,*.itgdb.net,itgcontent.net,*.itgcontent.net,localhost,github.com,*.githubusercontent.com",
			changed: true,
		},
		{
			// Nothing to do: every host this install needs is already listed.
			name:    "a complete allowlist is left exactly as it is",
			in:      "stepmaniaonline.net,*.stepmaniaonline.net,arrowcloud.dance,*.arrowcloud.dance,itgdb.net,*.itgdb.net,itgcontent.net,*.itgcontent.net,localhost,github.com,*.githubusercontent.com",
			want:    "stepmaniaonline.net,*.stepmaniaonline.net,arrowcloud.dance,*.arrowcloud.dance,itgdb.net,*.itgdb.net,itgcontent.net,*.itgcontent.net,localhost,github.com,*.githubusercontent.com",
			changed: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, changed := mergeHosts(tc.in)
			if got != tc.want {
				t.Errorf("hosts:\n  got  %q\n  want %q", got, tc.want)
			}
			if changed != tc.changed {
				t.Errorf("changed: got %v want %v", changed, tc.changed)
			}
		})
	}
}

// The whole point of the installer is that it does not disturb the rest of a
// user's preferences.
func TestEnsureAllowlistPreservesFile(t *testing.T) {
	dir := t.TempDir()
	original := strings.Join([]string{
		"[Options]",
		"# a comment",
		"Center1Player=1",
		"HttpAllowHosts=*.groovestats.com,*.itgmania.com",
		"HttpEnabled=1",
		"LastSeenVideoDriver=whatever",
		"",
		"[Game-dance]",
		"Announcer=",
	}, "\n") + "\n"

	path := filepath.Join(dir, "Preferences.ini")
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := EnsureAllowlist(dir)
	if err != nil {
		t.Fatalf("EnsureAllowlist: %v", err)
	}
	if !res.Changed {
		t.Fatal("expected a change")
	}
	if res.BackupPath == "" {
		t.Fatal("expected a backup to be written")
	}
	if _, err := os.Stat(res.BackupPath); err != nil {
		t.Fatalf("backup missing: %v", err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	beforeLines := strings.Split(strings.TrimRight(original, "\n"), "\n")
	afterLines := strings.Split(strings.TrimRight(string(after), "\n"), "\n")
	if len(beforeLines) != len(afterLines) {
		t.Fatalf("line count changed: %d -> %d", len(beforeLines), len(afterLines))
	}
	diffs := 0
	for i := range beforeLines {
		if beforeLines[i] != afterLines[i] {
			diffs++
			if !strings.HasPrefix(afterLines[i], "HttpAllowHosts=") {
				t.Errorf("unexpected line changed: %q -> %q", beforeLines[i], afterLines[i])
			}
		}
	}
	if diffs != 1 {
		t.Errorf("expected exactly 1 changed line, got %d", diffs)
	}
	if !AllowlistSatisfied(dir) {
		t.Error("allowlist should be satisfied after install")
	}
}

func TestEnsureAllowlistIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Preferences.ini")
	body := "[Options]\nHttpEnabled=1\nHttpAllowHosts=*.groovestats.com\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	first, err := EnsureAllowlist(dir)
	if err != nil || !first.Changed {
		t.Fatalf("first run: changed=%v err=%v", first.Changed, err)
	}
	afterFirst, _ := os.ReadFile(path)

	second, err := EnsureAllowlist(dir)
	if err != nil {
		t.Fatalf("second run: %v", err)
	}
	if second.Changed {
		t.Error("second run should not change anything")
	}
	if second.BackupPath != "" {
		t.Error("second run should not write a backup")
	}
	afterSecond, _ := os.ReadFile(path)
	if string(afterFirst) != string(afterSecond) {
		t.Error("file changed on the idempotent run")
	}
}

func TestEnsureAllowlistCreatesMissingFile(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Save")

	res, err := EnsureAllowlist(dir)
	if err != nil {
		t.Fatalf("EnsureAllowlist: %v", err)
	}
	if !res.Created || !res.Changed {
		t.Fatalf("expected creation: created=%v changed=%v", res.Created, res.Changed)
	}
	if !AllowlistSatisfied(dir) {
		t.Error("freshly created file should satisfy the allowlist")
	}
}

func TestEnsureAllowlistTurnsHttpBackOn(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Preferences.ini")
	body := "[Options]\nHttpEnabled=0\nHttpAllowHosts=stepmaniaonline.net,*.stepmaniaonline.net\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	if AllowlistSatisfied(dir) {
		t.Fatal("HttpEnabled=0 must not count as satisfied")
	}
	if _, err := EnsureAllowlist(dir); err != nil {
		t.Fatal(err)
	}
	if !AllowlistSatisfied(dir) {
		t.Error("HttpEnabled should have been turned back on")
	}
}

// Keys can be missing entirely on a sparse Preferences.ini.
func TestEnsureAllowlistInsertsMissingKeys(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Preferences.ini")
	body := "[Options]\nCenter1Player=1\n\n[Game-dance]\nAnnouncer=\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := EnsureAllowlist(dir); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	if !AllowlistSatisfied(dir) {
		t.Fatalf("allowlist not satisfied; file is:\n%s", after)
	}
	// The inserted keys must land inside [Options], not in the game section.
	text := string(after)
	optIdx := strings.Index(text, "[Options]")
	gameIdx := strings.Index(text, "[Game-dance]")
	hostIdx := strings.Index(text, "HttpAllowHosts=")
	if !(optIdx < hostIdx && hostIdx < gameIdx) {
		t.Errorf("HttpAllowHosts landed outside [Options]:\n%s", text)
	}
}

func TestEnsureAllowlistPreservesCRLF(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Preferences.ini")
	body := "[Options]\r\nHttpEnabled=1\r\nHttpAllowHosts=*.groovestats.com\r\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := EnsureAllowlist(dir); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	if !strings.Contains(string(after), "\r\n") {
		t.Error("CRLF line endings were not preserved")
	}
	if strings.Contains(strings.ReplaceAll(string(after), "\r\n", ""), "\n") {
		t.Error("mixed line endings after rewrite")
	}
}
