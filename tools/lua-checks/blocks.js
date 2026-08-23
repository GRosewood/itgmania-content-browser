#!/usr/bin/env node
// Lightweight Lua 5.1 sanity checker: tokenize + verify block/bracket balance.
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

let i = 0, line = 1;
const n = src.length;
const tokens = [];

function fail(msg, ln) {
  console.error(`ERROR line ${ln}: ${msg}`);
  process.exit(1);
}

const nameRe = /^[A-Za-z_][A-Za-z0-9_]*/;
const numRe = /^(0[xX][0-9a-fA-F]+|\d+\.?\d*([eE][+-]?\d+)?|\.\d+)/;

while (i < n) {
  const c = src[i];
  if (c === "\n") { line++; i++; continue; }
  if (c === " " || c === "\t" || c === "\r") { i++; continue; }

  if (src.startsWith("--", i)) {
    const rest = src.slice(i + 2);
    const m = rest.match(/^\[(=*)\[/);
    if (m) {
      const close = "]" + m[1] + "]";
      const k = src.indexOf(close, i + 2 + m[0].length);
      if (k < 0) fail("unterminated long comment", line);
      for (let j = i; j < k; j++) if (src[j] === "\n") line++;
      i = k + close.length;
    } else {
      const k = src.indexOf("\n", i);
      i = k < 0 ? n : k;
    }
    continue;
  }

  const lm = src.slice(i).match(/^\[(=*)\[/);
  if (lm) {
    const close = "]" + lm[1] + "]";
    const k = src.indexOf(close, i + lm[0].length);
    if (k < 0) fail("unterminated long string", line);
    for (let j = i; j < k; j++) if (src[j] === "\n") line++;
    tokens.push(["<str>", line]);
    i = k + close.length;
    continue;
  }

  if (c === "'" || c === '"') {
    const startLine = line;
    let j = i + 1;
    for (;;) {
      if (j >= n) fail("unterminated string (eof)", startLine);
      if (src[j] === "\\") { j += 2; continue; }
      if (src[j] === "\n") fail("unterminated string (newline)", startLine);
      if (src[j] === c) break;
      j++;
    }
    tokens.push(["<str>", line]);
    i = j + 1;
    continue;
  }

  let m = src.slice(i).match(numRe);
  if (m && (/\d/.test(c) || (c === "." && /\d/.test(src[i + 1] || "")))) {
    tokens.push(["<num>", line]);
    i += m[0].length;
    continue;
  }

  m = src.slice(i).match(nameRe);
  if (m) {
    tokens.push([m[0], line]);
    i += m[0].length;
    continue;
  }

  let matched = false;
  for (const op of ["...", "..", "==", "~=", "<=", ">="]) {
    if (src.startsWith(op, i)) {
      tokens.push([op, line]);
      i += op.length;
      matched = true;
      break;
    }
  }
  if (!matched) {
    tokens.push([c, line]);
    i++;
  }
}

// block balance
const stack = [];
for (const [tok, ln] of tokens) {
  if (tok === "(" || tok === "{" || tok === "[") {
    stack.push([tok, ln]);
  } else if (tok === ")" || tok === "}" || tok === "]") {
    if (!stack.length) fail(`unmatched '${tok}'`, ln);
    const [top, tln] = stack.pop();
    const want = { ")": "(", "}": "{", "]": "[" }[tok];
    if (top !== want) fail(`'${tok}' closes '${top}' from line ${tln}`, ln);
  } else if (tok === "function" || tok === "if" || tok === "while" || tok === "for" || tok === "repeat") {
    stack.push([tok, ln]);
  } else if (tok === "do") {
    if (stack.length && (stack[stack.length - 1][0] === "while" || stack[stack.length - 1][0] === "for")) {
      stack[stack.length - 1][0] += "*"; // entered the loop body
    } else {
      stack.push(["do", ln]);
    }
  } else if (tok === "then") {
    if (!stack.length || (stack[stack.length - 1][0] !== "if" && stack[stack.length - 1][0] !== "elseif")) {
      fail("'then' without matching 'if'", ln);
    }
    stack[stack.length - 1][0] = "if*";
  } else if (tok === "elseif") {
    if (!stack.length || stack[stack.length - 1][0] !== "if*") fail("'elseif' without open 'if'", ln);
    stack[stack.length - 1][0] = "elseif";
  } else if (tok === "until") {
    if (!stack.length || stack[stack.length - 1][0] !== "repeat*" ) {
      if (!stack.length || stack[stack.length - 1][0] !== "repeat") fail("'until' without 'repeat'", ln);
    }
    stack.pop();
  } else if (tok === "end") {
    if (!stack.length) fail("unmatched 'end'", ln);
    const [top, tln] = stack.pop();
    if (top === "(" || top === "{" || top === "[") {
      fail(`'end' inside unclosed '${top}' from line ${tln}`, ln);
    }
    if (top === "if" || top === "elseif") fail(`'${top}' from line ${tln} closed by 'end' without 'then'`, ln);
    if (top === "while" || top === "for") fail(`'${top}' from line ${tln} closed by 'end' without 'do'`, ln);
  }
}

if (stack.length) {
  const [top, ln] = stack[stack.length - 1];
  fail(`unclosed '${top}' from line ${ln} at eof`, line);
}

console.log(`OK: ${tokens.length} tokens, blocks balanced`);
