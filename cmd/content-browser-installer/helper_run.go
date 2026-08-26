package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"sync"
	"syscall"
	"time"

	"itgmania-content-browser/internal/branding"
	"itgmania-content-browser/internal/helper"
	"itgmania-content-browser/internal/installer"
	"itgmania-content-browser/internal/packs"
	"itgmania-content-browser/internal/preview"
	"itgmania-content-browser/internal/update"
)

// runHelper is the -helper mode: the loopback service that deletes packs on
// behalf of the in-game browser.
//
// The game can make HTTP requests but cannot delete a file, so this is the
// other half of the Installed Packs screen. It is started as a login item and
// exits when its published config file is removed, which is how the installer
// stops it on uninstall.
// manifestURL is where update news is read from. It is a parameter so a fork
// can point at its own, and so this can be tested against a local file without
// publishing anything.
func runHelper(target, manifestURL string) int {
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

	// Song previews. These live under the game's Cache directory -- they are
	// refetchable bytes, which is what Cache is for, and on a cabinet Cache is
	// the folder that sits on the big mounted drive. Nowhere the game scans
	// for songs, so an extracted song can never be mistaken for an installed
	// one; and the game reads the same folder from the inside as /Cache, so
	// wherever the mount really points, both ends land on the same files.
	//
	// If Cache cannot be written the game itself is broken -- the engine keeps
	// its own song cache there -- so that is reported and previews are let
	// fail loudly rather than quietly kept somewhere the game will not look.
	cacheDir, err := installer.CacheDir(inst)
	if err != nil {
		fmt.Fprintf(os.Stderr, "helper: %v (previews will not work)\n", err)
		cacheDir = filepath.Join(filepath.Dir(inst.SaveDir), "Cache")
	}
	previews := preview.New(
		filepath.Join(cacheDir, "ITGmaniaContentBrowser", "previews"),
		"https://stepmaniaonline.net")
	previews.Clear() // anything left behind by a previous run is stale

	// Earlier releases kept previews and the banner art under Save. Nothing on
	// the update path deletes a file, and the game cannot, so this helper is
	// the one thing that can retire those folders -- megabytes of artwork the
	// browser will never look at again. Both paths are wholly this project's
	// own, by name.
	os.RemoveAll(filepath.Join(inst.SaveDir, "ITGmaniaContentBrowser", "previews"))
	os.RemoveAll(filepath.Join(inst.SaveDir, "SMOFindContent"))
	srv.SetPreviewer(func(packID int, song string) (any, error) {
		return previews.Get(packID, song)
	})
	srv.SetReporter(func() any { return previews.Progress() })

	// Installs go to the folder the player configured, which the engine's own
	// unzip cannot be told to use. The root is resolved per install rather than
	// now: a drive can be mounted long after this helper started.
	installs := packs.New(
		func() (string, error) { return installer.InstallRoot(inst) },
		"https://stepmaniaonline.net")
	// One song is lifted straight out of the pack archive over ranged reads --
	// the same index the audio previews already built -- so taking one song from
	// a four gigabyte pack costs about what that song weighs.
	installs.InstallSong = func(packID int, title, root, sync string) (any, error) {
		return previews.InstallSong(packID, title, root, sync)
	}
	srv.SetInstaller(installs.Start, func() any { return installs.Status() })
	srv.SetSongInstaller(installs.StartSong)
	srv.SetPackIniReader(func(packID int) (any, error) {
		return previews.PackIni(packID)
	})
	srv.SetPackModsReader(func(packID int) (any, error) {
		return previews.PackMods(packID)
	})
	srv.SetPackCreditsReader(func(packID int) (any, error) {
		return previews.PackCredits(packID)
	})
	// The install root is resolved per call rather than now: a drive can be
	// mounted, filled or swapped long after this helper started.
	srv.SetSpaceReader(func() (int64, string, bool) {
		root, err := installer.InstallRoot(inst)
		if err != nil || root == "" {
			return 0, "", false
		}
		free, ok := installer.FreeBytes(root)
		return free, root, ok
	})

	// Updates. The helper checks and applies them because it is the half of
	// this that can reach any host and write any file; the game only asks.
	//
	// It replaces the module, not itself: this binary is the one running, and
	// on Windows a running executable cannot be overwritten. A release that
	// needs a newer helper says so in its manifest, and the browser then points
	// at the installer instead of pretending it can finish the job.
	if manifestURL == "" {
		manifestURL = branding.UpdateManifest
	}
	// The theme is resolved by finding the installed module, not by name: a
	// player on a renamed Simply Love fork has the module in the fork, and an
	// update written into a folder that merely shares the stock name would
	// report success while changing nothing the player can see.
	updates := update.New(
		manifestURL, version,
		filepath.Join(inst.ModuleThemeDir(), "Modules"),
		installer.CopyModuleFiles)
	// Warm the update answer off the game's serial path. The first /version
	// used to perform the manifest fetch inline, and on a cabinet with no
	// internet that held the game's ONLY HTTP worker for the full timeout --
	// twenty seconds of every network thing the game wanted to do, queued
	// behind a request that was never going to succeed.
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		updates.State(ctx)

		// That fetch is the most expensive thing this process ever does when
		// no game is running: a TLS handshake drags in the system certificate
		// pool, and on a machine that watches for the game the next thing that
		// happens is hours of doing nothing while holding it. Handing the
		// pages back here is worth about forty megabytes of resident memory.
		if installer.GameWatchSupported() {
			debug.FreeOSMemory()
		}
	}()
	srv.SetUpdater(helper.Updater{
		State: func() any {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			return updates.State(ctx)
		},
		Start:    updates.Start,
		Progress: func() any { return updates.Progress() },
	})

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

	// Where the game's comings and goings can be watched, the socket follows
	// them. Nothing is bound between games: no port open on the machine, no
	// config file pointing at one, and no preview cache on disk for a browser
	// that is not running. What is left is a parked process -- which is what
	// has to stay, because nothing on Windows can start one when the game does.
	if installer.GameWatchSupported() {
		srv.Pause()
		previews.Clear()
		go watchForGame(inst, srv, previews, done)
		fmt.Printf("helper waiting for ITGmania at %s\n", inst.Root)
	} else {
		fmt.Printf("helper listening on 127.0.0.1:%d for %s\n", srv.Port(), inst.Root)
	}
	if err := srv.Serve(); err != nil {
		fmt.Fprintf(os.Stderr, "helper: %v\n", err)
		return 1
	}
	return 0
}

