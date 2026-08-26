//go:build windows

package installer

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The snapshot walk is the whole basis of the Windows watch: if it cannot find
// a process that is definitely running, the helper never binds and the browser
// never opens. So it is checked against the one process certain to be there.
func TestProcessIDNamedFindsARunningProcess(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatalf("locating this test binary: %v", err)
	}
	name := strings.ToLower(filepath.Base(self))

	pid, ok := processIDNamed([]string{name})
	if !ok {
		t.Fatalf("did not find %q in the process list", name)
	}
	if pid != uint32(os.Getpid()) {
		// Another copy of the same test binary would also match, so this is
		// only worth reporting when it is the only one -- but a wrong pid is
		// still worth seeing.
		t.Logf("found pid %d, this process is %d", pid, os.Getpid())
	}
}

// Matching has to be case-insensitive: the process list reports whatever case
// the executable was created with, and gameNames is written in lower case.
func TestProcessIDNamedIgnoresCase(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	name := filepath.Base(self)
	if _, ok := processIDNamed([]string{strings.ToUpper(name)}); ok {
		t.Error("an upper-case name matched; gameNames must be lower case to work")
	}
	if _, ok := processIDNamed([]string{strings.ToLower(name)}); !ok {
		t.Error("the lower-case name did not match")
	}
}

func TestProcessIDNamedFindsNothingForANameNobodyRuns(t *testing.T) {
	if pid, ok := processIDNamed([]string{"itgmania-content-browser-no-such.exe"}); ok {
		t.Errorf("matched a process that cannot exist: pid %d", pid)
	}
}

// gameNames is what decides whether any of this fires, so it is pinned: lower
// case, with an extension, because that is what the process list reports and
// what lowerUTF16 produces.
func TestGameNamesAreComparable(t *testing.T) {
	for _, name := range gameNames {
		if name != strings.ToLower(name) {
			t.Errorf("%q is not lower case, so it can never match", name)
		}
		if !strings.HasSuffix(name, ".exe") {
			t.Errorf("%q has no .exe, but the process list reports one", name)
		}
	}
}

// The wait must come back when the helper is shutting down, or an uninstall
// would leave the process behind waiting for a game that is never started.
func TestWaitForGameReturnsWhenStopped(t *testing.T) {
	stop := make(chan struct{})
	close(stop)

	returned := make(chan bool, 1)
	go func() {
		_, ok := WaitForGame(Install{Root: t.TempDir()}, stop)
		returned <- ok
	}()
	select {
	case ok := <-returned:
		if ok {
			t.Error("WaitForGame claimed to have found a game")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("WaitForGame ignored its stop channel")
	}
}

// Waiting on a pid that has already gone must return rather than block: the
// game can exit between the snapshot that found it and the handle being opened.
func TestWaitForGameExitReturnsForADeadProcess(t *testing.T) {
	done := make(chan struct{})
	go func() {
		// 0xFFFFFFF0 is far above any real pid on Windows, so nothing owns it
		WaitForGameExit(0xFFFFFFF0)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("WaitForGameExit blocked on a pid that does not exist")
	}
}

func TestLowerUTF16StopsAtTheTerminator(t *testing.T) {
	buf := [maxPath]uint16{}
	for i, c := range "ITGmania.EXE" {
		buf[i] = uint16(c)
	}
	buf[12] = 0
	buf[13] = uint16('X') // rubbish past the terminator, as Windows leaves
	if got := lowerUTF16(buf[:]); got != "itgmania.exe" {
		t.Errorf("lowerUTF16 = %q, want %q", got, "itgmania.exe")
	}
}

// The cheap probe is what keeps this watch from costing anything, so what it
// says about a file nothing is running has to be right.
func TestImageRunningSaysNoForAFileNobodyRuns(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ITGmania.exe")
	if err := os.WriteFile(path, []byte("not really a program"), 0o644); err != nil {
		t.Fatal(err)
	}
	running, known := imageRunning(path)
	if !known {
		t.Fatal("could not tell, for a plain writable file")
	}
	if running {
		t.Error("a file nobody is running looked like a running image")
	}

	// and it must not have touched the file
	body, err := os.ReadFile(path)
	if err != nil || string(body) != "not really a program" {
		t.Errorf("the probe changed the file: %q, %v", body, err)
	}
}

// And what it says about one that IS running -- checked against this very test
// binary, which is by definition a running image.
func TestImageRunningSaysYesForARunningImage(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	running, known := imageRunning(self)
	if !known {
		t.Skip("no permission to probe this test binary where it is")
	}
	if !running {
		t.Error("the running test binary did not look like a running image")
	}
}

// A path that cannot be answered for must say so rather than guess, or the
// watch would sit forever believing the game is not running.
func TestImageRunningAdmitsWhenItCannotTell(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "no-such-directory", "ITGmania.exe")
	if _, known := imageRunning(missing); known {
		t.Error("claimed to know about a file that does not exist")
	}
}

// An empty candidate list is not evidence of anything.
func TestAnyImageRunningKnowsNothingWithNoCandidates(t *testing.T) {
	if _, known := anyImageRunning(nil); known {
		t.Error("claimed to know the answer with nothing to probe")
	}
}

// One unanswerable candidate poisons the set: a "no" derived from a file we
// could not open would stop the snapshot fallback from ever running.
func TestAnyImageRunningIsUnsureIfAnyCandidateIs(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "ITGmania.exe")
	if err := os.WriteFile(good, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	bad := filepath.Join(dir, "no-such-directory", "StepMania.exe")

	if _, known := anyImageRunning([]string{good, bad}); known {
		t.Error("an unanswerable candidate was treated as a definite no")
	}
	if running, known := anyImageRunning([]string{good}); !known || running {
		t.Errorf("running=%v known=%v, want false/true for a plain file", running, known)
	}
}

func TestGameImagesPrefersTheKnownNames(t *testing.T) {
	root := t.TempDir()
	prog := filepath.Join(root, "Program")
	if err := os.MkdirAll(prog, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"ITGmania.exe", "Texture Font Generator.exe"} {
		if err := os.WriteFile(filepath.Join(prog, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := gameImages(root)
	if len(got) != 1 || filepath.Base(got[0]) != "ITGmania.exe" {
		t.Errorf("gameImages = %v, want just the game binary", got)
	}
}

// A fork renames the binary, and then everything in Program/ is a candidate.
func TestGameImagesFallsBackToEverythingInProgram(t *testing.T) {
	root := t.TempDir()
	prog := filepath.Join(root, "Program")
	if err := os.MkdirAll(prog, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"MyFork.exe", "helper.dll"} {
		if err := os.WriteFile(filepath.Join(prog, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := gameImages(root)
	if len(got) != 1 || filepath.Base(got[0]) != "MyFork.exe" {
		t.Errorf("gameImages = %v, want the fork's binary and not the dll", got)
	}
}

func TestGameImagesFindsNothingWithoutAProgramDirectory(t *testing.T) {
	if got := gameImages(t.TempDir()); len(got) != 0 {
		t.Errorf("gameImages = %v, want none", got)
	}
}
