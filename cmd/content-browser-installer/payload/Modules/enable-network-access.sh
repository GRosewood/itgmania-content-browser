#!/usr/bin/env bash
# One-time setup for the ITGMania Content Browser module (Linux / macOS).
#
# ITGmania will not let a theme grant itself network access: HttpEnabled and
# HttpAllowHosts are immutable preferences and the preference files are
# write-protected inside the game. So the machine's owner authorizes it from
# outside the game - that's this script.
#
# It adds every host the browser reaches to the HttpAllowHosts line in Preferences.ini (keeping every
# host already listed) and sets HttpEnabled=1. A timestamped backup is written
# next to the file.
#
# Only POSIX tools are used (awk), so it works on a stock macOS or a minimal
# Linux install with no Python.
#
# Usage:  bash "enable-network-access.sh"     (with ITGmania closed)

set -uo pipefail

# Every host the browser reaches, written directly: the catalogue and its
# artwork, the popularity and doubles sources, the preview relay (localhost
# in development; put a deployed relay's host here or in webapp.txt), and
# the update manifest with its archive host.
#
# Nothing is ever REMOVED from the list -- an existing GrooveStats entry, or
# anything another module added, is left exactly where it is. Taking away
# access somebody else may be relying on is not this script's business.
NEW_HOSTS="stepmaniaonline.net,*.stepmaniaonline.net,arrowcloud.dance,*.arrowcloud.dance,itgdb.net,*.itgdb.net,localhost,127.0.0.1,github.com,*.githubusercontent.com"

report_done() {
    printf '  Start ITGmania and open Find Content from the title menu.\n\n'
}
printf '\n  ITGMania Content Browser - enable network access\n'
printf '  -----------------------------------------------\n\n'

# The game rewrites Preferences.ini from memory on exit, so edits made while it
# is running would be discarded.
#
# Matched loosely on purpose. An exact match on "itgmania" misses the names
# cabinets actually launch under -- itgmania-bin, a wrapper script, a systemd
# unit's exec name -- and missing it is the bad direction: the edit appears to
# work, then vanishes on the next quit with nothing to show why. The cost of
# looseness is matching ourselves, so this script and its own pgrep are
# excluded by name.
if pgrep -i -l itgmania 2>/dev/null |
   grep -viE 'content-browser|enable-network-access|pgrep' |
   grep -q .; then
    die "ITGmania looks like it is running. Close it completely, then run this again."
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
TMP2="$PREFS.tmp2.$$"
trap 'rm -f "$TMP" "$TMP2"' EXIT

