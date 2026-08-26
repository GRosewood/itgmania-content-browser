//go:build windows

package main

import "syscall"

// Keep the helper off the screen entirely.
//
// The helper is a console program started by the Task Scheduler, so Windows
// gives it a console window. Hiding that window left the process still
// attached to a console, which is why a terminal could still appear at logon.
//
// FreeConsole detaches from it outright: the window goes and no taskbar entry
// is left behind. The window is hidden first because the two do different
// things and hiding is instant -- detaching alone can leave the window painted
// for the moment before it happens.
//
// A brief flash before this runs is not reachable from here: the console is
// allocated by Windows when the process starts, before any Go code. Removing
// that too would take a second binary built for the GUI subsystem, which is
// not worth an extra artifact for a frame.
func hideConsole() {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	user32 := syscall.NewLazyDLL("user32.dll")
	getConsoleWindow := kernel32.NewProc("GetConsoleWindow")
	showWindow := user32.NewProc("ShowWindow")
	freeConsole := kernel32.NewProc("FreeConsole")

	if hwnd, _, _ := getConsoleWindow.Call(); hwnd != 0 {
		const swHide = 0
		showWindow.Call(hwnd, swHide)
	}
	freeConsole.Call()
}
