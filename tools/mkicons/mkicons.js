// Renders the browser's tab icons as anti-aliased PNGs.
//
// The engine's symbol fonts carry arrows, stars and music notes and nothing
// else useful, and quads only draw rectangles, so the icons are rendered here
// from signed distance fields and shipped as images. They are pure white with
// the shape in the alpha channel, so the module tints them with diffuse().
const fs = require("fs");
const zlib = require("zlib");

const N = 96;           // pixels per side
const OUT = process.argv[2];

// ---------------------------------------------------------------- SDF bits
const sub = (a, b) => Math.max(a, -b);
const uni = (...d) => Math.min(...d);

function disc(p, cx, cy, r) {
  return Math.hypot(p.x - cx, p.y - cy) - r;
}
function ring(p, cx, cy, r, t) {
  return Math.abs(disc(p, cx, cy, r)) - t / 2;
}
// thick line segment with round caps
function cap(p, ax, ay, bx, by, r) {
  const pax = p.x - ax, pay = p.y - ay, bax = bx - ax, bay = by - ay;
  const h = Math.max(0, Math.min(1, (pax * bax + pay * bay) / (bax * bax + bay * bay)));
  return Math.hypot(pax - bax * h, pay - bay * h) - r;
}
function roundRect(p, cx, cy, hw, hh, r) {
  const qx = Math.abs(p.x - cx) - (hw - r), qy = Math.abs(p.y - cy) - (hh - r);
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}
// A convex polygon: the largest of the outward distances to its edges. The
// winding is worked out from the signed area rather than assumed, so the
// normals point outward whichever way the points were listed.
function poly(p, verts, r) {
  let area = 0;
  for (let i = 0; i < verts.length; i++) {
    const [x1, y1] = verts[i], [x2, y2] = verts[(i + 1) % verts.length];
    area += x1 * y2 - x2 * y1;
  }
  const s = area > 0 ? 1 : -1;
  let d = -Infinity;
  for (let i = 0; i < verts.length; i++) {
    const [x1, y1] = verts[i], [x2, y2] = verts[(i + 1) % verts.length];
    const ex = x2 - x1, ey = y2 - y1, len = Math.hypot(ex, ey);
    d = Math.max(d, (p.x - x1) * (s * ey / len) + (p.y - y1) * (-s * ex / len));
  }
  return d - r;
}

const rectRing = (p, cx, cy, hw, hh, r, t) =>
  Math.abs(roundRect(p, cx, cy, hw, hh, r)) - t / 2;

// The arrow the chart preview scrolls: a head and a tail, pointing up, in the
// proportions cel uses. Shared so the body, its inner line and the receptor
// can never drift out of shape with one another.
const arrow = p => uni(
  poly(p, [[0.50, 0.10], [0.92, 0.52], [0.08, 0.52]], 0.030),
  roundRect(p, 0.50, 0.66, 0.150, 0.220, 0.050));

