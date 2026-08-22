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
