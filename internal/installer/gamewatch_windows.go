//go:build windows

package installer

// Watching for ITGmania without costing anything.
//
// The helper holds a loopback socket the game talks to, and there is no reason
// for that socket to exist while the game is not running. Finding out when it
// starts and stops has to be cheap, though: this runs on somebody's machine
// all the time, and GameRunning() shells out to tasklist, which spawns a
// process per check and is far too heavy to poll with.
//
// A Toolhelp snapshot was the obvious way to notice it start, and measuring one
// put an end to that: 5.2 milliseconds, because it copies a record per process
// including every name. Every three seconds, forever, that is a fifth of a per
// cent of a core spent on a question whose answer is almost always no.
//
// So the question is asked a cheaper way first. Windows will not let anything
// open a running executable for writing -- the image section denies it, and the
// error is specifically ERROR_SHARING_VIOLATION rather than a plain refusal.
// Opening the game's own binary for write and closing it again therefore
// answers "is it running" in microseconds, touching nothing: the handle is shut
// without a byte written.
//
// The snapshot stays for two jobs the probe cannot do -- turning "yes" into a
// process id, and covering an install whose binary is somewhere this does not
// think to look -- but it now runs when something has actually happened, plus
// once in a long while as a backstop.
//
// Noticing it STOP was never the problem: a wait on the process handle costs
// nothing at all while it blocks. The kernel wakes us; we never ask.

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var (
	gameKernel32         = syscall.NewLazyDLL("kernel32.dll")
	procCreateSnapshot   = gameKernel32.NewProc("CreateToolhelp32Snapshot")
	procProcess32FirstW  = gameKernel32.NewProc("Process32FirstW")
	procProcess32NextW   = gameKernel32.NewProc("Process32NextW")
	procOpenProcess      = gameKernel32.NewProc("OpenProcess")
	procWaitForSingleObj = gameKernel32.NewProc("WaitForSingleObject")
)

const (
	th32csSnapProcess = 0x00000002
	synchronize       = 0x00100000
	infinite          = 0xFFFFFFFF
	maxPath           = 260
)

type processEntry32 struct {
	Size            uint32
	Usage           uint32
	ProcessID       uint32
	DefaultHeapID   uintptr
	ModuleID        uint32
	Threads         uint32
	ParentProcessID uint32
	PriClassBase    int32
	Flags           uint32
	ExeFile         [maxPath]uint16
}

// gameNames are the executables an ITGmania install runs under. Forks keep the
// name; a renamed binary is not worth guessing at, and failing to match one
// only means the helper behaves as it always did.
var gameNames = []string{"itgmania.exe", "stepmania.exe"}

// GameProcessID is the process id of a running ITGmania, if there is one.
func GameProcessID() (uint32, bool) { return processIDNamed(gameNames) }

// processIDNamed walks the process list for the first entry whose executable is
// one of these names, lowercased. Split out from GameProcessID so the walk can
// be tested against a process that is certainly running -- this one -- rather
// than against a game that is certainly not.
func processIDNamed(names []string) (uint32, bool) {
	snap, _, _ := procCreateSnapshot.Call(th32csSnapProcess, 0)
	if snap == uintptr(syscall.InvalidHandle) || snap == 0 {
		return 0, false
	}
	defer syscall.CloseHandle(syscall.Handle(snap))

	var e processEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	ok, _, _ := procProcess32FirstW.Call(snap, uintptr(unsafe.Pointer(&e)))
	for ok != 0 {
		name := lowerUTF16(e.ExeFile[:])
		for _, want := range names {
			if name == want {
				return e.ProcessID, true
			}
		}
		ok, _, _ = procProcess32NextW.Call(snap, uintptr(unsafe.Pointer(&e)))
	}
	return 0, false
}

func lowerUTF16(buf []uint16) string {
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n++
	}
	out := make([]rune, n)
	for i := 0; i < n; i++ {
		c := rune(buf[i])
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		out[i] = c
	}
	return string(out)
}

