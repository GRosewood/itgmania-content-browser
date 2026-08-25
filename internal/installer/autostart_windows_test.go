//go:build windows

package installer

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// The task definition is the thing that has to be exactly right: schtasks
// rejects the whole file for a single malformed field, and the failure lands on
// a player's machine rather than here.

func TestTaskXMLPinsTriggerAndPrincipal(t *testing.T) {
	body, err := taskXML(testInstall(`C:\Games\ITGmania`))
	if err != nil {
		t.Skipf("no current user in this environment: %v", err)
	}
	for _, want := range []string{
		"<LogonTrigger>",         // it must be a logon trigger, not a schedule
		"InteractiveToken",       // ...running in the user's own session
		"LeastPrivilege",         // ...unelevated
		"<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>", // never killed at 72h
		"-install-dir",           // the helper is pinned to this install
		"content-browser-helper", // and it runs the helper, not the installer
	} {
		if !strings.Contains(body, want) {
			t.Errorf("task XML is missing %q", want)
		}
	}
}

// A path with an ampersand or a quote in it must not break the document. Game
// folders are user-named, so this is not hypothetical.
func TestTaskXMLEscapesPaths(t *testing.T) {
	body, err := taskXML(testInstall(`C:\Games\Rock & Roll <ITG>`))
	if err != nil {
		t.Skipf("no current user in this environment: %v", err)
	}
	if strings.Contains(body, "Rock & Roll") {
		t.Error("a raw ampersand reached the XML")
	}
	if !strings.Contains(body, "Rock &amp; Roll") {
		t.Error("the ampersand was not escaped")
	}
	if strings.Contains(body, "<ITG>") {
		t.Error("raw angle brackets reached the XML")
	}
}

// schtasks reads /XML as UTF-16 and rejects UTF-8 with a parse error that names
// a byte offset rather than the encoding, which is a miserable thing to debug.
func TestUTF16LEHasBOMAndWidth(t *testing.T) {
	got := utf16LE("Ab")
	want := []byte{0xFF, 0xFE, 'A', 0x00, 'b', 0x00}
	if len(got) != len(want) {
		t.Fatalf("utf16LE(%q) = % x, want % x", "Ab", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("utf16LE(%q) = % x, want % x", "Ab", got, want)
		}
	}
}

func TestUTF16LEEncodesAstralAsSurrogatePair(t *testing.T) {
	got := utf16LE("\U0001F600") // an emoji, which a folder name can contain
	if len(got) != 2+4 {
		t.Fatalf("astral rune produced %d bytes, want 6 (BOM + surrogate pair)", len(got))
	}
	hi := uint16(got[2]) | uint16(got[3])<<8
	lo := uint16(got[4]) | uint16(got[5])<<8
	if hi < 0xD800 || hi > 0xDBFF || lo < 0xDC00 || lo > 0xDFFF {
		t.Errorf("not a surrogate pair: %04X %04X", hi, lo)
	}
}

func TestTaskNamesArePerInstall(t *testing.T) {
	a := taskName(testInstall(`C:\Games\ITGmania`))
	b := taskName(testInstall(`C:\Games\ITGmania2`))
	if a == b {
		t.Fatal("two installs would fight over one task")
	}
	if !strings.HasPrefix(a, `\`) {
		t.Errorf("task name %q should sit at the scheduler root", a)
	}
}

// The real thing: hand our own generated XML to schtasks and see whether it is
// accepted, under a name no real install would use. Skipped rather than failed
// where task creation is not permitted, because that is a property of the
// machine and not of this code -- but when it IS permitted, a definition
// schtasks rejects is a bug worth failing on.
func TestGeneratedTaskIsAcceptedBySchtasks(t *testing.T) {
	if os.Getenv("CB_SKIP_SCHTASKS") != "" {
		t.Skip("disabled by CB_SKIP_SCHTASKS")
	}
	inst := testInstall(`C:\Games\ITGmaniaSelfTest`)
	name := taskName(inst)

	if err := registerTask(inst); err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "denied") {
			t.Skipf("this machine does not permit task creation: %v", err)
		}
		t.Fatalf("schtasks rejected our task definition: %v", err)
	}
	defer func() {
		_ = exec.Command("schtasks", "/Delete", "/TN", name, "/F").Run()
	}()

	if !taskPresent(inst) {
		t.Fatal("schtasks accepted the task but cannot find it")
	}

	out, err := exec.Command("schtasks", "/Query", "/TN", name, "/XML").CombinedOutput()
	if err != nil {
		t.Fatalf("querying the task back: %v", err)
	}
	if !strings.Contains(string(out), "LogonTrigger") {
		t.Errorf("the registered task is not logon-triggered:\n%s", out)
	}
}
