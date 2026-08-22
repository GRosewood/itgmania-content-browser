//go:build windows

package banner

import (
	"os"
	"syscall"
	"unsafe"
)

const (
	enableVirtualTerminalProcessing = 0x0004
	stdOutputHandle                 = ^uintptr(10) + 1 // -11
)

var kernel32 = syscall.NewLazyDLL("kernel32.dll")

func isTerminal(f *os.File) bool {
	getConsoleMode := kernel32.NewProc("GetConsoleMode")
	if getConsoleMode.Find() != nil {
		return false
	}
	var mode uint32
	r, _, _ := getConsoleMode.Call(f.Fd(), uintptr(unsafe.Pointer(&mode)))
	return r != 0
}

// enableVirtualTerminal turns on ANSI escape handling for the console, which
// Windows 10+ supports but does not enable by default for every host.
func enableVirtualTerminal() bool {
	getConsoleMode := kernel32.NewProc("GetConsoleMode")
	setConsoleMode := kernel32.NewProc("SetConsoleMode")
	if getConsoleMode.Find() != nil || setConsoleMode.Find() != nil {
		return false
	}
	h := os.Stdout.Fd()
	var mode uint32
	if r, _, _ := getConsoleMode.Call(h, uintptr(unsafe.Pointer(&mode))); r == 0 {
		return false
	}
	if mode&enableVirtualTerminalProcessing != 0 {
		return true
	}
	r, _, _ := setConsoleMode.Call(h, uintptr(mode|enableVirtualTerminalProcessing))
	return r != 0
}

// TerminalWidth returns the console width in columns, or 0 if unknown.
func TerminalWidth() int {
	getConsoleScreenBufferInfo := kernel32.NewProc("GetConsoleScreenBufferInfo")
	if getConsoleScreenBufferInfo.Find() != nil {
		return 0
	}
	// COORD, SMALL_RECT and friends; only the window rect is needed.
	var info struct {
		size              [2]int16
		cursorPosition    [2]int16
		attributes        uint16
		window            [4]int16 // left, top, right, bottom
		maximumWindowSize [2]int16
	}
	r, _, _ := getConsoleScreenBufferInfo.Call(os.Stdout.Fd(), uintptr(unsafe.Pointer(&info)))
	if r == 0 {
		return 0
	}
	w := int(info.window[2]) - int(info.window[0]) + 1
	if w < 0 {
		return 0
	}
	return w
}