// WaitForGame blocks until ITGmania is running, or until stop is closed.
//
// Polled, because Windows offers no cheap way to be told a process STARTED
// without WMI and COM. A snapshot every few seconds is a syscall and no more,
// and the game takes far longer than that to reach its title menu, so the
// socket is always up well before anything asks for it.
func WaitForGame(inst Install, stop <-chan struct{}) (uint32, bool) {
	images := gameImages(inst.Root)
	// A snapshot every so often regardless, so an install whose binary is
	// somewhere gameImages does not know about is still found -- just not at
	// the cost of asking every two seconds.
	const sweepEvery = 15
	sweepIn := 0

	for {
		probed, known := anyImageRunning(images)
		sweep := sweepIn <= 0
		sweepIn--

		// The probe answers whether, never which, so a yes still costs one
		// snapshot -- once per launch, which is what it is for.
		if (known && probed) || !known || sweep {
			if pid, ok := GameProcessID(); ok {
				return pid, true
			}
			sweepIn = sweepEvery
		}

		select {
		case <-stop:
			return 0, false
		case <-time.After(2 * time.Second):
		}
	}
}

// WaitForGameExit blocks until that process ends. Free: the kernel signals the
// handle, so nothing here runs until it does.
func WaitForGameExit(pid uint32) {
	h, _, _ := procOpenProcess.Call(synchronize, 0, uintptr(pid))
	if h == 0 {
		// Gone already, or not ours to wait on. Either way there is nothing
		// to wait for.
		return
	}
	defer syscall.CloseHandle(syscall.Handle(h))
	procWaitForSingleObj.Call(h, infinite)
}

// GameWatchSupported says whether this platform can gate the socket on the
// game. Where it cannot, the helper listens as it always has -- failing open,
// because a browser that cannot reach its helper is worse than a socket that
// outstays the game.
func GameWatchSupported() bool { return true }

// errSharingViolation is what Windows returns for an open that a running
// executable's image section refused. It is the whole signal: a plain
// ERROR_ACCESS_DENIED means something about permissions and says nothing about
// whether the game is running.
const errSharingViolation = syscall.Errno(32)

// gameImages are the executables to probe for this install, most likely first.
func gameImages(root string) []string {
	var out []string
	for _, p := range []string{
		filepath.Join(root, "Program", "ITGmania.exe"),
		filepath.Join(root, "Program", "StepMania.exe"),
	} {
		if isFile(p) {
			out = append(out, p)
		}
	}
	if len(out) > 0 {
		return out
	}
	// A fork renames the binary. Everything executable in Program/ is a
	// candidate then, which is still a handful of files rather than every
	// process on the machine.
	entries, err := os.ReadDir(filepath.Join(root, "Program"))
	if err != nil {
		return nil
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".exe") {
			out = append(out, filepath.Join(root, "Program", e.Name()))
		}
	}
	return out
}

// imageRunning reports whether that file is a running executable.
//
// known is false when the open failed for a reason that says nothing about the
// answer -- no permission to write there, the file gone, a path we cannot
// open at all. The caller falls back to the snapshot rather than guess.
func imageRunning(path string) (running, known bool) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return false, false
	}
	// Sharing everything on purpose: the refusal being looked for comes from
	// the image section, not from another handle's share mode, and denying
	// sharing here would make an unrelated reader look like a running game.
	h, err := syscall.CreateFile(p, syscall.GENERIC_WRITE,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		nil, syscall.OPEN_EXISTING, 0, 0)
	if err == nil {
		// Opened, so nothing is running it. Nothing was written: a handle
		// opened for writing and closed leaves the file exactly as it was.
		_ = syscall.CloseHandle(h)
		return false, true
	}
	if errors.Is(err, errSharingViolation) {
		return true, true
	}
	return false, false
}

// anyImageRunning asks the question of every candidate binary.
func anyImageRunning(paths []string) (running, known bool) {
	for _, p := range paths {
		got, ok := imageRunning(p)
		if !ok {
			return false, false // one unanswerable path makes the set unanswerable
		}
		if got {
			return true, true
		}
	}
	return false, len(paths) > 0
}
