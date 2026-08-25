// Count the chunk-level locals in a file against Lua 5.1's ceiling of 200.
//
// This is the other limit the module lives against, and the one with the worst
// error message: exceeding it stops the file loading with a complaint about a
// line that is merely the two-hundred-and-first, and says nothing about why.
//
// The README used to suggest `grep -c '^local '` for this, which quietly
// undercounts -- `local a, b, c = ...` is one line and three locals, and a
// forward declaration written `local Thing  -- filled in below` is one more.
// Counting names rather than lines is the whole point of having this.
//
// Usage:  node tools/lua-checks/locals.js <file.lua> [...]
const fs = require("fs");

const LIMIT = 200;   // LUAI_MAXVARS in luaconf.h

const files = process.argv.slice(2);
if (!files.length) {
  console.error("usage: node locals.js <file.lua> [...]");
  process.exit(2);
}

let worst = 0;
let failed = false;

for (const file of files) {
  const lines = fs.readFileSync(file, "utf8").split("\n");
  const names = [];

  lines.forEach((raw, i) => {
    // Column zero only. Anything indented belongs to some enclosing function
    // and is charged against that function's own budget, not the chunk's.
    let m = raw.match(/^local\s+function\s+([A-Za-z_]\w*)/);
    if (m) { names.push({ name: m[1], line: i + 1 }); return; }

    // `local a, b, c = ...` and `local a` and `local a  -- note`
    m = raw.match(/^local\s+([A-Za-z_][\w\s,]*?)\s*(?:=|--|$)/);
    if (!m) return;
    for (const n of m[1].split(",").map(s => s.trim())) {
      if (/^[A-Za-z_]\w*$/.test(n)) names.push({ name: n, line: i + 1 });
    }
  });

  const count = names.length;
  worst = Math.max(worst, count);
  const room = LIMIT - count;
  // 200 is the most a chunk may have, not one too many -- a file sitting
  // exactly on it still loads. It has no room left, though, which is worth
  // saying plainly rather than waiting for the next local to break the build.
  const note = count > LIMIT ? "  OVER THE LIMIT"
    : count === LIMIT ? "  (full -- no room for another)"
    : room <= 10 ? `  (only ${room} left)`
    : "";
  console.log(String(count).padStart(5) + " of " + LIMIT + "   " + file + note);

  if (count > LIMIT) {
    failed = true;
    // The last few declared are the ones to question first, since they are
    // what tipped it over.
    console.error("        last declared: " +
      names.slice(-6).map(n => n.name + " (line " + n.line + ")").join(", "));
  }
}

if (failed) {
  console.error("\nA chunk may declare at most " + LIMIT + " locals (LUAI_MAXVARS).");
  console.error("Hang the value off a table that is already a local -- state, LO, Snd --");
  console.error("or move it into the part of the module it actually belongs to.");
  process.exit(1);
}
console.log("\nOK: worst case " + worst + " of " + LIMIT + ".");