# awk does the merge: preserve every existing host and every other line,
# force HttpEnabled=1, and insert either key under [Options] if it is absent.
awk -v newhosts="$NEW_HOSTS" '
function merge(current,   n, i, j, seen, out, parts, host, extra, m, k) {
    n = split(current, parts, ",")
    out = ""
    for (i = 1; i <= n; i++) {
        host = parts[i]
        # \r matters: on a CRLF Preferences.ini read here, the LAST host in the
        # existing list keeps its carriage return, and appending ours after it
        # buries that CR in the middle of the value. The engine splits on ","
        # and compares exactly, so a host belonging to the player silently stops
        # matching anything -- destroyed by a script that only meant to add to it.
        gsub(/^[ \t\r]+|[ \t\r]+$/, "", host)
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

    # Matched with optional space before the "=", the way the engine, the
    # PowerShell script and the Go installer all read it. An exact "key="
    # prefix missed a hand-edited "HttpAllowHosts = foo", which then looked
    # absent and got a SECOND copy appended by the insert pass below.
    if (lower ~ /^httpallowhosts[ \t]*=/) {
        sawhosts = 1
        eq = index(line, "=")
        print "HttpAllowHosts=" merge(substr(line, eq + 1))
        next
    }
    if (lower ~ /^httpenabled[ \t]*=/) {
        sawenabled = 1
        eq = index(line, "=")
        val = substr(line, eq + 1)
        gsub(/^[ \t]+|[ \t\r]+$/, "", val)
        if (val != "1") changed = 1
        print "HttpEnabled=1"
        next
    }
    print line
}
END {
    # Which keys were missing, encoded so the insert pass adds only those.
    # Adding both regardless was the bug this replaces: whichever key DID
    # exist got a second copy, and the engine takes the LAST one it reads
    # (IniFile::SetKeyValue -> XNode::AppendAttr, which overwrites). So an
    # existing "HttpEnabled=0" further down beat the inserted "HttpEnabled=1"
    # and HTTP stayed off, or an existing HttpAllowHosts beat ours and the
    # edit was discarded -- in both cases under a "Done." message, because the
    # read-back at the end matched the inserted line rather than the winning one.
    if (!sawhosts || !sawenabled)
        exit (8 + (sawhosts ? 0 : 1) + (sawenabled ? 0 : 2))
    exit (changed ? 0 : 1)                 # 0 = changed, 1 = already fine
}
' "$PREFS" > "$TMP"
STATUS=$?

if [ "$STATUS" -ge 9 ] && [ "$STATUS" -le 11 ]; then
    # A key was missing entirely: add just that one, under [Options].
    NEED_HOSTS=$(( (STATUS - 8) % 2 ))
    NEED_ENABLED=$(( (STATUS - 8) / 2 ))
    # Reads $TMP, not $PREFS: the first pass already merged whichever key was
    # present, and re-reading the original would throw that work away.
    awk -v newhosts="$NEW_HOSTS" -v need_hosts="$NEED_HOSTS" -v need_enabled="$NEED_ENABLED" '
    BEGIN { done = 0 }
    {
        print $0
        line = tolower($0)
        gsub(/^[ \t]+|[ \t\r]+$/, "", line)
        if (!done && line == "[options]") {
            if (need_enabled) print "HttpEnabled=1"
            if (need_hosts) print "HttpAllowHosts=" newhosts
            done = 1
        }
    }
    END { if (!done) exit 1 }
    ' "$TMP" > "$TMP2" || die "Preferences.ini has no [Options] section - it may be corrupt."
    mv "$TMP2" "$TMP"
    STATUS=0
fi

if [ "$STATUS" -eq 1 ]; then
    printf '  Already set up - every host is allowed and HttpEnabled=1.\n\n'
    report_done
    exit 0
fi

BACKUP="$PREFS.bak-$(date +%Y%m%d-%H%M%S)"
cp "$PREFS" "$BACKUP" || die "Could not write a backup next to Preferences.ini."
cat "$TMP" > "$PREFS" || die "Could not write $PREFS."

# Never claim success without reading the file back -- and read it the way the
# ENGINE does. Asking "is there a line that looks right" is what let the
# duplicate-key bug report success: the inserted line matched while a later one
# quietly overrode it. The engine keeps the LAST occurrence of each key, so the
# last occurrence is what gets checked here.
last_hosts="$(grep -i '^[[:space:]]*HttpAllowHosts[[:space:]]*=' "$PREFS" | tail -1 | tr -d '\r')"
last_enabled="$(grep -i '^[[:space:]]*HttpEnabled[[:space:]]*=' "$PREFS" | tail -1 | tr -d '\r')"

if printf '%s' "$last_hosts" | grep -q '127\.0\.0\.1' &&
   printf '%s' "$last_enabled" | grep -q '=[[:space:]]*1[[:space:]]*$'; then
    printf '  Done.\n'
    printf '    the browser hosts were added to HttpAllowHosts\n'
    printf '    HttpEnabled=1\n'
    printf '    backup saved as %s\n\n' "$(basename "$BACKUP")"
    report_done
else
    cp "$BACKUP" "$PREFS"
    die "The allowlist could not be written; Preferences.ini was restored from the backup."
fi
