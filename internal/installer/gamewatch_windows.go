//go:build windows

package installer

// Watching for ITGmania without costing anything.
//
// The helper holds a loopback socket the game talks to, and there is no reason
// for that socket to exist while the game is not running. Finding out when it
// starts and stops has to be cheap, though: this runs on somebody's machine all
// the time, and GameRunning() shells out to tasklist, which spawns a process per
// check and is far too heavy to poll with.
//
// Noticing it STOP is free: a wait on the process handle costs nothing while it
// blocks. The kernel wakes us; we never ask.
//
// Noticing it START costs a Toolhelp snapshot -- 5.2ms, because it copies a
// record per process. Once every five seconds that is a tenth of a per cent of
// a core, and the whole helper measures at about a fifth of one while it waits.
// Real, small, and paid where it can be seen.
//
// There was a cleverer one here and it was a bad idea. Windows will not open a
// running executable for writing, so opening the game's binary for write and
// closing it again answered the question in microseconds. What that leaves out
// is who pays for it: Defender scans a file when a write handle on it is closed,
// so probing every two seconds meant a real-time scan of a thirty-megabyte
// executable every two seconds, all day, for a game that was not running. This
// process measured as idle the whole time, because the work had been moved
// somewhere nobody thought to measure.
//
// Repeatedly opening executables for write is also, reasonably, the thing
// security software exists to notice. Being cheap is not worth looking like a
// file infector on somebody else's machine.

import (
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
// name; a renamed binary is not worth guessing at, and failing to match one only
// means the helper behaves as it always did.
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
// Polled, because Windows offers no way to be told a process STARTED without
// WMI and COM. Five seconds between snapshots costs about a tenth of a per cent
// of a core, and the game takes far longer than that to reach its title menu,
// so the socket is up well before anything asks for it.
func WaitForGame(stop <-chan struct{}) (uint32, bool) {
	for {
		if pid, ok := GameProcessID(); ok {
			return pid, true
		}
		select {
		case <-stop:
			return 0, false
		case <-time.After(5 * time.Second):
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
