package installer

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// imageStart is shaped like the ITG System Image's ~/start.sh where it
// matters: the read-only remount first, the Preferences.ini lines forced on
// every start, the game, and the System Mode branch after it.
const imageStart = `#/bin/bash

PREF_LOC='/mnt/stepmania/Save/Preferences.ini'

#ensure we are mounted ro
sudo ~/utils/ro.sh

#force stepmania settings.
sed -i 's/LogFPS=.*/LogFPS=0/g' $PREF_LOC

#ensure we load AdditionalFolders
sed -i 's/AdditionalCourseFoldersReadOnly=.*/AdditionalCourseFoldersReadOnly=\/mnt\/songs\/Course/g' $PREF_LOC
sed -i 's/AdditionalSongFoldersReadOnly=.*/AdditionalSongFoldersReadOnly=\/mnt\/songs\/Songs/g' $PREF_LOC
sed -i 's/AdditionalFoldersWritable=.*/AdditionalFoldersWritable=\/mnt\/stepmania/g' $PREF_LOC
sed -i 's/AdditionalSongFoldersWritable=.*/AdditionalSongFoldersWritable=/g' $PREF_LOC

itgmania

if [ -z "$CAPS" ]
then
	exit 1
else
	sudo ~/utils/rw.sh
fi
`

var imageSongs = SystemImage{MountPoint: "/mnt/songs", SongsDir: "/mnt/songs/Songs"}

func TestParseImageScriptRecognisesTheImage(t *testing.T) {
	s, ok := parseImageScript(imageStart)
	if !ok {
		t.Fatal("not recognised")
	}
	if len(s.readOnly) != 1 || s.readOnly[0] != "/mnt/songs/Songs" {
		t.Errorf("read-only folders: %q", s.readOnly)
	}
	if got := splitLines(imageStart)[s.launch]; got != "itgmania" {
		t.Errorf("launch line is %q", got)
	}
}

// Only that script: a launcher that merely starts the game, or one whose
// pieces are in some other order, is somebody else's and is left alone.
func TestParseImageScriptLeavesOtherScriptsAlone(t *testing.T) {
	for name, body := range map[string]string{
		"plain launcher":   "#!/bin/sh\nexec /opt/itgmania/itgmania\n",
		"no remount":       strings.Replace(imageStart, "sudo ~/utils/ro.sh", "", 1),
		"no read-only sed": strings.Replace(imageStart, "AdditionalSongFoldersReadOnly", "Other", -1),
		"game before sed": strings.Replace(
			strings.Replace(imageStart, "\nitgmania\n", "\n", 1),
			"#ensure we load", "itgmania\n#ensure we load", 1),
	} {
		if _, ok := parseImageScript(body); ok {
			t.Errorf("%s: recognised as the image", name)
		}
	}
}

func TestSedValue(t *testing.T) {
	for line, want := range map[string]string{
		`sed -i 's/Key=.*/Key=\/mnt\/songs\/Songs/g' $PREF_LOC`: "/mnt/songs/Songs",
		`sed -i 's|Key=.*|Key=/a/b,/c|' "$PREF_LOC"`:            "/a/b,/c",
		`sed -i 's/Key=.*/Key=/g' $PREF_LOC`:                    "",
	} {
		got, ok := sedValue(line, "Key")
		if !ok || got != want {
			t.Errorf("%s: got %q %v, want %q", line, got, ok, want)
		}
	}
	if _, ok := sedValue(`sed -i 's/OtherKey=.*/OtherKey=x/g'`, "Key"); ok {
		t.Error("matched a different key")
	}
}

// The block goes after everything that forces the read-only setup and right
// before the game, and doing it twice changes nothing.
func TestSongsDriveBlockGoesJustBeforeTheGame(t *testing.T) {
	once, err := withSongsDriveBlock(imageStart, imageSongs)
	if err != nil {
		t.Fatal(err)
	}
	lines := splitLines(once)
	open, launch, lastSed := -1, -1, -1
	for i, l := range lines {
		switch {
		case l == songsDriveOpen:
			open = i
		case l == "itgmania":
			launch = i
		case strings.HasPrefix(l, "sed -i 's/Additional"):
			lastSed = i
		}
	}
	if open < 0 || open < lastSed || open > launch {
		t.Fatalf("block at %d, last sed at %d, game at %d:\n%s", open, lastSed, launch, once)
	}
	for _, want := range []string{
		"if sudo -n mount -o remount,rw '/mnt/songs'; then",
		`s|^AdditionalSongFoldersWritable=.*|AdditionalSongFoldersWritable=/mnt/songs/Songs|' "$PREF_LOC"`,
		`s|^AdditionalSongFoldersReadOnly=.*|AdditionalSongFoldersReadOnly=|' "$PREF_LOC"`,
	} {
		if !strings.Contains(once, want) {
			t.Errorf("block lacks %q", want)
		}
	}

	twice, err := withSongsDriveBlock(once, imageSongs)
	if err != nil {
		t.Fatal(err)
	}
	if twice != once {
		t.Errorf("a second run changed the script:\n%s", twice)
	}
	if n := strings.Count(twice, songsDriveOpen); n != 1 {
		t.Errorf("%d blocks", n)
	}

	back, found := withoutSongsDriveBlock(splitLines(once))
	if !found || strings.Join(back, "\n") != imageStart {
		t.Errorf("taking the block out did not give the script back:\n%s", strings.Join(back, "\n"))
	}
}

// Other read-only folders the script lists stay read-only.
func TestSongsDriveBlockKeepsOtherReadOnlyFolders(t *testing.T) {
	img := imageSongs
	img.OtherRO = "/mnt/extra/Songs"
	out, err := withSongsDriveBlock(imageStart, img)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "AdditionalSongFoldersReadOnly=/mnt/extra/Songs|") {
		t.Errorf("the other folder was dropped:\n%s", out)
	}
}

