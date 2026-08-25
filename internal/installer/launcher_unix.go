//go:build !windows

package installer

// Starting the helper on a machine that never logs anybody in.
//
// A cabinet image boots straight into ITGmania. There is no login, so logind
// starts no per-user systemd instance, so the user service this installer
// registers never runs -- and lingering, which would fix that, cannot be
// enabled when /var/lib/systemd is read-only, which those images usually are.
//
// What DOES run on such a machine is whatever launches the game. So the
// installer finds that file and starts the helper from it, immediately before
// the game. Nobody has to be told to edit anything.
//
// Rules this follows, because editing somebody's boot path is not a small
// thing to do on their behalf:
//
//   - Only files owned by the account the game runs as, and only ones that
//     actually mention ITGmania. A file that does not launch the game is none
//     of our business.
//   - A timestamped backup before the first byte changes.
//   - The inserted block is fenced with markers, so it can be found again,
//     replaced on upgrade rather than duplicated, and removed on uninstall.
//   - The block is an `if`, never a bare `cmd && cmd`: a failing `&&` list is
//     a non-zero status, and under `set -e` -- which a .xinitrc may well use --
//     that would abort the script and leave the cabinet with no game at all.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	launcherOpen  = "# >>> ITGMania Content Browser helper >>>"
	launcherClose = "# <<< ITGMania Content Browser helper <<<"
)

// launcherCandidates are the files that plausibly start a game at boot, most
// specific first. All of them live in the player's home, which is the part of
// a read-only cabinet image that is still writable.
func launcherCandidates(home string) []string {
	if home == "" {
		return nil
	}
	names := []string{
		".xinitrc",
		".xsession",
		".bash_profile",
		".bash_login",
		".profile",
		".zprofile",
		".zlogin",
		"start-itgmania.sh",
		"launch-itgmania.sh",
	}
	out := make([]string, 0, len(names))
	for _, n := range names {
		out = append(out, filepath.Join(home, n))
	}
	return out
}

// FindGameLauncher is the file that starts ITGmania on this machine, if one
// can be identified.
//
// "Mentions itgmania" is the whole test. It is deliberately loose -- cabinet
// images launch the game under all sorts of names and wrappers -- but it is
// anchored to files that are already a login or session entry point, so a
// stray mention somewhere else in the home directory cannot be mistaken for
// one.
func FindGameLauncher(inst Install) (string, bool) {
	for _, path := range launcherCandidates(autostartHome(inst)) {
		body, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if !strings.Contains(strings.ToLower(string(body)), "itgmania") {
			continue
		}
		return path, true
	}
	return "", false
}

// helperBlock is the fenced snippet inserted into a launcher.
func helperBlock(inst Install) string {
	var b strings.Builder
	b.WriteString(launcherOpen + "\n")
	b.WriteString("# Added by the ITGMania Content Browser installer.\n")
	b.WriteString("# Starts the local service the in-game browser needs. This machine\n")
	b.WriteString("# boots straight into the game, so nothing else would start it.\n")
	b.WriteString("# Removed again by running the installer with -uninstall.\n")
	b.WriteString("if [ -x " + quoteArg(HelperBinary(inst)) + " ]; then\n")
	b.WriteString("  " + quoteArg(HelperBinary(inst)) + " -helper -install-dir " +
		quoteArg(inst.Root) + " >/dev/null 2>&1 &\n")
	b.WriteString("fi\n")
	b.WriteString(launcherClose)
	return b.String()
}

// stripBlock removes a previously inserted block, returning the remaining
// lines and whether one was there.
func stripBlock(lines []string) ([]string, bool) {
	out := make([]string, 0, len(lines))
	inside, found := false, false
	for _, l := range lines {
		switch {
		case strings.TrimSpace(l) == launcherOpen:
			inside, found = true, true
			continue
		case strings.TrimSpace(l) == launcherClose:
			inside = false
			continue
		}
		if !inside {
			out = append(out, l)
		}
	}
	return out, found
}

// PatchLauncher inserts the helper start into the file that launches the game.
//
// The block goes immediately BEFORE the first line that mentions ITGmania,
// because that line commonly execs the game and nothing after an exec ever
// runs.
func PatchLauncher(inst Install) (path string, changed bool, err error) {
	path, ok := FindGameLauncher(inst)
	if !ok {
		return "", false, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return path, false, err
	}
	original := string(raw)
	nl := "\n"
	if strings.Contains(original, "\r\n") {
		nl = "\r\n"
	}
	lines := strings.Split(strings.ReplaceAll(original, "\r\n", "\n"), "\n")

	// An upgrade replaces its own block rather than stacking another one.
	lines, had := stripBlock(lines)

	insertAt := len(lines)
	for i, l := range lines {
		t := strings.TrimSpace(l)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		if strings.Contains(strings.ToLower(t), "itgmania") {
			insertAt = i
			break
		}
	}

	block := strings.Split(helperBlock(inst), "\n")
	updated := make([]string, 0, len(lines)+len(block)+1)
	updated = append(updated, lines[:insertAt]...)
	updated = append(updated, block...)
	updated = append(updated, "")
	updated = append(updated, lines[insertAt:]...)

	body := strings.Join(updated, nl)
	if body == original {
		return path, false, nil
	}

	if !had {
		// Only back up the first time we touch it; an upgrade replacing its own
		// block does not need a fresh copy of a file it already owns part of.
		backup := path + ".bak-" + time.Now().Format("20060102-150405")
		if err := os.WriteFile(backup, raw, 0o644); err != nil {
			return path, false, fmt.Errorf("backing up %s: %w", path, err)
		}
		chownLike(backup, path)
	}

	info, statErr := os.Stat(path)
	mode := os.FileMode(0o644)
	if statErr == nil {
		mode = info.Mode().Perm()
	}
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		return path, false, fmt.Errorf("writing %s: %w", path, err)
	}
	chownLike(path, filepath.Dir(path))
	return path, true, nil
}

// UnpatchLauncher takes the block back out again.
func UnpatchLauncher(inst Install) (string, bool) {
	for _, path := range launcherCandidates(autostartHome(inst)) {
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		original := string(raw)
		if !strings.Contains(original, launcherOpen) {
			continue
		}
		nl := "\n"
		if strings.Contains(original, "\r\n") {
			nl = "\r\n"
		}
		lines := strings.Split(strings.ReplaceAll(original, "\r\n", "\n"), "\n")
		lines, _ = stripBlock(lines)
		// The blank line the insert added back out again, so repeated
		// install/uninstall cycles do not grow the file.
		trimmed := make([]string, 0, len(lines))
		for i, l := range lines {
			if l == "" && i > 0 && i < len(lines)-1 && lines[i-1] == "" {
				continue
			}
			trimmed = append(trimmed, l)
		}
		info, statErr := os.Stat(path)
		mode := os.FileMode(0o644)
		if statErr == nil {
			mode = info.Mode().Perm()
		}
		if os.WriteFile(path, []byte(strings.Join(trimmed, nl)), mode) == nil {
			return path, true
		}
	}
	return "", false
}
