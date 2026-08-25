package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"itgmania-content-browser/internal/update"
)

// fakePayload builds the smallest tree mkmodulezip will accept: the entry file
// the updater looks for, and the VERSION stamp beside it.
func fakePayload(t *testing.T, stamp string) string {
	t.Helper()
	root := t.TempDir()
	modules := filepath.Join(root, "Modules")
	parts := filepath.Join(modules, strings.TrimSuffix(update.ModuleFile, ".lua"))
	if err := os.MkdirAll(parts, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(modules, update.ModuleFile),
		[]byte("-- entry point\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parts, "VERSION"),
		[]byte(stamp+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

// A release whose stamp disagrees with the version being cut must not be
// buildable. This is the check that stops the update-nag loop reaching players:
// a module stamped 0.1 published as 0.2 re-offers itself forever.
func TestReleaseWithMismatchedStampIsRefused(t *testing.T) {
	src := fakePayload(t, "0.1")
	err := run("0.2", t.TempDir(), src, "")
	if err == nil {
		t.Fatal("a release whose stamp says 0.1 was cut as 0.2")
	}
	if !strings.Contains(err.Error(), "VERSION stamp") {
		t.Errorf("unhelpful error for the case this exists to catch: %v", err)
	}
}

func TestReleaseWithMatchingStampIsBuilt(t *testing.T) {
	src := fakePayload(t, "0.2")
	if err := run("0.2", t.TempDir(), src, ""); err != nil {
		t.Fatalf("a correctly stamped release was refused: %v", err)
	}
}

// A dev build is stamped dev-<sha> by build.sh precisely so it cannot be
// mistaken for a release, which means the payload stamp can never match it.
// build.sh already waives its own drift check for these; enforcing the same
// rule here failed every ordinary push to main a few lines later.
func TestDevBuildIsNotHeldToTheStamp(t *testing.T) {
	src := fakePayload(t, "0.1")
	if err := run("dev-cdc76dc", t.TempDir(), src, ""); err != nil {
		t.Fatalf("a dev build was refused: %v", err)
	}
}

// Relaxing that one equality must not relax anything else: an archive missing
// the entry point is unusable whatever it is called.
func TestDevBuildStillNeedsTheEntryPoint(t *testing.T) {
	root := t.TempDir()
	parts := filepath.Join(root, "Modules", strings.TrimSuffix(update.ModuleFile, ".lua"))
	if err := os.MkdirAll(parts, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parts, "VERSION"), []byte("0.1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run("dev-cdc76dc", t.TempDir(), root, ""); err == nil {
		t.Fatal("a dev build with no entry point was accepted")
	}
}

// ...nor the stamp existing at all. Without it a restarted helper cannot tell
// what module is installed.
func TestDevBuildStillNeedsAStamp(t *testing.T) {
	root := t.TempDir()
	modules := filepath.Join(root, "Modules")
	if err := os.MkdirAll(modules, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(modules, update.ModuleFile),
		[]byte("-- entry point\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run("dev-cdc76dc", t.TempDir(), root, ""); err == nil {
		t.Fatal("a dev build with no VERSION stamp was accepted")
	}
}

func TestIsDevVersion(t *testing.T) {
	for _, v := range []string{"dev-cdc76dc", "dev-0000000"} {
		if !isDevVersion(v) {
			t.Errorf("%q should be a dev version", v)
		}
	}
	for _, v := range []string{"0.1", "1.0.0", "development", "", "v0.1"} {
		if isDevVersion(v) {
			t.Errorf("%q should NOT be a dev version", v)
		}
	}
}
