// Catch the deleted-import mistake: a part using a name it never brought in.
//
// Every cross-part name arrives through the shared table -- `local X = CB.X`
// at the top, or a one-line forwarder for the few late-bound ones. Delete one
// of those lines, or use a new name and forget to add one, and nothing
// complains: the name compiles as a global, a global nobody sets is nil, and
// the failure surfaces later as "attempt to call a nil value" somewhere that
// says nothing about the cause.
//
// The test: a FREE name in a part (used, but not declared in that part at any
// scope and not imported) must not be a name that any part defines or exports.
// Engine globals -- SCREENMAN, Def, math -- are free everywhere and belong to
// nobody here, so they pass untouched; a project name gone free is exactly the
// deleted import.
//
// Usage:  node tools/lua-checks/names.js <partsDir>
const fs = require("fs");
const path = require("path");

const DIR = process.argv[2];
if (!DIR) {
  console.error("usage: node names.js <partsDir>");
  process.exit(2);
}

// One pass that knows whether it is inside a string or a comment. The prose
// here uses "--" as an em dash inside strings, and apostrophes in comments, so
// naive stripping corrupts everything after the first one it misreads.
function scrub(text) {
  let out = "", i = 0;
  const n = text.length;
  while (i < n) {
    const long = /^(--)?\[(=*)\[/.exec(text.slice(i, i + 8));
    if (long) {
      const close = "]" + long[2] + "]";
      const end = text.indexOf(close, i + long[0].length);
      const eaten = text.slice(i, end === -1 ? n : end + close.length);
      out += eaten.replace(/[^\n]/g, " ");
      i = end === -1 ? n : end + close.length;
      continue;
    }
    if (text[i] === "-" && text[i + 1] === "-") {
      while (i < n && text[i] !== "\n") { out += " "; i++; }
      continue;
    }
    if (text[i] === '"' || text[i] === "'") {
      const q = text[i++];
      out += " ";
      while (i < n) {
        if (text[i] === "\\") { out += "  "; i += 2; continue; }
        if (text[i] === q) { out += " "; i++; break; }
        if (text[i] === "\n") break;
        out += " "; i++;
      }
      continue;
    }
    out += text[i++];
  }
  return out;
}

// Names a chunk binds anywhere in it: locals at any depth, function
// parameters, for-loop variables. Coarser than real scoping -- a name bound
// deep inside one function is treated as bound for the whole file -- which
// errs towards silence, never towards a false alarm.
function bound(clean) {
  const out = new Set();
  for (const line of clean.split("\n")) {
    let m = /\blocal\s+function\s+([A-Za-z_]\w*)/.exec(line);
    if (m) { out.add(m[1]); continue; }
    m = /\blocal\s+([A-Za-z_][\w ,\t]*)/.exec(line);
    if (m) {
      for (const n of m[1].split(",").map(s => s.trim())) {
        if (/^[A-Za-z_]\w*$/.test(n)) out.add(n);
      }
    }
    for (const f of line.matchAll(/\bfunction\s*[A-Za-z_.:\w]*\s*\(([^)]*)\)/g)) {
      for (const n of f[1].split(",").map(s => s.trim())) {
        if (/^[A-Za-z_]\w*$/.test(n)) out.add(n);
      }
    }
    m = /\bfor\s+([A-Za-z_][\w\s,]*?)\s*(?:=|\bin\b)/.exec(line);
    if (m) {
      for (const n of m[1].split(",").map(s => s.trim())) {
        if (/^[A-Za-z_]\w*$/.test(n)) out.add(n);
      }
    }
  }
  return out;
}

const files = fs.readdirSync(DIR).filter(f => f.endsWith(".lua")).sort();
if (!files.length) {
  console.error("no .lua files under " + DIR);
  process.exit(2);
}

// First pass: every name the project itself defines or shares -- the names a
// part could plausibly have meant to import.
const project = new Set();
const cleaned = new Map();
for (const f of files) {
  const clean = scrub(fs.readFileSync(path.join(DIR, f), "utf8"));
  cleaned.set(f, clean);
  for (const line of clean.split("\n")) {
    let m = /^local\s+function\s+([A-Za-z_]\w*)/.exec(line);
    if (m) { project.add(m[1]); continue; }
    m = /^local\s+([A-Za-z_][\w ,\t]*)/.exec(line);
    if (m) {
      for (const n of m[1].split(",").map(s => s.trim())) {
        if (/^[A-Za-z_]\w*$/.test(n)) project.add(n);
      }
    }
    m = /^CB\.([A-Za-z_]\w*)\s*=/.exec(line);
    if (m) project.add(m[1]);
  }
}
project.delete("CB");   // the vararg itself

// Second pass: free names against that set.
let failures = 0;
for (const f of files) {
  const clean = cleaned.get(f);
  const b = bound(clean);
  const bad = new Map();
  clean.split("\n").forEach((line, i) => {
    for (const m of line.matchAll(/(^|[^A-Za-z0-9_.:])([A-Za-z_]\w*)/g)) {
      const name = m[2];
      if (b.has(name) || !project.has(name)) continue;
      if (!bad.has(name)) bad.set(name, i + 1);
    }
  });
  if (bad.size) {
    failures += bad.size;
    console.log("  FAIL  " + f);
    for (const [name, line] of bad) {
      console.log("        " + name + " (line " + line + ") is a project name this part " +
        "neither declares nor imports -- it is nil here");
    }
  }
}

console.log(failures === 0
  ? "OK: every project name is declared or imported wherever it is used (" +
    project.size + " names, " + files.length + " parts)."
  : failures + " free project name(s) -- each one is a silent nil.");
process.exit(failures === 0 ? 0 : 1);
