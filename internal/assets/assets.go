// Package assets holds the product artwork, embedded into the binary so the
// installer is a single self-contained file.
package assets

import "embed"

// FS contains the artwork. banner.jpg is optional: the pattern also matches
// README.md, so the build succeeds even if the image has been removed, and
// callers treat a missing banner as "do not draw one".
//
//go:embed *.jpg *.md
var FS embed.FS

// BannerPath is the artwork inside FS.
const BannerPath = "banner.jpg"
