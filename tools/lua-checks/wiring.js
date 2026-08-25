// Check the wiring by reading the emitted files, not the plan that made them.
//
// Every `local X = CB.X` at the top of a part is a promise that some earlier
// part wrote `CB.X = X`. If nothing did, X is nil and stays nil, and the
// failure turns up much later as "attempt to call a nil value" somewhere that
// has nothing to do with the cause. This reads the load order out of the entry
// file and checks every promise against it.
//
// Usage: node tools/lua-checks/wiring.js <entryFile.lua> <partsDir>
//
// Run by check.js, which finds both for you.
const fs = require("fs");
const path = require("path");

const [, , ENTRY, DIR] = process.argv;
const entry = fs.readFileSync(ENTRY, "utf8");

// The load order, taken from the entry file's own list -- the thing that
// actually runs, rather than the folder's alphabetical order.
let failures = 0;
const order = [];
for (const m of entry.matchAll(/^\t"([^"]+\.lua)",/gm)) order.push(m[1]);
const finalMatch = /^local FINAL = "([^"]+)"/m.exec(entry);
if (finalMatch) order.push(finalMatch[1]);

if (!order.length) {
  console.error("could not read a load order out of " + ENTRY);
  process.exit(2);
}

// Every part ON DISK must be in the entry list. The updater never deletes
// files, so an orphan is expected after a release renames a part -- but a
// NEW file that never made the list is the likeliest add-a-part mistake, and
// it fails silently: the folder holds it, nothing loads it, every name it
// defines is quietly missing. Distinguishing the two is impossible from here,
// so both fail loudly and a deliberate orphan is deleted rather than kept.
{
  const listed = new Set(order);
  for (const f of fs.readdirSync(DIR)) {
    if (f.endsWith(".lua") && !listed.has(f)) {
      console.error("  FAIL  " + f + " is on disk but not in the entry file library list -- it never loads");
      failures++;
    }
  }
}

const supplied = new Set();       // CB.<name> set so far
const suppliedBy = new Map();
const namespaces = new Set(["Screen"]);   // tables the entry creates up front

console.log(order.length + " parts, in the order the entry file loads them\n");

for (const name of order) {
  const file = path.join(DIR, name);
  if (!fs.existsSync(file)) {
    console.error("  MISSING  " + name + " -- listed in the entry file, not on disk");
    failures++;
    continue;
  }
  const text = fs.readFileSync(file, "utf8");

  // Promises this part makes about what already exists.
  const wants = [...text.matchAll(/^local\s+([A-Za-z_]\w*)\s*=\s*CB\.([A-Za-z_]\w*)$/gm)];
  const missing = [];
  for (const m of wants) {
    if (m[1] !== m[2]) {
      console.error("  ODD      " + name + ": local " + m[1] + " = CB." + m[2] +
        " (renamed on the way in, which makes it harder to follow)");
    }
    if (!supplied.has(m[2])) missing.push(m[2]);
  }
  if (missing.length) {
    failures++;
    console.error("  FAIL     " + name + " uses names nothing has set yet: " + missing.join(", "));
  }

  // Anything reached through CB at any point in the body, not just at the top.
  for (const m of text.matchAll(/\bCB\.([A-Za-z_]\w*)\.([A-Za-z_]\w*)/g)) {
    if (!namespaces.has(m[1]) && !supplied.has(m[1])) {
      failures++;
      console.error("  FAIL     " + name + " reaches CB." + m[1] + "." + m[2] +
        " but CB." + m[1] + " has not been set");
    }
  }

  // What it provides for the parts after it.
  const gives = [];
  for (const m of text.matchAll(/^CB\.([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)$/gm)) {
    gives.push(m[1]);
    supplied.add(m[1]);
    suppliedBy.set(m[1], name);
  }
  for (const m of text.matchAll(/^function\s+CB\.([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*\(/gm)) {
    gives.push(m[1] + "." + m[2]);
  }
  for (const m of text.matchAll(/^function\s+CB\.([A-Za-z_]\w*)\s*\(/gm)) {
    gives.push(m[1]);
    supplied.add(m[1]);
    suppliedBy.set(m[1], name);
  }

  console.log("  ok    " + name.padEnd(34) +
    "uses " + String(wants.length).padStart(2) +
    "   provides " + String(gives.length).padStart(2));
}

console.log(failures === 0
  ? "\nOK: every name a part uses is set by a part that ran before it."
  : "\n" + failures + " wiring problem(s).");
process.exit(failures === 0 ? 0 : 1);
