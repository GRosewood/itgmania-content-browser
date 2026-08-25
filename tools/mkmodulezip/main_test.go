package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
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

// -verify exists because the checksum in a manifest and the bytes on the
// release come from two different machines, and until this nothing compared
// them. A mismatch is invisible until a player is told their download is
// corrupt, so these pin both directions.

func manifestFor(t *testing.T, url, sha string, bytes int64) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "update.json")
	body := `{"version":"0.2","notes":"","module":{"url":"` + url +
		`","sha256":"` + sha + `","bytes":` + strconv.FormatInt(bytes, 10) +
		`},"minHelper":"0.1"}`
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func servePayload(t *testing.T, payload []byte, status int) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		_, _ = w.Write(payload)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestVerifyAcceptsAMatchingManifest(t *testing.T) {
	payload := []byte("the published archive")
	sum := sha256.Sum256(payload)
	p := manifestFor(t, servePayload(t, payload, 200), hex.EncodeToString(sum[:]), int64(len(payload)))
	if err := verifyManifest(p, false); err != nil {
		t.Fatalf("a correct manifest was rejected: %v", err)
	}
}

// The exact failure that shipped: identical-looking release, different bytes.
func TestVerifyRejectsAMismatchedManifest(t *testing.T) {
	p := manifestFor(t, servePayload(t, []byte("what is actually published"), 200),
		"0000000000000000000000000000000000000000000000000000000000000000", 999)
	err := verifyManifest(p, false)
	if err == nil {
		t.Fatal("a manifest that no player could match was accepted")
	}
	if !strings.Contains(err.Error(), "does not match") {
		t.Errorf("unhelpful error: %v", err)
	}
}

func TestVerifyFixRewritesTheManifest(t *testing.T) {
	payload := []byte("what is actually published")
	sum := sha256.Sum256(payload)
	want := hex.EncodeToString(sum[:])

	p := manifestFor(t, servePayload(t, payload, 200),
		"0000000000000000000000000000000000000000000000000000000000000000", 999)
	if err := verifyManifest(p, true); err != nil {
		t.Fatalf("-fix failed: %v", err)
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var man update.Manifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatalf("-fix wrote something unparseable: %v", err)
	}
	if man.Module.SHA256 != want {
		t.Errorf("sha = %s, want %s", man.Module.SHA256, want)
	}
	if man.Module.Bytes != int64(len(payload)) {
		t.Errorf("bytes = %d, want %d", man.Module.Bytes, len(payload))
	}
	// -fix must repair the checksum and nothing else.
	if man.Version != "0.2" || man.MinHelper != "0.1" {
		t.Errorf("-fix disturbed the rest of the manifest: %+v", man)
	}
	// ...and the result must now verify.
	if err := verifyManifest(p, false); err != nil {
		t.Errorf("manifest still wrong after -fix: %v", err)
	}
}

// Uploading is the step people forget; say so rather than reporting a checksum
// mismatch against nothing.
func TestVerifySaysWhenNothingIsPublished(t *testing.T) {
	p := manifestFor(t, servePayload(t, nil, http.StatusNotFound),
		"0000000000000000000000000000000000000000000000000000000000000000", 1)
	err := verifyManifest(p, false)
	if err == nil {
		t.Fatal("a missing release asset was accepted")
	}
	if !strings.Contains(err.Error(), "Upload") {
		t.Errorf("error should point at the missing upload: %v", err)
	}
}
