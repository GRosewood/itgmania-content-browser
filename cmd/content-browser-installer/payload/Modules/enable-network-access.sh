#!/usr/bin/env bash
# One-time setup for the ITGMania Content Browser module (Linux / macOS).
#
# ITGmania will not let a theme grant itself network access: HttpEnabled and
# HttpAllowHosts are immutable preferences and the preference files are
# write-protected inside the game. So the machine's owner authorizes it from
# outside the game - that's this script.
#
# It adds 127.0.0.1 to the HttpAllowHosts line in Preferences.ini (keeping every
# host already listed) and sets HttpEnabled=1. A timestamped backup is written
# next to the file.
#
# Only POSIX tools are used (awk), so it works on a stock macOS or a minimal
# Linux install with no Python.
#
# Usage:  bash "enable-network-access.sh"     (with ITGmania closed)

set -uo pipefail

# One entry, and it is the loopback address.
#
# This used to write the catalogue hosts -- stepmaniaonline.net and friends --
# because the browser fetched them directly. It does not any more: it talks to
# a small local helper, and the helper does the fetching. So the game needs to
# reach exactly one place, and the six domain entries this used to add were six
# more than the browser needs.
#
# That matters beyond tidiness. HttpAllowHosts is global to the GAME, not to
# this module: every entry on it is reachable by every other theme and module
# on the machine. Keeping it at one loopback address is the whole reason the
# relay exists.
#
# Nothing is ever REMOVED from the list -- an existing GrooveStats entry, or
# the catalogue hosts an older version of this script added, are left exactly
# where they are. Taking away access somebody else may be relying on is not
# this script's business.
NEW_HOSTS="127.0.0.1"

die() { printf '\n  %s\n\n' "$1" >&2; exit 1; }

# Say whether the thing the allowlist points AT is actually there.
#
# One loopback entry with nothing listening on it goes nowhere, so a script that
# ended on "start the game and open Find Content" would be sending people to a
# browser that cannot open. The helper only ever arrives with the installer.
report_helper() {
    helper_dir="$(dirname "$PREFS")/ITGmaniaContentBrowser"
    if [ -f "$helper_dir/content-browser-helper" ]; then
        printf '  The local helper is installed beside it.\n'
        printf '  Start ITGmania and open Find Content from the title menu.\n\n'
        return 0
    fi
    printf '  One thing is still missing: the local helper is not installed,\n'
    printf '  and the browser reaches the internet THROUGH it. An allowlist\n'
    printf '  entry for 127.0.0.1 with nothing listening there goes nowhere.\n\n'
    printf '  Run the installer, which adds the helper and makes this same\n'
    printf '  allowlist edit:\n\n'
    printf '    itgmania-content-browser-installer\n\n'
    printf '  Looked for the helper in:\n    %s\n\n' "$helper_dir"
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
    printf '  Already set up - 127.0.0.1 is allowed and HttpEnabled=1.\n\n'
    report_helper
    exit 0
fi

BACKUP="$PREFS.bak-$(date +%Y%m%d-%H%M%S)"
cp "$PREFS" "$BACKUP" || die "Could not write a backup next to Preferences.ini."
cat "$TMP" > "$PREFS" || die "Could not write $PREFS."

# Never claim success without reading the file back.
if grep -qi '^[[:space:]]*HttpAllowHosts=.*127\.0\.0\.1' "$PREFS" &&
   grep -qi '^[[:space:]]*HttpEnabled=1' "$PREFS"; then
    printf '  Done.\n'
    printf '    127.0.0.1 added to HttpAllowHosts\n'
    printf '    HttpEnabled=1\n'
    printf '    backup saved as %s\n\n' "$(basename "$BACKUP")"
    report_helper
else
    cp "$BACKUP" "$PREFS"
    die "The allowlist could not be written; Preferences.ini was restored from the backup."
fi
