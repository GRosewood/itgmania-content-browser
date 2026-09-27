//go:build !windows

package installer

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Finding the image from an install: the start script in the player's home,
// and the songs drive by the mount its folder is on. /dev/shm stands in for
// /mnt/songs -- it is a separate mount on any Linux machine, which is the
// property that matters.
func TestFindSystemImage(t *testing.T) {
	if point, _ := mountOf("/dev/shm"); point != "/dev/shm" {
		t.Skip("/dev/shm is not a mount of its own here")
	}
	songs, err := os.MkdirTemp("/dev/shm", "songs-")
	if err != nil {
		t.Skip("cannot write /dev/shm:", err)
	}
	t.Cleanup(func() { os.RemoveAll(songs) })
	songs = filepath.Join(songs, "Songs")

	home := t.TempDir()
	escaped := strings.ReplaceAll(songs, "/", `\/`)
	script := strings.ReplaceAll(imageStart, `\/mnt\/songs\/Songs`, escaped)
	path := filepath.Join(home, "start.sh")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	inst := Install{GameUser: GameUser{Home: home}, SaveDir: filepath.Join(home, ".itgmania", "Save")}

	img, ok := FindSystemImage(inst)
	if !ok {
		t.Fatal("not found")
	}
	if img.StartScript != path || img.SongsDir != songs || img.MountPoint != "/dev/shm" || img.Writable {
		t.Fatalf("found %+v", img)
	}

	if _, err := MakeSongsDriveWritable(img); err != nil {
		t.Fatal(err)
	}
	if again, ok := FindSystemImage(inst); !ok || !again.Writable || again.SongsDir != songs {
		t.Fatalf("after the change: %+v %v", again, ok)
	}

	if where, ok := PutSongsDriveBack(inst); !ok || where != path {
		t.Fatalf("put back: %q %v", where, ok)
	}
	if now, _ := os.ReadFile(path); string(now) != script {
		t.Errorf("script not restored:\n%s", now)
	}
}
