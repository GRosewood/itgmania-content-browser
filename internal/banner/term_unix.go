//go:build !windows

package banner

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func isTerminal(f *os.File) bool {
	st, err := f.Stat()
	if err != nil {
		return false
	}
	return st.Mode()&os.ModeCharDevice != 0
}

// enableVirtualTerminal is a Windows concern; ANSI already works here.
func enableVirtualTerminal() bool { return false }

// TerminalWidth returns the terminal width in columns, or 0 if unknown.
// COLUMNS is checked first so callers can override; `tput cols` is the
// portable fallback and avoids pulling in a terminal library.
func TerminalWidth() int {
	if v := os.Getenv("COLUMNS"); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n > 0 {
			return n
		}
	}
	out, err := exec.Command("tput", "cols").Output()
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return 0
	}
	return n
}
