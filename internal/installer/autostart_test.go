package installer

import (
	"strings"
	"testing"
)

// The autostart code had no tests at all, which is uncomfortable for the one
// part of the installer whose failure mode is "the browser silently never
// opens on a cabinet". These cover the parts that are the same everywhere; the
// platform files carry their own.

func testInstall(root string) Install {
	return Install{Root: root, SaveDir: root + "/Save"}
}

func TestInstallKeyDistinguishesInstalls(t *testing.T) {
	a := installKey(testInstall("/opt/itgmania"))
	b := installKey(testInstall("/opt/itgmania-2"))
	if a == b {
		t.Fatalf("two installs share a key: %s", a)
	}
	if len(a) != 8 {
		t.Errorf("key %q is %d chars, want 8", a, len(a))
	}
}

// The key is what keeps two installs from fighting over one registration, and
// it has to survive the same path being spelled differently -- a trailing
// slash, a doubled separator, a different case on a case-insensitive system.
func TestInstallKeyIsStableAcrossSpellings(t *testing.T) {
	want := installKey(testInstall("/opt/itgmania"))
	for _, spelling := range []string{
		"/opt/itgmania/",
		"/opt//itgmania",
		"/opt/./itgmania",
		"/OPT/ITGMANIA",
	} {
		if got := installKey(testInstall(spelling)); got != want {
			t.Errorf("%q -> %s, want %s", spelling, got, want)
		}
	}
}

// helperArgs must always carry -install-dir. Without it the helper falls back
// to discovery, and on a machine with two installs it can publish helper.json
// where the running game will never look for it.
func TestHelperArgsPinTheInstall(t *testing.T) {
	args := helperArgs(testInstall("/opt/itgmania"))
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-helper") {
		t.Errorf("helperArgs lost -helper: %q", joined)
	}
	if !strings.Contains(joined, "-install-dir") {
		t.Fatalf("helperArgs must pin -install-dir: %q", joined)
	}
	for i, a := range args {
		if a == "-install-dir" {
			if i+1 >= len(args) || args[i+1] != "/opt/itgmania" {
				t.Fatalf("-install-dir is not followed by the root: %q", joined)
			}
			return
		}
	}
}

func TestAutostartStatusDescribesWhenItStarts(t *testing.T) {
	cases := []struct {
		starts StartsWhen
		want   string
	}{
		{StartsAtBoot, "at boot"},
		{StartsOnLogin, "logs in"},
		{StartsOnDesktopSession, "desktop session"},
	}
	for _, c := range cases {
		got := AutostartStatus{Mechanism: MechTask, Path: "somewhere", Starts: c.starts}.Describe()
		if !strings.Contains(got, c.want) {
			t.Errorf("Starts=%v described as %q, want it to mention %q", c.starts, got, c.want)
		}
	}
	none := AutostartStatus{Mechanism: MechNone}.Describe()
	if !strings.Contains(none, "nothing") {
		t.Errorf("MechNone described as %q", none)
	}
}

// A machine with no registration must never be reported as fine. This is the
// property the whole -check flag exists to expose.
func TestNoMechanismIsNotSilentlyOK(t *testing.T) {
	s := AutostartStatus{Mechanism: MechNone}
	if s.Starts == StartsAtBoot {
		t.Fatal("an unregistered install must not claim to start at boot")
	}
	if !strings.Contains(s.Describe(), "nothing is registered") {
		t.Fatalf("Describe() = %q", s.Describe())
	}
}
