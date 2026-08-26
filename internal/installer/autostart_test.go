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
