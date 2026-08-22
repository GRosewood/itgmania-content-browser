// Command mkwizardart renders the product artwork into the bitmap sizes the
// Windows installer wizard expects.
//
// Inno Setup only accepts BMP for WizardImageFile/WizardSmallImageFile, so
// this crops the source to each target aspect ratio, scales it, and writes
// uncompressed 24-bit BMPs. Run it whenever assets/banner.jpg changes:
//
//	go run ./tools/mkwizardart
package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	_ "image/jpeg"
	"image/png"
	"os"
	"path/filepath"
)

type target struct {
	name string
	w, h int
}

func main() {
	src := filepath.Join("internal", "assets", "banner.jpg")
	outDir := filepath.Join("packaging", "windows")

	f, err := os.Open(src)
	if err != nil {
		fatal(err)
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		fatal(err)
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		fatal(err)
	}

	// Inno Setup 6 scales these for high DPI; 164x314 and 55x58 are the
	// documented 100% sizes for the large and small wizard images.
	for _, t := range []target{
		{"wizard-large.bmp", 164, 314},
		{"wizard-small.bmp", 55, 58},
	} {
		dst := scaleCover(img, t.w, t.h)
		path := filepath.Join(outDir, t.name)
		if err := writeBMP24(path, dst); err != nil {
			fatal(err)
		}
		fmt.Printf("wrote %s (%dx%d)\n", path, t.w, t.h)
	}

	// macOS Installer.app draws a background image on the left of its window.
	macDir := filepath.Join("packaging", "macos", "resources")
	if err := os.MkdirAll(macDir, 0o755); err != nil {
		fatal(err)
	}
	macBG := filepath.Join(macDir, "background.png")
	if err := writePNG(macBG, scaleCover(img, 620, 418)); err != nil {
		fatal(err)
	}
	fmt.Printf("wrote %s (620x418)\n", macBG)
}

func writePNG(path string, img *image.RGBA) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return png.Encode(f, img)
}

// scaleCover crops the source to the destination aspect ratio (centred, but
// biased slightly above centre so the Taj Mahal and the dancer stay in frame)
// and then box-filters it down to the target size.
func scaleCover(src image.Image, w, h int) *image.RGBA {
	b := src.Bounds()
	srcAR := float64(b.Dx()) / float64(b.Dy())
	dstAR := float64(w) / float64(h)

	cw, ch := b.Dx(), b.Dy()
	if srcAR > dstAR {
		cw = int(float64(b.Dy()) * dstAR)
	} else {
		ch = int(float64(b.Dx()) / dstAR)
	}
	ox := b.Min.X + (b.Dx()-cw)/2
	oy := b.Min.Y + (b.Dy()-ch)/3 // upper third reads better than dead centre

	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			x0 := ox + x*cw/w
			x1 := ox + (x+1)*cw/w
			y0 := oy + y*ch/h
			y1 := oy + (y+1)*ch/h
			if x1 <= x0 {
				x1 = x0 + 1
			}
			if y1 <= y0 {
				y1 = y0 + 1
			}
			var r, g, bl, n uint32
			stepX := maxi(1, (x1-x0)/4)
			stepY := maxi(1, (y1-y0)/4)
			for sy := y0; sy < y1; sy += stepY {
				for sx := x0; sx < x1; sx += stepX {
					cr, cg, cb, _ := src.At(sx, sy).RGBA()
					r += cr >> 8
					g += cg >> 8
					bl += cb >> 8
					n++
				}
			}
			if n == 0 {
				n = 1
			}
			dst.Set(x, y, color.RGBA{uint8(r / n), uint8(g / n), uint8(bl / n), 255})
		}
	}
	return dst
}

func maxi(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// writeBMP24 emits an uncompressed bottom-up 24-bit BMP, which is the format
// Inno Setup reads. image/bmp is not in the standard library and the format is
// small enough that a dependency is not worth it.
func writeBMP24(path string, img *image.RGBA) error {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	rowSize := (w*3 + 3) &^ 3 // rows are padded to 4 bytes
	pixels := rowSize * h
	const fileHeader, infoHeader = 14, 40

	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	out := bufio.NewWriter(f)

	le := func(v any) error { return binary.Write(out, binary.LittleEndian, v) }

	out.WriteString("BM")
	if err := le(uint32(fileHeader + infoHeader + pixels)); err != nil {
		return err
	}
	le(uint16(0))
	le(uint16(0))
	le(uint32(fileHeader + infoHeader)) // pixel data offset

	le(uint32(infoHeader))
	le(int32(w))
	le(int32(h))
	le(uint16(1))  // planes
	le(uint16(24)) // bits per pixel
	le(uint32(0))  // BI_RGB, no compression
	le(uint32(pixels))
	le(int32(2835)) // ~72 DPI
	le(int32(2835))
	le(uint32(0))
	le(uint32(0))

	pad := make([]byte, rowSize-w*3)
	for y := h - 1; y >= 0; y-- { // BMP rows run bottom-up
		for x := 0; x < w; x++ {
			c := img.RGBAAt(x, y)
			out.Write([]byte{c.B, c.G, c.R}) // BMP is BGR
		}
		out.Write(pad)
	}
	return out.Flush()
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "mkwizardart:", err)
	os.Exit(1)
}
