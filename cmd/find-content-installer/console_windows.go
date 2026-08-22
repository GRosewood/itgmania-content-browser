//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

// isDoubleClicked reports whether we own the console window, which is the case
// when the user double-clicked the exe rather than running it from a shell.
// In that situation the window would vanish before the output could be read.
func isDoubleClicked() bool {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	getConsoleProcessList := kernel32.NewProc("GetConsoleProcessList")
	if getConsoleProcessList.Find() != nil {
		return false
	}
	var pids [4]uint32
	n, _, _ := getConsoleProcessList.Call(
		uintptr(unsafe.Pointer(&pids[0])),
		uintptr(len(pids)),
	)
	// Exactly one process attached to this console: it was created for us.
	return n == 1
}