// watchForGame binds the loopback socket for as long as ITGmania is running
// and gives it up in between.
//
// Both halves of the wait are the cheapest the platform offers: a process
// snapshot every few seconds to notice a start, then a wait on the process
// handle -- which costs nothing at all while it blocks -- to notice the end.
// So the polling half only runs while the game is not, which is when the
// machine has room for it; and the game takes far longer to reach a menu than
// the poll takes to see it, so the socket is up before anything asks.
func watchForGame(inst installer.Install, srv *helper.Server, previews *preview.Fetcher, done <-chan struct{}) {
	for {
		pid, ok := installer.WaitForGame(inst, done)
		if !ok {
			return // the helper is shutting down
		}
		if err := srv.Resume(); err != nil {
			fmt.Fprintf(os.Stderr, "helper: %v\n", err)
			return
		}
		fmt.Printf("helper listening on 127.0.0.1:%d for %s\n", srv.Port(), inst.Root)

		installer.WaitForGameExit(pid)
		select {
		case <-done:
			return
		default:
		}

		srv.Pause()
		// Previews are refetchable bytes belonging to a browser that has just
		// gone away with the game. Holding megabytes of extracted audio for a
		// screen nobody can open is the sort of thing this is trying not to do.
		previews.Clear()
		// And hand the pages back rather than sit on a heap sized for work
		// that is over: this process is about to be idle for hours.
		debug.FreeOSMemory()
		fmt.Printf("helper waiting for ITGmania at %s\n", inst.Root)
	}
}
