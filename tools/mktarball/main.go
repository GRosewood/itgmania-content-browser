// Command mktarball wraps a built binary in a .tar.gz that carries its
// executable bit.
//
// A bare binary attached to a GitHub release loses its mode: the browser hands
// it over as a plain download, and the file arrives without +x. Every Linux
// and macOS user then has to be told to chmod it before it will run, which is
// a step people reasonably skip and then report as "the installer is broken".
// tar stores the mode, so extracting one produces something that just runs.
//
// The archive is deterministic -- fixed timestamp, fixed uid/gid, one entry --
// so rebuilding the same binary produces the same bytes.
//
// Usage:
//
//	go run ./tools/mktarball -in dist/foo-linux-amd64 -out dist/foo-linux-amd64.tar.gz
package main

import (
	"archive/tar"
	"compress/gzip"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func main() {
	in := flag.String("in", "", "the binary to wrap")
	out := flag.String("out", "", "the .tar.gz to write (default: <in>.tar.gz)")
	name := flag.String("name", "", "the name the file has inside the archive (default: base of -in)")
	flag.Parse()

	if *in == "" {
		fmt.Fprintln(os.Stderr, "mktarball: -in is required")
		os.Exit(2)
	}
	if *out == "" {
		*out = *in + ".tar.gz"
	}
	if *name == "" {
		*name = filepath.Base(*in)
	}
	if err := wrap(*in, *out, *name); err != nil {
		fmt.Fprintf(os.Stderr, "mktarball: %v\n", err)
		os.Exit(1)
	}
}

func wrap(in, out, name string) error {
	body, err := os.ReadFile(in)
	if err != nil {
		return err
	}

	f, err := os.Create(out)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()

	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)

	if err := tw.WriteHeader(&tar.Header{
		Name: name,
		// 0755 is the whole point of this tool.
		Mode:     0o755,
		Size:     int64(len(body)),
		Typeflag: tar.TypeReg,
		// Fixed metadata keeps the archive reproducible: the same binary in
		// gives the same archive out, whoever builds it and whenever.
		ModTime: time.Date(1980, 1, 1, 0, 0, 0, 0, time.UTC),
		Uid:     0,
		Gid:     0,
		Uname:   "root",
		Gname:   "root",
		Format:  tar.FormatGNU,
	}); err != nil {
		return err
	}
	if _, err := tw.Write(body); err != nil {
		return err
	}
	if err := tw.Close(); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}

	info, err := os.Stat(out)
	if err != nil {
		return err
	}
	fmt.Printf("  %s  (%s, mode 0755, %d bytes)\n", out, name, info.Size())
	return nil
}
