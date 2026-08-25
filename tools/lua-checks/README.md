# Lua checks

The in-game module is loaded by the game, not by a compiler you can ask first,
and the things that go wrong with it break at load time and name only a line
number. These catch that class of mistake in about a second.

Run the lot:

    node tools/lua-checks/check.js

That walks every `.lua` in the module payload, runs all four per-file checks on
each, then checks the wiring across the whole set. One line per file, and a
non-zero exit if anything fails. It is the only command you need; the rest are
listed here because check.js runs them and their output is theirs.

## Per file

**syntax.js** parses the file as Lua 5.1 with `luaparse` and reports the first
thing that is not, with three lines of context. It is the strictest of them.
`luaparse` is optional — where it is not installed this says so and passes, so
a missing dev dependency does not stop anyone building. That also means it can
pass silently, which is worth knowing.

**blocks.js** tokenises and checks that every `function`/`if`/`for`/`do` reaches
its `end`, and that no string or long comment is left open. Weaker than
syntax.js, but it needs no npm install, so it is the one that always runs.

**upvalues.js** counts, per top-level function, how many enclosing-scope locals
it names. Lua 5.1 allows 60 (`LUAI_MAXUPVALUES`) and charges one per distinct
name mentioned anywhere inside, nested closures included, because the outer
function has to capture a value to pass it down.

**locals.js** counts the locals a file declares at chunk level against Lua's
limit of 200 (`LUAI_MAXVARS`). It counts names, not lines — `local a, b, c` is
one line and three locals, and a forward declaration is one more.

## Across the set

**wiring.js** reads the load order out of the entry file, then checks that every
`local X = CB.X` at the top of a part was actually set by a part that ran
earlier. Nothing per-file can see this: a name that no earlier part supplies is
simply `nil`, and the failure surfaces much later somewhere that has nothing to
do with the cause.

## What these numbers used to be

Before the module was split into parts it was one chunk of 11,862 lines sitting
at **200 of 200 locals and 59 of 60 upvalues** — both ceilings, at once. Adding
a single file-level local anywhere inside `BrowserActor` stopped the module
loading, with:

    Error loading module: ... function at line NNNN has more than 60 upvalues

and the advice was to never add a local: reach through a table that is already
an upvalue, or find somewhere else to do the work.

Split, the worst file uses 43 locals and 21 upvalues. The limits stopped being
something to design around, which is most of why the split happened. These
checks are now cheap insurance rather than a daily constraint — but they are
what will tell you when a file is filling up again.

Two things to keep in mind if you change how the files are laid out:

- upvalues.js finds top-level functions by looking at column zero, and assumes a
  function's body ends at the first `end` there. Indent a whole file, or wrap it
  in `do ... end`, and every function in it becomes invisible — the check will
  report OK on a file it never measured.
- A low upvalue count is not automatically headroom. If a name left the chunk
  and became a cross-file reference it costs no upvalue slot, but it costs a
  hash lookup at every use instead. The parts deliberately copy what they need
  into locals at the top, which keeps the speed and keeps these numbers honest.
