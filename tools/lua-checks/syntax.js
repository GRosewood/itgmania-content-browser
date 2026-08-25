// Parse the module as Lua 5.1 and report the first thing that is not.
//
// blocks.js counts do/end pairs, which catches an unbalanced edit but not a
// stray token: a patch that dropped a lone "f" between two functions balanced
// perfectly and still failed to load, and the only sign was one WARNING line
// in the game's log after a restart. This parses for real, so the same class of
// mistake is caught in a second rather than in a launch.
//
// luaparse is optional. Where it is not installed this says so and passes,
// because a missing dev dependency should not stop anyone building.
//
// Usage:  node tools/lua-checks/syntax.js <file.lua>
const fs = require("fs");

const file = process.argv[2];
if (!file) {
  console.error("usage: node syntax.js <file.lua>");
  process.exit(2);
}

let luaparse;
try {
  luaparse = require("luaparse");
} catch (e) {
  console.log("SKIP: luaparse is not installed (npm install luaparse to enable)");
  process.exit(0);
}

const src = fs.readFileSync(file, "utf8");
try {
  luaparse.parse(src, { luaVersion: "5.1", comments: false });
} catch (err) {
  // luaparse reports a line; show it with its neighbours, which is what tells
  // you whether the mistake is on that line or the one that opened it
  const line = err.line || 0;
  console.error("SYNTAX ERROR: " + err.message);
  if (line > 0) {
    const lines = src.split(/\r?\n/);
    for (let n = Math.max(1, line - 3); n <= Math.min(lines.length, line + 2); n++) {
      console.error((n === line ? " >" : "  ") + String(n).padStart(6) + "  " + lines[n - 1]);
    }
  }
  process.exit(1);
}

console.log("OK: parses as Lua 5.1");
