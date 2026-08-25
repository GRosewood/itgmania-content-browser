// Catch a name used above the line that declares it.
//
// Lua binds a name when it compiles the line that mentions it, so a `local`
// declared further down a file is not the same name to the code above it --
// that code reads a GLOBAL, and a global nobody sets is nil. Nothing else here
// can see this: the name IS declared in the file, so the wiring checks are
// happy, the file parses, the blocks balance, and the failure arrives at run
// time as "attempt to call a nil value" or "attempt to index a nil value" in a
// function that looks entirely correct.
//
// This has bitten this project twice -- once when the layout table was
// declared below the download prompt that asked it about disk space, and once
// when a redraw called a helper written below it. Both times the fix was to
// declare the name earlier and assign it where it belongs.
//
// Being inside a function body does not excuse it. Deferring the CALL does not
// defer the BINDING: the line was compiled when the file loaded, and whatever
// it resolved to then is what it keeps for good. A forward declaration is the
// fix, and it is also the thing this measures against -- `local Thing` early,
// `Thing = function() ... end` later, reports the early line and passes.
//
// A name declared more than once is skipped, because a mention could bind to
// either declaration and only a real scope parser could say which.
//
// Usage:  node tools/lua-checks/order.js <file.lua> [...]
const fs = require("fs");

const files = process.argv.slice(2);
if (!files.length) {
  console.error("usage: node order.js <file.lua> [...]");
  process.exit(2);
}

// One pass that knows whether it is inside a string or a comment; the prose
// here uses "--" as an em dash inside strings and apostrophes inside comments,
// so neither can be stripped with a regex alone.
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

let failures = 0;

for (const file of files) {
  const lines = scrub(fs.readFileSync(file, "utf8")).split("\n");

  // What each line declares, and whether it declares it at chunk level.
  function declares(text) {
    let m = text.match(/^\s*local\s+function\s+([A-Za-z_]\w*)/);
    if (m) return [m[1]];
    m = text.match(/^\s*local\s+([A-Za-z_][\w ,\t]*?)\s*(?:=|$)/);
    if (!m) return [];
    return m[1].split(",").map(s => s.trim()).filter(n => /^[A-Za-z_]\w*$/.test(n));
  }

  // Chunk-level declarations and the line each one is on.
  const declaredAt = new Map();
  // Names ALSO declared inside some block. A name can be declared more than
  // once -- an inner `local ok` shadowing an outer one is ordinary Lua -- and
  // telling which declaration a given mention binds to needs a real scope
  // parser, not a line scan. So a shadowed name is left alone entirely: this
  // check would rather say nothing than say something it cannot stand behind.
  // The bug it exists for is a chunk-level helper declared once, below a line
  // that calls it, and that case stays fully covered.
  const shadowed = new Set();
  lines.forEach((text, i) => {
    const chunkLevel = /^local\b/.test(text);
    for (const n of declares(text)) {
      if (!chunkLevel) { shadowed.add(n); continue; }
      if (declaredAt.has(n)) shadowed.add(n);
      else declaredAt.set(n, i + 1);
    }
  });

  // Every line counts, indented or not. Scope in Lua is lexical and settled
  // when the line is COMPILED, not when it runs: a mention inside a function
  // body, above the declaration, is bound to a global there and stays bound
  // to it however late the function is finally called. Deferring the call
  // does not defer the binding.
  //
  // Legitimate forward declarations are unaffected, because they are what
  // this measures against: `local Thing` on an early line, filled in later
  // with `Thing = function() ... end`, records the early line. And Lua's
  // `local function F` sugar declares F before its own body, so a function
  // that calls itself is fine too.
  const bad = [];
  const seen = new Set();
  lines.forEach((text, i) => {
    if (/^\s*local\b/.test(text)) return;   // a declaration, at any depth
    const re = /(^|[^A-Za-z0-9_.:])([A-Za-z_]\w*)/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      if (shadowed.has(m[2])) continue;
      const at = declaredAt.get(m[2]);
      if (at !== undefined && at > i + 1 && !seen.has(m[2])) {
        seen.add(m[2]);
        bad.push({ name: m[2], used: i + 1, declared: at });
      }
    }
  });

  if (bad.length) {
    failures += bad.length;
    console.log("  FAIL  " + file);
    for (const b of bad) {
      console.log("        " + b.name + " is used at line " + b.used +
        " but not declared until line " + b.declared +
        " -- above that line it is a nil global");
    }
  }
}

console.log(failures === 0
  ? "OK: nothing is used above the line that declares it."
  : "\n" + failures + " forward reference(s) -- each one is a nil global.");
process.exit(failures === 0 ? 0 : 1);
