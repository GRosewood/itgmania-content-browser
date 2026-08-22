// Package banner renders the product artwork in a terminal.
//
// Installers show artwork where the platform allows it. A single static
// binary has no GUI, but every modern terminal on Windows, macOS and Linux
// understands 24-bit colour, so the image is drawn with half-block glyphs:
// each character cell carries two pixels (foreground = upper, background =
// lower), which doubles the vertical resolution.
//
// When the output is redirected, the terminal is too narrow, or colour
// support cannot be confirmed, rendering is skipped silently -- the installer
// is fully usable without it.
package banner

import (
	"fmt"
	"image"
	"image/color"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"io/fs"
	"os"
	"strconv"
	"strings"
)

const (
	// upperHalfBlock paints the top half of a cell in the foreground colour
	// and leaves the bottom half showing the background colour.
	upperHalfBlock = "▀"

	minCols     = 40
	maxCols     = 100
	defaultCols = 72
)

// Render writes the image at path (inside fsys) to w as coloured half-blocks.
// A missing image, an undecodable image, or a terminal that cannot show
// colour are all non-errors: nothing is drawn and Render reports false.
func Render(w io.Writer, fsys fs.FS, path string, maxWidth int) bool {
	if !ColorCapable() {
		return false
	}
	return RenderTo(w, fsys, path, maxWidth)
}

// RenderTo draws the image regardless of terminal capability. Callers that
// have already decided colour is safe (and tests) use this directly.
func RenderTo(w io.Writer, fsys fs.FS, path string, maxWidth int) bool {
	f, err := fsys.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()

	img, _, err := image.Decode(f)
	if err != nil {
		return false
	}

	cols := clamp(maxWidth, minCols, maxCols)
	b := img.Bounds()
	if b.Dx() <= 0 || b.Dy() <= 0 {
		return false
	}

	// Character cells are about twice as tall as they are wide, and each cell
	// shows two stacked pixels, so the two factors cancel: rows = cols * h/w
	// divided by 2, times 2. Halve once for the cell aspect ratio.
	rows := int(float64(cols) * float64(b.Dy()) / float64(b.Dx()) / 2.0)
	if rows < 2 {
		return false
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		for col := 0; col < cols; col++ {
			upper := sampleAvg(img, b, col, row*2, cols, rows*2)
			lower := sampleAvg(img, b, col, row*2+1, cols, rows*2)
			sb.WriteString("\x1b[38;2;")
			writeRGB(&sb, upper)
			sb.WriteString(";48;2;")
			writeRGB(&sb, lower)
			sb.WriteString("m")
			sb.WriteString(upperHalfBlock)
		}
		sb.WriteString("\x1b[0m\n")
	}
	fmt.Fprint(w, sb.String())
	return true
}

func writeRGB(sb *strings.Builder, c [3]uint32) {
	sb.WriteString(strconv.Itoa(int(c[0])))
	sb.WriteByte(';')
	sb.WriteString(strconv.Itoa(int(c[1])))
	sb.WriteByte(';')
	sb.WriteString(strconv.Itoa(int(c[2])))
}

// sampleAvg box-filters the source region mapped to one output pixel, which
// keeps fine detail (the dancer, the minarets) from aliasing away.
func sampleAvg(img image.Image, b image.Rectangle, cx, cy, cols, rows int) [3]uint32 {
	x0 := b.Min.X + cx*b.Dx()/cols
	x1 := b.Min.X + (cx+1)*b.Dx()/cols
	y0 := b.Min.Y + cy*b.Dy()/rows
	y1 := b.Min.Y + (cy+1)*b.Dy()/rows
	if x1 <= x0 {
		x1 = x0 + 1
	}
	if y1 <= y0 {
		y1 = y0 + 1
	}

	// Cap the samples per cell so huge source images stay fast.
	stepX := max1((x1 - x0) / 4)
	stepY := max1((y1 - y0) / 4)

	var r, g, bl, n uint32
	for y := y0; y < y1; y += stepY {
		for x := x0; x < x1; x += stepX {
			cr, cg, cb, _ := color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA).RGBA()
			r += cr >> 8
			g += cg >> 8
			bl += cb >> 8
			n++
		}
	}
	if n == 0 {
		return [3]uint32{0, 0, 0}
	}
	return [3]uint32{r / n, g / n, bl / n}
}

func max1(v int) int {
	if v < 1 {
		return 1
	}
	return v
}

func clamp(v, lo, hi int) int {
	if v <= 0 {
		v = defaultCols
	}
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// ColorCapable reports whether it is safe to emit 24-bit colour escapes.
func ColorCapable() bool {
	if os.Getenv("NO_COLOR") != "" {
		return false
	}
	if !isTerminal(os.Stdout) {
		return false
	}
	// Windows Terminal, and Windows 10+ consoles once VT mode is enabled.
	if os.Getenv("WT_SESSION") != "" {
		return true
	}
	if enableVirtualTerminal() {
		return true
	}
	switch strings.ToLower(os.Getenv("COLORTERM")) {
	case "truecolor", "24bit":
		return true
	}
	term := os.Getenv("TERM")
	return strings.Contains(term, "256color") || strings.Contains(term, "truecolor")
}
