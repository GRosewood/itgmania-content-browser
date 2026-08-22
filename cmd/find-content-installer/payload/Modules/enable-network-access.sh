#!/usr/bin/env bash
# One-time setup for the SMO Find Content module (Linux / macOS).
#
# ITGmania deliberately prevents themes from granting themselves network
# access: HttpEnabled/HttpAllowHosts are immutable preferences and the
# preference files are write-protected inside the game. So the machine's owner
# authorizes it from outside the game — that's this script.
#
# It adds stepmaniaonline.net to the HttpAllowHosts line in Preferences.ini
# (keeping every host already listed) and sets HttpEnabled=1. A timestamped
# backup is written next to the file.
#
# Usage:  bash "enable-network-access.sh"     (with ITGmania closed)

set -euo pipefail

NEW_HOSTS=("stepmaniaonline.net" "*.stepmaniaonline.net")

die() { printf '\n  %s\n\n' "$1" >&2; exit 1; }

printf '\n  SMO Find Content - enable network access\n'
printf '  ----------------------------------------\n\n'

# The game rewrites Preferences.ini from memory on exit, so edits made while it
# is running would be discarded.
if pgrep -x itgmania >/dev/null 2>&1 || pgrep -x ITGmania >/dev/null 2>&1; then
    die "ITGmania is running. Close it completely, then run this again."
fi

# This script lives in <install>/Themes/Simply Love/Modules/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

CANDIDATES=(
    "$INSTALL_ROOT/Save/Preferences.ini"
    "$HOME/.itgmania/Save/Preferences.ini"
    "$HOME/Library/Application Support/ITGmania/Save/Preferences.ini"
)

PREFS=""
for candidate in "${CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then PREFS="$candidate"; break; fi
done
[ -n "$PREFS" ] || die "Could not find Preferences.ini. Looked in: ${CANDIDATES[*]}"

printf '  Preferences file:\n    %s\n\n' "$PREFS"

BACKUP="$PREFS.bak-$(date +%Y%m%d-%H%M%S)"
cp "$PREFS" "$BACKUP"

python3 - "$PREFS" "${NEW_HOSTS[@]}" <<'PY'
import sys, re

path, new_hosts = sys.argv[1], sys.argv[2:]
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    lines = fh.read().splitlines()

def merge(current):
    out, seen = [], set()
    for host in current.split(","):
        host = host.strip()
        if host and host.lower() not in seen:
            seen.add(host.lower())
            out.append(host)
    for host in new_hosts:
        if host.lower() not in seen:
            seen.add(host.lower())
            out.append(host)
    return ",".join(out)

changed = saw_hosts = saw_enabled = False
result = []
for line in lines:
    m = re.match(r"\s*HttpAllowHosts\s*=(.*)$", line)
    if m:
        saw_hosts = True
        merged = merge(m.group(1))
        if merged != m.group(1).strip():
            changed = True
        result.append("HttpAllowHosts=" + merged)
        continue
    m = re.match(r"\s*HttpEnabled\s*=\s*(.*)$", line)
    if m:
        saw_enabled = True
        if m.group(1).strip() != "1":
            changed = True
        result.append("HttpEnabled=1")
        continue
    result.append(line)

if not saw_hosts or not saw_enabled:
    rebuilt, inserted = [], False
    for line in result:
        rebuilt.append(line)
        if not inserted and re.match(r"\s*\[Options\]\s*$", line):
            if not saw_hosts:
                rebuilt.append("HttpAllowHosts=" + merge(""))
            if not saw_enabled:
                rebuilt.append("HttpEnabled=1")
            inserted = changed = True
    if not inserted:
        sys.exit("Preferences.ini has no [Options] section - it may be corrupt.")
    result = rebuilt

if changed:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(result) + "\n")
    print("  Done.")
    print("    stepmaniaonline.net added to HttpAllowHosts")
    print("    HttpEnabled=1")
else:
    print("  Already set up - stepmaniaonline.net is allowed.")
PY

printf '    backup saved as %s\n\n' "$(basename "$BACKUP")"
printf '  Start ITGmania and open Find Content from the title menu.\n\n'
