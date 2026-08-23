#!/usr/bin/env node
// Count the upvalues Lua will charge each top-level function in the module.
//
// Lua 5.1 allows a function 60 upvalues (LUAI_MAXUPVALUES). A function is
// charged one for every enclosing-scope local it mentions -- including through
// nested closures, since the enclosing function has to capture it to pass it
// down. BrowserActor builds the whole screen, so it names a great many
// file-level locals, and going one over stops the module loading with an error
// that names a line number and nothing else.
//
// Nothing catches this: it is not a syntax error, luacheck does not model it,
// and the failure only shows up in the game log at runtime.
//
// Usage: node upvalues.js <file.lua> [limit]

const fs = require("fs");
const path = process.argv[2];
const LIMIT = Number(process.argv[3] || 60);
const src = fs.readFileSync(path, "utf8");
const lines = src.split("\n");

// ---- strip comments and strings so identifiers are only real references ----
function scrub(line) {
  return line
    .replace(/--\[\[[\s\S]*?\]\]/g, " ")
    .replace(/--.*$/, " ")
    .replace(/"(\\.|[^"\\])*"/g, '""')
    .replace(/'(\\.|[^'\\])*'/g, "''")
    .replace(/\[\[[\s\S]*?\]\]/g, " ");
}

// ---- top-level locals, and the line each becomes visible on ----------------
const declared = new Map(); // name -> line index
lines.forEach((raw, i) => {
  const line = scrub(raw);
  let m = /^local\s+function\s+([A-Za-z_]\w*)/.exec(line);
  if (m) { if (!declared.has(m[1])) declared.set(m[1], i); return; }
  m = /^local\s+([A-Za-z_][\w\s,]*?)\s*(=|$)/.exec(line);
  if (m) {
    for (const nameRaw of m[1].split(",")) {
      const name = nameRaw.trim();
      if (/^[A-Za-z_]\w*$/.test(name) && !declared.has(name)) declared.set(name, i);
    }
  }
});

// ---- top-level function bodies --------------------------------------------
// Everything here is written with tabs inside functions, so a top-level `end`
// sits at column zero. That makes the body of a column-zero function the span
// up to the next column-zero `end`.
const funcs = [];
lines.forEach((raw, i) => {
  const m = /^local\s+function\s+([A-Za-z_]\w*)|^function\s+([A-Za-z_][\w.]*)/.exec(scrub(raw));
  if (!m) return;
  const name = m[1] || m[2];
  let close = -1;
  for (let j = i + 1; j < lines.length; j++) {
    if (/^end\b/.test(lines[j])) { close = j; break; }
  }
  if (close > i) funcs.push({ name, start: i, end: close });
});

let worst = null;
const report = [];
for (const fn of funcs) {
  const used = new Map(); // name -> reference count
  for (let j = fn.start + 1; j < fn.end; j++) {
    const line = scrub(lines[j]);
    for (const m of line.matchAll(/[A-Za-z_]\w*/g)) {
      const name = m[0];
      // a field access (x.name / x:name) is not a reference to a local
      const before = line[m.index - 1];
      if (before === "." || before === ":") continue;
      if (!declared.has(name)) continue;
      if (declared.get(name) > fn.start) continue; // not in scope yet
      if (name === fn.name) continue;              // recursion is not an upvalue
      used.set(name, (used.get(name) || 0) + 1);
    }
  }
  const entry = { name: fn.name, line: fn.start + 1, count: used.size, used };
  report.push(entry);
  if (!worst || entry.count > worst.count) worst = entry;
}

report.sort((a, b) => b.count - a.count);
console.log(`upvalue budget: ${LIMIT} per function (Lua 5.1 LUAI_MAXUPVALUES)\n`);
for (const fn of report.slice(0, 5)) {
  const flag = fn.count > LIMIT ? "  OVER LIMIT" : fn.count >= LIMIT - 4 ? "  (tight)" : "";
  console.log(`  ${String(fn.count).padStart(3)}  ${fn.name} (line ${fn.line})${flag}`);
}

if (worst && worst.count >= LIMIT - 4) {
  const singles = [...worst.used.entries()]
    .filter(([, n]) => n === 1)
    .map(([n]) => n)
    .sort();
  console.log(`\n  ${worst.name} names ${worst.count} enclosing locals.`);
  if (singles.length) {
    console.log("  Mentioned exactly once, so cheapest to route through an existing table:");
    console.log("    " + singles.join(", "));
  }
}

if (worst && worst.count > LIMIT) {
  console.log(`\nFAIL: ${worst.name} would need ${worst.count} upvalues; Lua allows ${LIMIT}.`);
  process.exit(1);
}
console.log(`\nOK: worst case ${worst ? worst.count : 0} of ${LIMIT}.`);
