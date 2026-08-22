package banner

import (
	"bytes"
	"strings"
	"testing"

	"itgmania-content-browser/internal/assets"
)

// The artwork must actually decode and turn into coloured half-blocks;
// a silent no-op here would mean installers show nothing.
func TestRenderToProducesTruecolorBlocks(t *testing.T) {
	var buf bytes.Buffer
	if !RenderTo(&buf, assets.FS, assets.BannerPath, 72) {
		t.Fatal("RenderTo reported failure; is assets/banner.jpg present and decodable?")
	}
	out := buf.String()

	if !strings.Contains(out, upperHalfBlock) {
		t.Error("output contains no half-block glyphs")
	}
	if !strings.Contains(out, "\x1b[38;2;") || !strings.Contains(out, ";48;2;") {
		t.Error("output is missing 24-bit foreground/background escapes")
	}
	if !strings.HasSuffix(out, "\x1b[0m\n") {
		t.Error("output does not reset colour on the final line")
	}

	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) < 8 {
		t.Errorf("expected a reasonable number of rows, got %d", len(lines))
	}
	for i, line := range lines {
		if got := strings.Count(line, upperHalfBlock); got != 72 {
			t.Fatalf("row %d has %d cells, want 72", i, got)
		}
	}

	// The artwork is colourful: a broken decode would give a flat grey wall.
	if len(distinctColors(out)) < 50 {
		t.Errorf("only %d distinct colours; image likely did not decode", len(distinctColors(out)))
	}
}

func distinctColors(s string) map[string]struct{} {
	seen := map[string]struct{}{}
	for _, part := range strings.Split(s, "\x1b[38;2;") {
		if i := strings.Index(part, "m"); i > 0 {
			seen[part[:i]] = struct{}{}
		}
	}
	return seen
}

func TestRenderToMissingImageIsNotFatal(t *testing.T) {
	var buf bytes.Buffer
	if RenderTo(&buf, assets.FS, "no-such-file.jpg", 72) {
		t.Error("expected failure for a missing image")
	}
	if buf.Len() != 0 {
		t.Error("nothing should be written when the image is missing")
	}
}

func TestClampKeepsWidthSane(t *testing.T) {
	for _, tc := range []struct{ in, want int }{
		{0, defaultCols}, {10, minCols}, {500, maxCols}, {72, 72},
	} {
		if got := clamp(tc.in, minCols, maxCols); got != tc.want {
			t.Errorf("clamp(%d) = %d, want %d", tc.in, got, tc.want)
		}
	}
}