// ------------------------------------------------------------------ icons
const ICONS = {
  // a magnifier
  search: p => uni(
    ring(p, 0.43, 0.41, 0.25, 0.095),
    cap(p, 0.60, 0.59, 0.84, 0.83, 0.055)),

  // a dance pad: four panels round a centre
  pad: p => uni(
    roundRect(p, 0.50, 0.19, 0.165, 0.165, 0.05),
    roundRect(p, 0.50, 0.81, 0.165, 0.165, 0.05),
    roundRect(p, 0.19, 0.50, 0.165, 0.165, 0.05),
    roundRect(p, 0.81, 0.50, 0.165, 0.165, 0.05),
    roundRect(p, 0.50, 0.50, 0.135, 0.135, 0.04)),

  // Two pads side by side, for doubles: one player standing across both.
  //
  // Each pad is square, which is the whole point of the shape -- a dance pad
  // is as wide as it is deep. Spacing the buttons further apart vertically
  // than horizontally to fill a square canvas, which is what this used to do,
  // drew two pads that had been stood on: correct in outline and wrong in
  // every proportion. Two square pads in a square canvas leave room above and
  // below instead, which is what being half as wide actually looks like.
  doubles: p => {
    const s = 0.145;   // button centre to pad centre, the same both ways
    const b = 0.070;   // half a button
    const half = (q, ox) => uni(
      roundRect(q, ox,     0.50 - s, b, b, 0.024),
      roundRect(q, ox,     0.50 + s, b, b, 0.024),
      roundRect(q, ox - s, 0.50,     b, b, 0.024),
      roundRect(q, ox + s, 0.50,     b, b, 0.024));
    return uni(half(p, 0.25), half(p, 0.75));
  },

  // a keyboard
  keyboard: p => uni(
    rectRing(p, 0.50, 0.50, 0.46, 0.31, 0.09, 0.075),
    roundRect(p, 0.28, 0.42, 0.055, 0.05, 0.02),
    roundRect(p, 0.43, 0.42, 0.055, 0.05, 0.02),
    roundRect(p, 0.58, 0.42, 0.055, 0.05, 0.02),
    roundRect(p, 0.73, 0.42, 0.055, 0.05, 0.02),
    cap(p, 0.32, 0.61, 0.68, 0.61, 0.05)),

  // a sprout
  beginner: p => uni(
    // the stem carries on above where the leaves join, or it reads as a Y
    cap(p, 0.50, 0.92, 0.50, 0.26, 0.05),
    // leaves: short fat strokes read as rounded foliage at this size
    cap(p, 0.44, 0.56, 0.21, 0.47, 0.125),
    cap(p, 0.56, 0.46, 0.79, 0.37, 0.125)),

  // an apple
  tech: p => uni(
    sub(uni(disc(p, 0.37, 0.60, 0.28), disc(p, 0.63, 0.60, 0.28)),
        disc(p, 0.50, 0.235, 0.115)),
    cap(p, 0.50, 0.34, 0.55, 0.14, 0.035),
    cap(p, 0.58, 0.20, 0.80, 0.12, 0.065)),

  // a runner
  stamina: p => uni(
    disc(p, 0.66, 0.15, 0.105),
    cap(p, 0.61, 0.27, 0.43, 0.53, 0.058),   // torso, leaning forward
    cap(p, 0.56, 0.33, 0.84, 0.25, 0.044),   // leading arm
    cap(p, 0.51, 0.39, 0.23, 0.35, 0.044),   // trailing arm
    cap(p, 0.44, 0.52, 0.67, 0.65, 0.052),   // leading thigh
    cap(p, 0.67, 0.65, 0.73, 0.88, 0.046),   // leading shin
    cap(p, 0.44, 0.52, 0.27, 0.63, 0.052),   // trailing thigh
    cap(p, 0.27, 0.63, 0.12, 0.77, 0.046)),  // trailing shin

  // a calendar
  year: p => uni(
    rectRing(p, 0.50, 0.57, 0.40, 0.35, 0.085, 0.08),
    roundRect(p, 0.50, 0.31, 0.40, 0.085, 0.03),
    cap(p, 0.34, 0.13, 0.34, 0.24, 0.045),
    cap(p, 0.66, 0.13, 0.66, 0.24, 0.045)),

  // a play triangle. The points are pulled in by the corner radius so the
  // rounded shape still fills the box it is given, rather than sitting inside
  // a triangle that is visibly too small.
  play: p => poly(p, [[0.30, 0.19], [0.80, 0.50], [0.30, 0.81]], 0.055),

  // a plain filled dot, for the featured strip's page indicator. Squares read
  // as debris at five pixels across; a circle reads as a dot.
  dot: p => disc(p, 0.50, 0.50, 0.42),

  // a radio button, in both of its states
  radiooff: p => ring(p, 0.50, 0.50, 0.34, 0.10),
  radioon: p => uni(
    ring(p, 0.50, 0.50, 0.34, 0.10),
    disc(p, 0.50, 0.50, 0.17)),

  // an arrow dropping into an open tray. Deliberately not the same shape as
  // the Installed tab's icon, which is an arrow onto a bare shelf: one means
  // 'fetch this', the other means 'already here'.
  download: p => uni(
    cap(p, 0.50, 0.09, 0.50, 0.50, 0.060),   // shaft
    cap(p, 0.27, 0.35, 0.50, 0.58, 0.060),   // left barb
    cap(p, 0.73, 0.35, 0.50, 0.58, 0.060),   // right barb
    cap(p, 0.15, 0.88, 0.85, 0.88, 0.060),   // tray floor
    cap(p, 0.15, 0.68, 0.15, 0.88, 0.060),   // tray walls
    cap(p, 0.85, 0.68, 0.85, 0.88, 0.060)),

  // A note and its receptor, for the chart the sample is playing. One arrow
  // pointing up, turned four ways by the screen -- so the four directions can
  // never drift apart from each other, and doubles costs nothing extra.
  note: p => arrow(p),
  receptor: p => Math.abs(arrow(p)) - 0.045,

  // The pale line that runs just inside the arrow every ITG skin draws, cel
  // included. It is a second image rather than part of the first because it is
  // the one part that must not take the quantization colour: the body says
  // which quantization, the line stays white, and tinting one graphic would
  // have taken both.
  //
  // Inset rather than an outer border. Measured off cel: the line sits about a
  // twentieth of the arrow in from its edge and is about that thick, which is
  // thin enough to read as an edge and not as a second arrow.
  noteedge: p => Math.abs(arrow(p) + 0.048) - 0.021,

  installed: p => uni(
    cap(p, 0.50, 0.14, 0.50, 0.55, 0.062),
    cap(p, 0.27, 0.42, 0.50, 0.65, 0.062),
    cap(p, 0.73, 0.42, 0.50, 0.65, 0.062),
    cap(p, 0.17, 0.86, 0.83, 0.86, 0.062)),
};

