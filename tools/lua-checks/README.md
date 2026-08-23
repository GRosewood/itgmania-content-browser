# Lua checks

Two things about the module break at load time, produce errors that name only a
line number, and are caught by no ordinary linter. Both are Lua 5.1 limits the
module now sits close to.

    node tools/lua-checks/blocks.js   "cmd/content-browser-installer/payload/Modules/ITGmania Content Browser.lua"
    node tools/lua-checks/upvalues.js "cmd/content-browser-installer/payload/Modules/ITGmania Content Browser.lua"

**blocks.js** tokenises the file and checks that every `function`/`if`/`for`
opens and closes. A stray `end` is otherwise reported against whatever line the
parser gave up on.

**upvalues.js** counts, per top-level function, how many enclosing-scope locals
it names. Lua allows 60 (`LUAI_MAXUPVALUES`) and charges one per distinct name
mentioned anywhere inside -- nested closures included, since the outer function
has to capture a value to pass it down.

`BrowserActor` builds the entire screen and sits at the ceiling. Adding one more
file-level local *anywhere* inside it stops the module loading, with:

    Error loading module: ... function at line NNNN has more than 60 upvalues

The fix is never to add a local: reach through a table that is already an
upvalue (`state`, `LO`, `Snd`), or work the value out in a top-level function
where there is room. The tool prints the names mentioned exactly once, which are
the cheapest to route somewhere else.

There is also a 200-local limit per chunk (`LUAI_MAXVARS`); `grep -c '^local '`
on the module is a good enough proxy, and it is at 199.
