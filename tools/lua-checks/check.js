// Run every Lua check over every Lua file in the module payload.
//
// The module used to be one file, and remembering to check one file is easy.
// It is now an entry point and a folder of parts, and remembering to check
// thirty is not -- so this walks the payload, runs all four checks on
// everything it finds, and gives one answer.
//
// Usage:  node tools/lua-checks/check.js [payloadModulesDir]
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const DEFAULT_DIR = path.join(
  HERE, "..", "..", "cmd", "content-browser-installer", "payload", "Modules");

const root = process.argv[2] || DEFAULT_DIR;
if (!fs.existsSync(root)) {
  console.error("no such directory: " + root);
  process.exit(2);
}

// Every .lua under the payload, entry point first and then the parts in the
// order they load, which is the order their names sort in.
function luaFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
    a.name.localeCompare(b.name))) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...luaFiles(full));
    else if (entry.name.toLowerCase().endsWith(".lua")) out.push(full);
  }
  return out;
}
const files = luaFiles(root);
if (!files.length) {
  console.error("no .lua files under " + root);
  process.exit(2);
}

function run(script, args) {
  try {
    return { ok: true, out: execFileSync(process.execPath,
      [path.join(HERE, script), ...args], { encoding: "utf8" }) };
  } catch (err) {
    return {
      ok: false,
      out: (err.stdout || "") + (err.stderr || ""),
    };
  }
}

let failed = 0;
const rel = f => path.relative(root, f).replace(/\\/g, "/");

// Per-file checks: a chunk is a chunk, and each one has its own budgets.
console.log(files.length + " Lua files under " + root + "\n");
for (const file of files) {
  const results = [
    ["syntax  ", run("syntax.js", [file])],
    ["blocks  ", run("blocks.js", [file])],
    ["upvalues", run("upvalues.js", [file])],
    ["locals  ", run("locals.js", [file])],
  ];
  const bad = results.filter(r => !r[1].ok);
  if (!bad.length) {
    // Pull the interesting numbers out so a passing run still says something.
    const up = /worst case (\d+) of 60/.exec(results[2][1].out);
    const lo = /^\s*(\d+) of 200/m.exec(results[3][1].out);
    console.log("  ok    " + rel(file).padEnd(46) +
      "upvalues " + String(up ? up[1] : "?").padStart(2) + "/60" +
      "   locals " + String(lo ? lo[1] : "?").padStart(3) + "/200");
    continue;
  }
  failed++;
  console.log("  FAIL  " + rel(file));
  for (const [name, r] of bad) {
    console.log("        " + name + ":");
    for (const line of r.out.trimEnd().split("\n")) console.log("          " + line);
  }
}

// Then one check across the whole set rather than per file: that every name a
// part imports was actually put on the shared table by a part that ran before
// it. No per-file check can see this -- it is a property of the load order, and
// getting it wrong gives you a nil that only complains much later, somewhere
// unrelated.
const entry = path.join(root, "ITGmania Content Browser.lua");
const parts = path.join(root, "ITGmania Content Browser");
if (fs.existsSync(entry) && fs.existsSync(parts)) {
  const wiring = run("wiring.js", [entry, parts]);
  const lines = wiring.out.trimEnd().split("\n");
  console.log("");
  if (wiring.ok) {
    console.log("  ok    " + lines[lines.length - 1].trim());
  } else {
    failed++;
    console.log("  FAIL  wiring:");
    for (const line of lines) console.log("        " + line);
  }

  // And the mirror image: wiring checks that what a part imports was exported
  // earlier; this checks that what a part USES it actually imported. A deleted
  // import line fails here and nowhere else -- the name quietly compiles as a
  // global otherwise, and a global nobody sets is nil.
  const names = run("names.js", [parts]);
  const nameLines = names.out.trimEnd().split("\n");
  if (names.ok) {
    console.log("  ok    " + nameLines[nameLines.length - 1].trim());
  } else {
    failed++;
    console.log("  FAIL  names:");
    for (const line of nameLines) console.log("        " + line);
  }
}

console.log(failed === 0
  ? "\nOK: all " + files.length + " files pass."
  : "\n" + failed + " problem(s).");
process.exit(failed === 0 ? 0 : 1);
