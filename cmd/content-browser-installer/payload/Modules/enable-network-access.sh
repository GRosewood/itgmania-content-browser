#!/usr/bin/env bash
# One-time setup for the ITGMania Content Browser module (Linux / macOS).
#
# ITGmania will not let a theme grant itself network access: HttpEnabled and
# HttpAllowHosts are immutable preferences and the preference files are
# write-protected inside the game. So the machine's owner authorizes it from
# outside the game - that's this script.
#
# It adds stepmaniaonline.net to the HttpAllowHosts line in Preferences.ini
# (keeping every host already listed) and sets HttpEnabled=1. A timestamped
# backup is written next to the file.
#
# Only POSIX tools are used (awk), so it works on a stock macOS or a minimal
# Linux install with no Python.
#
# Usage:  bash "enable-network-access.sh"     (with ITGmania closed)

set -uo pipefail

# Every host the browser reads. Both spellings of each: the engine's wildcard
# does not match the bare domain -- "*.example.net" allows "www.example.net"
# and refuses "example.net" -- so a list with only one of the two silently
# half-works. itgdb.net was missing here for exactly that reason and took the
# doubles-pack list with it.
NEW_HOSTS="stepmaniaonline.net,*.stepmaniaonline.net,arrowcloud.dance,*.arrowcloud.dance,itgdb.net,*.itgdb.net"

die() { printf '\n  %s\n\n' "$1" >&2; exit 1; }

printf '\n  ITGMania Content Browser - enable network access\n'
printf '  -----------------------------------------------\n\n'

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
[ -w "$PREFS" ] || die "$PREFS is not writable."

TMP="$PREFS.tmp.$$"
trap 'rm -f "$TMP"' EXIT

# awk does the merge: preserve every existing host and every other line,
# force HttpEnabled=1, and insert either key under [Options] if it is absent.
awk -v newhosts="$NEW_HOSTS" '
function merge(current,   n, i, j, seen, out, parts, host, extra, m, k) {
    n = split(current, parts, ",")
    out = ""
    for (i = 1; i <= n; i++) {
        host = parts[i]
        gsub(/^[ \t]+|[ \t]+$/, "", host)
        if (host == "") continue
        k = tolower(host)
        if (k in seen) continue
        seen[k] = 1
        out = (out == "" ? host : out "," host)
    }
    m = split(newhosts, extra, ",")
    for (j = 1; j <= m; j++) {
        host = extra[j]
        gsub(/^[ \t]+|[ \t]+$/, "", host)
        k = tolower(host)
        if (k in seen) continue
        seen[k] = 1
        out = (out == "" ? host : out "," host)
        changed = 1
    }
    return out
}
BEGIN { changed = 0; sawhosts = 0; sawenabled = 0; inserted = 0 }
{
    line = $0
    trimmed = line
    gsub(/^[ \t]+/, "", trimmed)
    lower = tolower(trimmed)

    if (index(lower, "httpallowhosts=") == 1) {
        sawhosts = 1
        eq = index(line, "=")
        print "HttpAllowHosts=" merge(substr(line, eq + 1))
        next
    }
    if (index(lower, "httpenabled=") == 1) {
        sawenabled = 1
        eq = index(line, "=")
        val = substr(line, eq + 1)
        gsub(/^[ \t]+|[ \t\r]+$/, "", val)
        if (val != "1") changed = 1
        print "HttpEnabled=1"
        next
    }
    print line
    # Remember where [Options] was so missing keys can be added after it.
    if (lower ~ /^\[options\][ \t\r]*$/ && !inserted) {
        optline = NR
        inserted = 1
    }
}
END {
    if (!sawhosts || !sawenabled) exit 9   # signal: needs the insert pass
    exit (changed ? 0 : 1)                 # 0 = changed, 1 = already fine
}
' "$PREFS" > "$TMP"
STATUS=$?

if [ "$STATUS" -eq 9 ]; then
    # One or both keys were missing entirely: add them under [Options].
    awk -v newhosts="$NEW_HOSTS" '
    BEGIN { done = 0 }
    {
        print $0
        line = tolower($0)
        gsub(/^[ \t]+|[ \t\r]+$/, "", line)
        if (!done && line == "[options]") {
            print "HttpEnabled=1"
            print "HttpAllowHosts=" newhosts
            done = 1
        }
    }
    END { if (!done) exit 1 }
    ' "$PREFS" > "$TMP" || die "Preferences.ini has no [Options] section - it may be corrupt."
    STATUS=0
fi

if [ "$STATUS" -eq 1 ]; then
    printf '  Already set up - stepmaniaonline.net is allowed.\n'
    printf '  Start ITGmania and open Find Content from the title menu.\n\n'
    exit 0
fi

BACKUP="$PREFS.bak-$(date +%Y%m%d-%H%M%S)"
cp "$PREFS" "$BACKUP" || die "Could not write a backup next to Preferences.ini."
cat "$TMP" > "$PREFS" || die "Could not write $PREFS."

# Never claim success without reading the file back.
if grep -qi '^[[:space:]]*HttpAllowHosts=.*stepmaniaonline\.net' "$PREFS" &&
   grep -qi '^[[:space:]]*HttpEnabled=1' "$PREFS"; then
    printf '  Done.\n'
    printf '    stepmaniaonline.net added to HttpAllowHosts\n'
    printf '    HttpEnabled=1\n'
    printf '    backup saved as %s\n\n' "$(basename "$BACKUP")"
    printf '  Start ITGmania and open Find Content from the title menu.\n\n'
else
    cp "$BACKUP" "$PREFS"
    die "The allowlist could not be written; Preferences.ini was restored from the backup."
fi