func TestSongsDriveBlockRefusesWhatItCannotWriteSafely(t *testing.T) {
	for name, img := range map[string]SystemImage{
		"quote in path":        {MountPoint: "/mnt/so'ngs", SongsDir: "/mnt/so'ngs/Songs"},
		"sed metacharacter":    {MountPoint: "/mnt/songs", SongsDir: "/mnt/songs/S|ongs"},
		"root filesystem":      {MountPoint: "/", SongsDir: "/songs"},
		"folder off the mount": {MountPoint: "/mnt/songs", SongsDir: "/mnt/other/Songs"},
	} {
		if _, err := withSongsDriveBlock(imageStart, img); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestSongsDriveBlockKeepsCRLF(t *testing.T) {
	crlf := strings.ReplaceAll(imageStart, "\n", "\r\n")
	out, err := withSongsDriveBlock(crlf, imageSongs)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(out, "\n") != strings.Count(out, "\r\n") {
		t.Error("line endings were mixed")
	}
}

// The file itself: a copy kept the first time it changes, none when nothing
// needs changing, and the block taken out again on uninstall.
func TestMakeSongsDriveWritableEditsTheScriptInPlace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "start.sh")
	if err := os.WriteFile(path, []byte(imageStart), 0o755); err != nil {
		t.Fatal(err)
	}
	img := imageSongs
	img.StartScript = path

	backup, err := MakeSongsDriveWritable(img)
	if err != nil {
		t.Fatal(err)
	}
	if kept, _ := os.ReadFile(backup); string(kept) != imageStart {
		t.Errorf("backup %s does not hold the original", backup)
	}
	if now, _ := os.ReadFile(path); !strings.Contains(string(now), songsDriveOpen) {
		t.Fatal("block not written")
	}
	if runtime.GOOS != "windows" {
		if info, _ := os.Stat(path); info.Mode().Perm() != 0o755 {
			t.Errorf("mode became %o", info.Mode().Perm())
		}
	}

	again, err := MakeSongsDriveWritable(img)
	if err != nil || again != "" {
		t.Errorf("second run: backup %q, err %v -- want no change", again, err)
	}

	removed, err := removeSongsDriveBlock(path)
	if err != nil || !removed {
		t.Fatalf("removing: %v %v", removed, err)
	}
	if now, _ := os.ReadFile(path); string(now) != imageStart {
		t.Errorf("uninstall did not restore the script:\n%s", now)
	}
}

// What the block does when the image runs it: with the remount working, the
// songs drive becomes the writable song folder; with it failing, the image's
// read-only setup stands untouched. Run by bash itself against a Preferences.ini
// shaped like the image's -- CRLF, except the lines its own sed has touched.
func TestSongsDriveBlockUnderBash(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("needs a POSIX shell and sed")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash")
	}
	patched, err := withSongsDriveBlock(imageStart, imageSongs)
	if err != nil {
		t.Fatal(err)
	}
	// the whole script still parses
	script := filepath.Join(t.TempDir(), "start.sh")
	if err := os.WriteFile(script, []byte(patched), 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(bash, "-n", script).CombinedOutput(); err != nil {
		t.Fatalf("bash -n: %v\n%s", err, out)
	}

	block := strings.Join(songsDriveBlock(imageSongs.MountPoint, imageSongs.SongsDir, ""), "\n")
	const prefs = "[Options]\r\n" +
		"AdditionalFoldersWritable=/mnt/stepmania\n" +
		"AdditionalSongFoldersReadOnly=/mnt/songs/Songs\n" +
		"AdditionalSongFoldersWritable=\n" +
		"Theme=Simply-Love-SM5\r\n"

	for _, tc := range []struct {
		sudoExit string
		want     []string
	}{
		{"0", []string{"AdditionalSongFoldersReadOnly=\n", "AdditionalSongFoldersWritable=/mnt/songs/Songs\n"}},
		{"1", []string{"AdditionalSongFoldersReadOnly=/mnt/songs/Songs\n", "AdditionalSongFoldersWritable=\n"}},
	} {
		dir := t.TempDir()
		stub := filepath.Join(dir, "sudo")
		if err := os.WriteFile(stub, []byte("#!/bin/sh\nexit "+tc.sudoExit+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		pref := filepath.Join(dir, "Preferences.ini")
		if err := os.WriteFile(pref, []byte(prefs), 0o644); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(bash, "-c", "PREF_LOC='"+pref+"'\n"+block)
		cmd.Env = append(os.Environ(), "PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"))
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("sudo exits %s: %v\n%s", tc.sudoExit, err, out)
		}
		got, _ := os.ReadFile(pref)
		for _, w := range tc.want {
			if !strings.Contains(string(got), w) {
				t.Errorf("sudo exits %s: %q missing from\n%q", tc.sudoExit, w, got)
			}
		}
		if !strings.Contains(string(got), "Theme=Simply-Love-SM5\r\n") {
			t.Errorf("sudo exits %s: an unrelated line changed: %q", tc.sudoExit, got)
		}
	}
}

func TestRecordInstall(t *testing.T) {
	inst := Install{SaveDir: t.TempDir()}
	path := filepath.Join(HelperDir(inst), "installer.txt")

	if err := RecordInstall(inst, "0.9", "writable"); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != "version 0.9\nsongs-drive writable\n" {
		t.Errorf("got %q", got)
	}
	// off the image there is nothing to say about a songs drive
	if err := RecordInstall(inst, "0.9", ""); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != "version 0.9\n" {
		t.Errorf("got %q", got)
	}
}
