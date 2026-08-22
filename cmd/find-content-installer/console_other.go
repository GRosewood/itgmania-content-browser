//go:build !windows

package main

// isDoubleClicked is Windows-only behaviour; elsewhere the installer is run
// from a terminal that stays open on its own.
func isDoubleClicked() bool { return false }
