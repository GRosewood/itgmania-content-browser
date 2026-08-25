// Package branding holds the product identity in one place so the installer,
// the packaging scripts and the docs cannot drift apart.
package branding

const (
	// Name is the human-readable product name shown to users.
	Name = "ITGMania Content Browser"

	// Author is credited wherever the packaging format allows it.
	Author = "GregTech"

	// Slug is the machine-readable identifier (binaries, repo, module path).
	Slug = "itgmania-content-browser"

	// MenuLabel is what the module is called inside the game. This
	// deliberately differs from Name: the in-game menu entry stays
	// "Find Content".
	MenuLabel = "Find Content"

	// Tagline is a one-line description for installer chrome.
	Tagline = "Browse and install song packs from inside ITGmania"
)

const (
	// Version is what this build calls itself. The installer, the helper and
	// the in-game module all report it, and the updater compares it against
	// what the manifest advertises.
	//
	// build.sh reads it from here, so bumping this one line is the whole of
	// cutting a release.
	Version = "0.1"

	// UpdateManifest is where the helper looks to find out whether a newer
	// module has been published. It is fetched by the helper rather than by
	// the game: the engine will only talk to hosts on its own allowlist, and
	// asking players to add another one to see an update notice is a poor
	// trade for a file this small.
	UpdateManifest = "https://raw.githubusercontent.com/GRosewood/" +
		Slug + "/main/update.json"
)
