package installer

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// prefsInstall is an install whose Preferences.ini [Options] holds lines, with
// every folder those lines name made for real (a tree gets its Songs/), since
// folders that do not exist are not reported.
func prefsInstall(t *testing.T, lines ...string) Install {
	t.Helper()
	root := t.TempDir()
	save := filepath.Join(root, "Save")
	if err := os.MkdirAll(save, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, line := range lines {
		key, value, _ := strings.Cut(line, "=")
		for _, dir := range strings.Split(value, ",") {
			if dir == "" {
				continue
			}
			if strings.HasPrefix(key, "AdditionalFolders") {
				dir = filepath.Join(dir, "Songs")
			}
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
		}
	}
	body := "[Options]\r\n" + strings.Join(lines, "\r\n") + "\r\n"
	if err := os.WriteFile(filepath.Join(save, "Preferences.ini"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return Install{Root: root, SaveDir: save}
}

func dirs(libs []Library) []string {
	var out []string
	for _, lib := range libs {
		out = append(out, lib.Dir)
	}
	return out
}

// The order the engine tries folders in for a new pack -- newest mount first,
// song folders mounted after trees -- with the read-only ones, which it never
// tries, at the end.
func TestLibrariesAreInTheOrderTheGameTriesThem(t *testing.T) {
	base := t.TempDir()
	a, b := filepath.Join(base, "a"), filepath.Join(base, "b")
	t1, t2 := filepath.Join(base, "t1"), filepath.Join(base, "t2")
	ro := filepath.Join(base, "ro")
	inst := prefsInstall(t,
		"AdditionalSongFoldersWritable="+a+","+b,
		"AdditionalFoldersWritable="+t1+","+t2,
		"AdditionalSongFoldersReadOnly="+ro)

	libs := Libraries(inst)
	want := []string{b, a, filepath.Join(t2, "Songs"), filepath.Join(t1, "Songs"), ro}
	if got := dirs(libs); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("order:\n got %v\nwant %v", got, want)
	}
	if !libs[4].ReadOnlyPref || libs[0].ReadOnlyPref || !libs[2].Tree {
		t.Errorf("kinds wrong: %+v", libs)
	}
	if got := DownloadsGoTo(inst, libs); got != b {
		t.Errorf("downloads go to %s, want %s", got, b)
	}
}

// The ITG System Image as shipped: the songs drive read-only to the game, the
// data partition a writable tree. The tree is where downloads go -- the
// behaviour that started all this, reproduced on the engine itself.
func TestDownloadsGoToTheTreeWhenTheSongFolderIsReadOnly(t *testing.T) {
	base := t.TempDir()
	songs := filepath.Join(base, "songs", "Songs")
	tree := filepath.Join(base, "stepmania")
	inst := prefsInstall(t,
		"AdditionalSongFoldersReadOnly="+songs,
		"AdditionalSongFoldersWritable=",
		"AdditionalFoldersWritable="+tree)

	libs := Libraries(inst)
	if got, want := DownloadsGoTo(inst, libs), filepath.Join(tree, "Songs"); got != want {
		t.Fatalf("downloads go to %s, want %s", got, want)
	}

	// ...and once the image's start script lists the drive writable, the drive
	// takes them, ahead of the tree
	after := WithWritableSongs(libs, songs)
	if got := DownloadsGoTo(inst, after); got != songs {
		t.Errorf("after the change downloads go to %s, want %s", got, songs)
	}
	if !after[0].Pending || after[0].Dir != songs {
		t.Errorf("the drive should lead, pending the next start: %+v", after)
	}
	if len(after) != len(libs) {
		t.Errorf("a folder was lost or doubled: %v -> %v", dirs(libs), dirs(after))
	}
}

func TestWithWritableSongsLeavesAWritableFolderAlone(t *testing.T) {
	libs := []Library{{Dir: "/a"}, {Dir: "/b", ReadOnlyPref: true}}
	if got := WithWritableSongs(libs, "/a"); strings.Join(dirs(got), "|") != "/a|/b" || got[0].Pending {
		t.Errorf("got %+v", got)
	}
}

// With nothing the game may write to, a download goes to its own Songs.
func TestDownloadsGoToTheGamesOwnSongsWhenNothingElseIsWritable(t *testing.T) {
	inst := prefsInstall(t, "AdditionalSongFoldersReadOnly="+filepath.Join(t.TempDir(), "ro"))
	if got, want := DownloadsGoTo(inst, Libraries(inst)), OwnSongsDir(inst); got != want {
		t.Errorf("got %s, want %s", got, want)
	}
}

// A writable folder on a filesystem mounted read-only is passed over; the
// next one the game may write to gets the pack.
func TestDownloadsFallBackPastAReadOnlyFilesystem(t *testing.T) {
	inst := Install{Root: "root", Portable: true}
	libs := []Library{
		{Dir: "/songs", ReadOnlyFS: true},
		{Dir: "/ro", ReadOnlyPref: true},
		{Dir: "/also-ro-fs", ReadOnlyFS: true},
		{Dir: "/tree/Songs", Tree: true},
	}
	if got := DownloadsFallBackTo(inst, libs); got != "/tree/Songs" {
		t.Errorf("got %s", got)
	}
	if got := DownloadsFallBackTo(inst, libs[:1]); got != OwnSongsDir(inst) {
		t.Errorf("with nothing after it: got %s", got)
	}
}

// Nothing listed, nothing to say.
func TestLibrariesWithNoFoldersListed(t *testing.T) {
	inst := prefsInstall(t, "AdditionalSongFoldersWritable=", "AdditionalFoldersWritable=")
	if libs := Libraries(inst); len(libs) != 0 {
		t.Errorf("got %+v, want none", libs)
	}
}

// Where a download goes when nothing the player listed takes it.
func TestOwnSongsDir(t *testing.T) {
	root := filepath.Join("games", "itgmania")
	portable := Install{Root: root, SaveDir: filepath.Join(root, "Save"), Portable: true}
	if got, want := OwnSongsDir(portable), filepath.Join(root, "Songs"); got != want {
		t.Errorf("portable: got %s, want %s", got, want)
	}
	profile := filepath.Join("home", "dance", ".itgmania")
	installed := Install{Root: root, SaveDir: filepath.Join(profile, "Save")}
	if got, want := OwnSongsDir(installed), filepath.Join(profile, "Songs"); got != want {
		t.Errorf("installed: got %s, want %s", got, want)
	}
}
