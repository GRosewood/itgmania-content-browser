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

	// A machine with ITGmania actually running answers this the other way,
	// and correctly so -- the wait is over because the game is there. The
	// property being pinned is that it comes BACK, not which reason it gives.
	gameUp := false
	if _, ok := GameProcessID(); ok {
		gameUp = true
	}

	returned := make(chan bool, 1)
	go func() {
		_, ok := WaitForGame(stop)
		returned <- ok
	}()
	select {
	case ok := <-returned:
		if ok && !gameUp {
			t.Error("WaitForGame reported a game that is not in the process list")
		}
		if !ok && gameUp {
			t.Error("WaitForGame missed a game that is in the process list")
		}
	case <-time.After(10 * time.Second):
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

// The watch must never open an executable for writing. It did once, as a cheap
// way to ask whether the game was running, and the cost landed on the antivirus
// instead: Defender rescans a file whenever a write handle on it closes, so a
// probe every couple of seconds meant scanning the game binary every couple of
// seconds forever. Nothing here should reintroduce that.
func TestTheWatchNeverOpensAnExecutableForWriting(t *testing.T) {
	src, err := os.ReadFile("gamewatch_windows.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	// the comment explaining why is expected; a real call is not
	for _, banned := range []string{"GENERIC_WRITE", "CreateFile("} {
		for _, line := range strings.Split(body, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "//") {
				continue
			}
			if strings.Contains(line, banned) {
				t.Errorf("the watch opens files again: %q", trimmed)
			}
		}
	}
}