// Icons that are not square. The SDF works in units of the icon HEIGHT, so x
// runs 0..aspect and every radius means the same thing on both axes -- which is
// the whole reason the shapes above can be written as fractions at all.
const WIDE = {
  // What a pack with no banner shows instead.
  //
  // Banner-shaped rather than square, so it fills the slot the real one would
  // have filled: a row of packs where one is missing its art should still be a
  // row, not a row with a hole and a small square in it.
  //
  // The classic picture placeholder -- a frame, a sun, a horizon -- because it
  // is read as "no image here" without a caption in any language.
  nobanner: {
    aspect: 256 / 80,
    sdf: (p, A) => {
      const cx = A / 2, cy = 0.5;
      const frame = rectRing(p, cx, cy, 0.62, 0.34, 0.07, 0.052);
      const sun = disc(p, cx - 0.30, cy - 0.12, 0.058);
      const hill = uni(
        poly(p, [[cx - 0.42, cy + 0.26], [cx - 0.14, cy - 0.04], [cx + 0.14, cy + 0.26]], 0.02),
        poly(p, [[cx - 0.06, cy + 0.26], [cx + 0.18, cy + 0.02], [cx + 0.42, cy + 0.26]], 0.02));
      return uni(frame, sun, hill);
    },
  },
};

// ------------------------------------------------------------- png writing
const TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(width, height, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const raw = Buffer.alloc(height * (width * 4 + 1));
  for (let y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0;
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// --------------------------------------------------------------- rasterise
fs.mkdirSync(OUT, { recursive: true });
for (const [name, sdf] of Object.entries(ICONS)) {
  const rgba = Buffer.alloc(N * N * 4);
  const px = 1 / N;
  for (let y = 0; y < N; y++) {
    for (let x = 0; x < N; x++) {
      const p = { x: (x + 0.5) * px, y: (y + 0.5) * px };
      const d = sdf(p);
      // analytic coverage: the distance field is in the same units as a pixel,
      // so half a pixel either side of the edge is the whole transition
      const a = Math.max(0, Math.min(1, 0.5 - d / px));
      const i = (y * N + x) * 4;
      rgba[i] = 255; rgba[i + 1] = 255; rgba[i + 2] = 255;
      rgba[i + 3] = Math.round(a * 255);
    }
  }
  const file = OUT + "/" + name + ".png";
  fs.writeFileSync(file, png(N, N, rgba));
  console.log("  " + name + ".png");
}

for (const [name, spec] of Object.entries(WIDE)) {
  const h = N, w = Math.round(N * spec.aspect);
  const rgba = Buffer.alloc(w * h * 4);
  const px = 1 / h;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const p = { x: (x + 0.5) * px, y: (y + 0.5) * px };
      const d = spec.sdf(p, spec.aspect);
      const a = Math.max(0, Math.min(1, 0.5 - d / px));
      const i = (y * w + x) * 4;
      rgba[i] = 255; rgba[i + 1] = 255; rgba[i + 2] = 255;
      rgba[i + 3] = Math.round(a * 255);
    }
  }
  fs.writeFileSync(OUT + "/" + name + ".png", png(w, h, rgba));
  console.log("  " + name + ".png  (" + w + "x" + h + ")");
}

console.log("\n" + (Object.keys(ICONS).length + Object.keys(WIDE).length)
  + " icons at " + N + "px tall");
