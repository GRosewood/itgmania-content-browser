package installer

// The ITG System Image, and its songs drive.
//
// dinsfire64's ITG System Image is a turnkey cabinet OS: ITGmania in
// /opt/itgmania, the player's profile on a read-only root partition, custom
// files on /mnt/stepmania, and the song library on its own partition,
// /mnt/songs. Every time the game starts, ~/start.sh runs first, and among
// other things it
//
//	sudo ~/utils/ro.sh                     remounts / and /mnt/songs read-only
//	sed ... AdditionalSongFoldersReadOnly=/mnt/songs/Songs    in Preferences.ini
//	sed ... AdditionalSongFoldersWritable=
//	sed ... AdditionalFoldersWritable=/mnt/stepmania
//
// So the game treats the songs drive as read-only twice over, and the only
// place it may write is the /mnt/stepmania tree: a pack downloaded in the game
// lands in /mnt/stepmania/Songs, while the drive meant for songs sits
// untouched. That is the image's design -- the library survives the cabinet
// being switched off at the wall -- so changing it is the player's choice.
//
// Choosing it adds one fenced block to start.sh, just before the line that
// starts the game, where it runs after all of the above: remount the songs
// drive read-write, and only if that worked, list the song folder as writable
// instead of read-only. The engine mounts song folders after whole trees and
// gives a new pack to the newest mount, so downloads then land on the songs
// drive. If the remount fails, nothing else changes and the image's own
// read-only setup stands.
//
// The block lives on the image's root partition, which an image update
// replaces -- the same update that takes this module out of the theme -- so
// running the installer again after an update puts both back.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	songsDriveOpen  = "# >>> ITGMania Content Browser: songs drive writable during play >>>"
	songsDriveClose = "# <<< ITGMania Content Browser: songs drive writable during play <<<"
)

// SystemImage is what the installer found of the ITG System Image.
type SystemImage struct {
	StartScript string // the script that starts the game at boot
	SongsDir    string // the song folder it lists read-only: /mnt/songs/Songs
	OtherRO     string // anything else it lists read-only, which stays that way
	MountPoint  string // the filesystem SongsDir is on: /mnt/songs
	Writable    bool   // the block is in the script already
}

// imageScript is what a start script says, when it is the image's.
type imageScript struct {
	readOnly []string // AdditionalSongFoldersReadOnly, as its sed line sets it
	launch   int      // the line that starts the game
}

// A line that starts the game: the command itself, possibly by path, possibly
// exec'd. Comments do not count.
var launchLine = regexp.MustCompile(`^\s*(exec\s+)?(\S*/)?itgmania(\s|$)`)

// parseImageScript recognises the image's start script. All of it has to be
// there -- the read-only remount, the Preferences.ini it edits, the sed line
// that lists the songs drive read-only, and the game starting after that line
// -- because the block only makes sense in exactly that script.
func parseImageScript(body string) (imageScript, bool) {
	var s imageScript
	if !strings.Contains(body, "utils/ro.sh") || !strings.Contains(body, "PREF_LOC=") {
		return s, false
	}
	lines := splitLines(body)
	sedAt := -1
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if v, ok := sedValue(line, "AdditionalSongFoldersReadOnly"); ok {
			s.readOnly = splitList(v)
			sedAt = i
		}
	}
	if sedAt < 0 || len(s.readOnly) == 0 {
		return s, false
	}
	s.launch = -1
	for i := sedAt + 1; i < len(lines); i++ {
		if launchLine.MatchString(lines[i]) {
			s.launch = i
			break
		}
	}
	return s, s.launch >= 0
}

// sedValue reads the value a sed substitution gives a preference, from a line
// shaped like the image's own:
//
//	sed -i 's/Key=.*/Key=\/some\/path/g' $PREF_LOC
func sedValue(line, key string) (string, bool) {
	i := strings.Index(line, "s")
	for ; i >= 0 && i+1 < len(line); i = nextIndex(line, "s", i+1) {
		delim := line[i+1]
		head := key + "=.*" + string(delim) + key + "="
		if !strings.HasPrefix(line[i+2:], head) {
			continue
		}
		rest := line[i+2+len(head):]
		var val strings.Builder
		for j := 0; j < len(rest); j++ {
			switch {
			case rest[j] == '\\' && j+1 < len(rest):
				j++
				val.WriteByte(rest[j])
			case rest[j] == delim:
				return strings.TrimSpace(val.String()), true
			default:
				val.WriteByte(rest[j])
			}
		}
		return "", false
	}
	return "", false
}

func nextIndex(s, sub string, from int) int {
	if from >= len(s) {
		return -1
	}
	j := strings.Index(s[from:], sub)
	if j < 0 {
		return -1
	}
	return from + j
}

