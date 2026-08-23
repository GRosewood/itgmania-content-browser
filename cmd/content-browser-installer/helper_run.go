package main

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"itgmania-content-browser/internal/helper"
	"itgmania-content-browser/internal/installer"
	"itgmania-content-browser/internal/preview"
)

// runHelper is the -helper mode: the loopback service that deletes packs on
// behalf of the in-game browser.
//
// The game can make HTTP requests but cannot delete a file, so this is the
// other half of the Installed Packs screen. It is started as a login item and
// exits when its published config file is removed, which is how the installer
// stops it on uninstall.
func runHelper(target string) int {
	hideConsole()

	var inst installer.Install
	if target != "" {
		found, ok := installer.Inspect(target)
		if !ok {
			fmt.Fprintf(os.Stderr, "helper: %s is not an ITGmania installation\n", target)
			return 1
		}
		inst = found
	} else {
		installs := installer.Discover()
		if len(installs) == 0 {
			fmt.Fprintln(os.Stderr, "helper: no ITGmania installation found")
			return 1
		}
		inst = installs[0]
	}

	srv, err := helper.New(inst.SaveDir, version,
		func(pack string) (string, error) {
			return installer.RemovePack(inst, pack)
		},
		func() ([]string, error) {
			return installer.TidyProbeFiles(inst)
		})
	if err != nil {
		fmt.Fprintf(os.Stderr, "helper: %v\n", err)
		return 1
	}

	// Song previews. These live under the browser's own data directory rather
	// than anywhere the game scans, so an extracted song can never be mistaken
	// for an installed one.
	previews := preview.New(
		filepath.Join(inst.SaveDir, "ITGmaniaContentBrowser", "previews"),
		"https://stepmaniaonline.net")
	previews.Clear() // anything left behind by a previous run is stale
	srv.SetPreviewer(func(packID int, song string) (any, error) {
		return previews.Get(packID, song)
	})
	srv.SetReporter(func() any { return previews.Progress() })

	// Two ways to stop: a signal, or the config file going away (which is what
	// the uninstaller does, and what a second helper instance would cause).
	done := make(chan struct{})
	var once sync.Once
	stop := func() { once.Do(func() { close(done) }) }

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		stop()
	}()
	// Two things end this helper's life: the config file going away (what the
	// uninstaller does) and the config carrying someone else's token (what an
	// upgrade does, since the replacement publishes over us). Without the
	// second check an old helper lingers holding its own binary open.
	go func() {
		for {
			select {
			case <-done:
				return
			case <-time.After(2 * time.Second):
				cfg, err := helper.ReadConfig(inst.SaveDir)
				if err != nil || cfg.Token != srv.Token() {
					stop()
					return
				}
			}
		}
	}()
	go func() {
		<-done
		previews.Clear()
		srv.Close()
	}()

	fmt.Printf("helper listening on 127.0.0.1:%d for %s\n", srv.Port(), inst.Root)
	if err := srv.Serve(); err != nil {
		fmt.Fprintf(os.Stderr, "helper: %v\n", err)
		return 1
	}
	return 0
}
