// Command mkmodulezip builds the in-game update payload and the manifest that
// describes it.
//
// The browser updates itself by fetching this archive and unpacking it over
// Themes/Simply Love/Modules/. It holds the same files the installer embeds, so
// a player who updates in game ends up with exactly what a fresh install would
// have given them.
//
// The archive is deterministic -- entries sorted, timestamps zeroed -- so
// rebuilding the same source twice produces the same bytes and so the same
// checksum. A release rebuilt to fix the build machine does not invalidate a
// manifest that was already published.
//
// Usage:
//
//	go run ./tools/mkmodulezip -version 0.2 -out dist
package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"itgmania-content-browser/internal/branding"
	"itgmania-content-browser/internal/update"
)

// payloadDir is what the installer embeds, relative to the repository root.
const payloadDir = "cmd/content-browser-installer/payload"

func main() {
	var (
		version = flag.String("version", branding.Version, "version being released")
		out     = flag.String("out", "dist", "directory to write into")
		src     = flag.String("payload", payloadDir, "payload directory to archive")
		baseURL = flag.String("url", "", "where the archive will be published (default: the GitHub release for this version)")
	)
	flag.Parse()

	if err := run(*version, *out, *src, *baseURL); err != nil {
		fmt.Fprintf(os.Stderr, "mkmodulezip: %v\n", err)
		os.Exit(1)
	}
}

func run(version, out, src, url string) error {
	name := branding.Slug + "-module-" + version + ".zip"
	if url == "" {
		url = "https://github.com/GRosewood/" + branding.Slug +
			"/releases/download/v" + version + "/" + name
	}

	blob, files, err := build(src)
	if err != nil {
		return err
	}
	verifyVersion = version
	if err := verify(blob); err != nil {
		return err
	}

	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	zipPath := filepath.Join(out, name)
	if err := os.WriteFile(zipPath, blob, 0o644); err != nil {
		return err
	}

	sum := sha256.Sum256(blob)
	var man update.Manifest
	man.Version = version
	man.Notes = ""
	man.Module.URL = url
	man.Module.SHA256 = hex.EncodeToString(sum[:])
	man.Module.Bytes = int64(len(blob))
	// Conservative by default: a release is assumed to want its own helper
	// until whoever cuts it says otherwise. Lowering it is a deliberate act,
	// and the wrong way round would hand players a module their helper cannot
	// serve.
	man.MinHelper = version

	raw, err := json.MarshalIndent(man, "", "  ")
	if err != nil {
		return err
	}
	manPath := filepath.Join(out, "update.json")
	if err := os.WriteFile(manPath, append(raw, '\n'), 0o644); err != nil {
		return err
	}

	fmt.Printf("  %s  (%d files, %d bytes)\n", zipPath, files, len(blob))
	fmt.Printf("  %s  sha256 %s\n", manPath, man.Module.SHA256)
	return nil
}

// build walks the payload and returns a deterministic archive of it.
//
// Paths inside the archive are relative to the payload's Modules directory,
// which is where they are unpacked -- so the archive holds "ITGmania Content
// Browser.lua" at its root rather than "Modules/ITGmania Content Browser.lua".
func build(src string) ([]byte, int, error) {
	root := filepath.Join(src, "Modules")
	if _, err := os.Stat(root); err != nil {
		return nil, 0, fmt.Errorf("payload: %w", err)
	}

	var names []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		names = append(names, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		return nil, 0, err
	}
	sort.Strings(names)

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(name)))
		if err != nil {
			return nil, 0, err
		}
		h := &zip.FileHeader{Name: name, Method: zip.Deflate}
		// A fixed timestamp rather than the file's: the archive should differ
		// only when its contents do. Zip cannot store a zero time, so this is
		// the earliest it can represent.
		h.Modified = time.Date(1980, 1, 1, 0, 0, 0, 0, time.UTC)
		h.SetMode(0o644)
		if strings.HasSuffix(name, ".sh") {
			h.SetMode(0o755)
		}
		w, err := zw.CreateHeader(h)
		if err != nil {
			return nil, 0, err
		}
		if _, err := w.Write(data); err != nil {
			return nil, 0, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, 0, err
	}
	return buf.Bytes(), len(names), nil
}

// verify reads the archive back the way the updater will, so a payload that
// the browser would reject never reaches a release.
func verify(blob []byte) error {
	zr, err := zip.NewReader(bytes.NewReader(blob), int64(len(blob)))
	if err != nil {
		return fmt.Errorf("the archive does not read back: %w", err)
	}
	found := false
	stamp := ""
	stampName := strings.TrimSuffix(update.ModuleFile, ".lua") + "/VERSION"
	for _, f := range zr.File {
		if path.Base(f.Name) == update.ModuleFile {
			found = true
		}
		if f.Name == stampName {
			rc, err := f.Open()
			if err != nil {
				return fmt.Errorf("the VERSION stamp does not open: %w", err)
			}
			raw, err := io.ReadAll(io.LimitReader(rc, 64))
			rc.Close()
			if err != nil {
				return fmt.Errorf("the VERSION stamp does not read: %w", err)
			}
			stamp = strings.TrimSpace(string(raw))
		}
		if !fs.ValidPath(f.Name) {
			return fmt.Errorf("the archive holds an unusable path: %q", f.Name)
		}
	}
	if !found {
		return fmt.Errorf("the archive does not contain %s", update.ModuleFile)
	}
	// The stamp is how a restarted helper knows what module is installed --
	// without it every module-only update re-offers itself forever. A release
	// whose stamp disagrees with the version being cut would plant that bug
	// on every machine that takes it, so it cannot be cut.
	if stamp == "" {
		return fmt.Errorf("the archive has no %s stamp", stampName)
	}
	// A dev build is not a release, and build.sh names it dev-<sha> precisely so
	// it cannot be mistaken for one -- which means the stamp can never match it.
	// Enforcing the match here anyway failed every ordinary push to main while
	// build.sh had already, deliberately, waived the same rule. Only the
	// equality is relaxed: the archive must still read back, still contain the
	// entry point, still carry a stamp, and still hold only usable paths.
	if isDevVersion(verifyVersion) {
		fmt.Printf("  (dev build: the payload stamp stays %q and is not checked "+
			"against %q -- this archive is not publishable)\n", stamp, verifyVersion)
		return nil
	}
	if stamp != verifyVersion {
		return fmt.Errorf("the VERSION stamp says %q but this release is %q -- "+
			"update the stamp in the payload", stamp, verifyVersion)
	}
	return nil
}

// isDevVersion matches the names build.sh gives a build that is not a release.
// The two must agree: build.sh exempts these from its own version-drift check,
// and a stricter rule here only moves the failure a few lines later.
func isDevVersion(v string) bool { return strings.HasPrefix(v, "dev-") }

// verifyVersion is what verify checks the stamp against; main sets it before
// verifying. A package-level variable rather than a parameter only to keep
// verify's signature stable for its test.
var verifyVersion string