func splitList(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func splitLines(body string) []string {
	return strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n")
}

// safeForScript is a path that can go into a shell single-quoted string and a
// sed replacement unescaped: nothing that either would read as syntax.
var safeForScript = regexp.MustCompile(`^[A-Za-z0-9 _./,+:@-]*$`)

// songsDriveBlock is the text that goes into the script.
func songsDriveBlock(mount, songs, otherRO string) []string {
	return []string{
		songsDriveOpen,
		"# Added by the ITGMania Content Browser installer, so that packs downloaded",
		"# in the game land on the songs drive. If the remount fails nothing below",
		"# changes, and the drive stays read-only as the image intends. Delete this",
		"# block, or run that installer with -uninstall, to put the image's own",
		"# read-only songs drive back.",
		"if sudo -n mount -o remount,rw '" + mount + "'; then",
		"\tsed -i 's|^AdditionalSongFoldersReadOnly=.*|AdditionalSongFoldersReadOnly=" + otherRO + "|' \"$PREF_LOC\"",
		"\tsed -i 's|^AdditionalSongFoldersWritable=.*|AdditionalSongFoldersWritable=" + songs + "|' \"$PREF_LOC\"",
		"fi",
		songsDriveClose,
	}
}

// withoutSongsDriveBlock takes the block out, and the blank line that was put
// after it, reporting whether it was there.
func withoutSongsDriveBlock(lines []string) ([]string, bool) {
	out := make([]string, 0, len(lines))
	inside, found, skipBlank := false, false, false
	for _, l := range lines {
		switch t := strings.TrimSpace(l); {
		case t == songsDriveOpen:
			inside, found = true, true
			continue
		case t == songsDriveClose:
			inside, skipBlank = false, true
			continue
		case inside:
			continue
		case skipBlank:
			skipBlank = false
			if t == "" {
				continue
			}
		}
		out = append(out, l)
	}
	return out, found
}

// withSongsDriveBlock is the script with the block in it, just before the line
// that starts the game. A block already there is replaced, not doubled.
func withSongsDriveBlock(body string, img SystemImage) (string, error) {
	for _, p := range []string{img.MountPoint, img.SongsDir, img.OtherRO} {
		if !safeForScript.MatchString(p) {
			return "", fmt.Errorf("%q cannot be written into start.sh safely", p)
		}
	}
	// These are paths on the cabinet, so they are checked as such whatever
	// machine this runs on: absolute, a mount of its own, and holding the folder.
	if !strings.HasPrefix(img.MountPoint, "/") || img.MountPoint == "/" ||
		!strings.HasPrefix(img.SongsDir, strings.TrimSuffix(img.MountPoint, "/")+"/") {
		return "", fmt.Errorf("%s is not on a drive of its own (%q)", img.SongsDir, img.MountPoint)
	}
	nl := "\n"
	if strings.Contains(body, "\r\n") {
		nl = "\r\n"
	}
	lines, _ := withoutSongsDriveBlock(splitLines(body))
	s, ok := parseImageScript(strings.Join(lines, "\n"))
	if !ok {
		return "", fmt.Errorf("could not find where the script starts the game")
	}
	block := append(songsDriveBlock(img.MountPoint, img.SongsDir, img.OtherRO), "")
	out := make([]string, 0, len(lines)+len(block))
	out = append(out, lines[:s.launch]...)
	out = append(out, block...)
	out = append(out, lines[s.launch:]...)
	return strings.Join(out, nl), nil
}

// MakeSongsDriveWritable puts the block into the image's start script, or
// brings one already there up to date. The script is changed in place -- it
// keeps its owner and mode -- after a timestamped copy is kept beside it.
// Returns the copy's path, empty when nothing needed changing.
func MakeSongsDriveWritable(img SystemImage) (string, error) {
	path := img.StartScript
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if readOnlyFS(path) {
		return "", fmt.Errorf("%s is on a read-only filesystem%s", path, systemModeHint)
	}
	next, err := withSongsDriveBlock(string(raw), img)
	if err != nil {
		return "", err
	}
	if next == string(raw) {
		return "", nil
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	backup := path + ".bak-" + time.Now().Format("20060102-150405")
	if err := os.WriteFile(backup, raw, info.Mode().Perm()); err != nil {
		return "", fmt.Errorf("keeping a copy of %s: %w", path, err)
	}
	chownLike(backup, path)
	if err := os.WriteFile(path, []byte(next), info.Mode().Perm()); err != nil {
		return "", fmt.Errorf("writing %s: %w", path, err)
	}
	return backup, nil
}

// removeSongsDriveBlock takes the block out of a script, in place. It reports
// whether there was one.
func removeSongsDriveBlock(path string) (bool, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	nl := "\n"
	if strings.Contains(string(raw), "\r\n") {
		nl = "\r\n"
	}
	lines, found := withoutSongsDriveBlock(splitLines(string(raw)))
	if !found {
		return false, nil
	}
	info, err := os.Stat(path)
	if err != nil {
		return false, err
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, nl)), info.Mode().Perm()); err != nil {
		return false, err
	}
	return true, nil
}

// systemModeHint says how to get a writable root partition on the image.
const systemModeHint = "; on the ITG System Image that partition is only writable in" +
	" System Mode -- turn Caps Lock on, press Alt+F4 to quit the game, and run" +
	" this again from there"

// RecordInstall notes what the installer last did on this machine, beside
// the browser's saved state (installer.txt), where the game can read it: its
// version, and on the ITG System Image whether the songs drive was made
// writable during play ("writable") or left as the image has it ("read-only").
//
// The in-game updater brings a new module and nothing else, so a release that
// needs the installer to change something on the machine has to be able to
// tell, from inside the game, whether that happened. An installer from before
// the songs drive could be changed leaves no record at all -- which is exactly
// the machine that needs telling.
func RecordInstall(inst Install, version, songsDrive string) error {
	dir := HelperDir(inst)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	chownToGameUser(dir, inst.GameUser)
	body := "version " + version + "\n"
	if songsDrive != "" {
		body += "songs-drive " + songsDrive + "\n"
	}
	path := filepath.Join(dir, "installer.txt")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return err
	}
	chownToGameUser(path, inst.GameUser)
	return nil
}
