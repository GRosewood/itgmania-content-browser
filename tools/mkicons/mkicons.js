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

  // an arrow landing on a shelf
  installed: p => uni(
    cap(p, 0.50, 0.14, 0.50, 0.55, 0.062),
    cap(p, 0.27, 0.42, 0.50, 0.65, 0.062),
    cap(p, 0.73, 0.42, 0.50, 0.65, 0.062),
    cap(p, 0.17, 0.86, 0.83, 0.86, 0.062)),
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
console.log("\n" + Object.keys(ICONS).length + " icons at " + N + "x" + N);
