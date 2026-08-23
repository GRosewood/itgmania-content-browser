//go:build !windows

package main

// Only Windows pops a console for a login item.
func hideConsole() {}
