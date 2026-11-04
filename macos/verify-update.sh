#!/bin/sh
# What macos/verify-release.sh can't check headless, on a CI runner: the
# release launches for real from a clean Mac (the first run's welcome, the
# hotkey, the menu bar), the release before it updates itself to this one and
# comes back, and a feed that lies is refused.
#
#   sh macos/verify-update.sh v0.2.6 v0.2.7
#
# It shows windows and replaces /Applications/Nanolight.app, so it runs only
# where CI is set. A launcher started with `open` gets the environment `open
# --env` gives it, so the new copy, restarted by the updater, reads the real
# feed: TO must be the newest release, or it would update again.
set -eu
[ "${CI:-}" = true ] || {
    echo "verify-update.sh shows windows and replaces the installed app: CI runners only" >&2
    exit 2
}

from=${1:?usage: sh macos/verify-update.sh vOLD vNEW}
to=${2:?usage: sh macos/verify-update.sh vOLD vNEW}
from_version=${from#v}
to_version=${to#v}
releases=https://github.com/justrach/nanolight/releases/download
asset=nanolight-macos-arm64.zip
app=/Applications/Nanolight.app
bin="$app/Contents/MacOS/nanolight"
cache="$HOME/Library/Caches/Nanolight"
team=WWP9DLJ27P
port=8765
shots=${SHOTS:-/tmp/nanolight-shots}
mkdir -p "$shots"

work=$(mktemp -d /tmp/nanolight-update.XXXXXX)
work=$(cd "$work" && pwd -P)
server=
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; pkill -f "^$bin" 2>/dev/null; rm -rf "$work"' EXIT
cd /

die() {
    {
        echo "FAIL  $*"
        crashes=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/*anolight* 2>/dev/null | head -1 || true)
        if [ -n "$crashes" ]; then
            echo "--- $crashes"
            head -60 "$crashes"
        fi
    } >&2
    shot failed
    exit 1
}
ok() { echo "ok    $*"; }
shot() { screencapture -x "$shots/$(sw_vers -productVersion)-$1.png" 2>/dev/null || true; }

running() { pgrep -f "^$bin" 2>/dev/null | head -1 || true; }
installed() { plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist"; }

stop() {
    pkill -f "^$bin" 2>/dev/null || true
    n=0
    while [ -n "$(running)" ] && [ "$n" -lt 20 ]; do
        sleep 0.5
        n=$((n + 1))
    done
    [ -z "$(running)" ] || die "the app won't stop"
}

zip_of() { # tag: its update, fetched once
    z="$work/$1.zip"
    [ -f "$z" ] || curl -fsSL --retry 3 -o "$z" "$releases/$1/$asset"
    echo "$z"
}

install() { # tag, as a person drags it to Applications
    stop
    rm -rf "$app" "$cache"
    t=$(mktemp -d "$work/unpack.XXXXXX")
    ditto -x -k "$(zip_of "$1")" "$t"
    ditto "$t/Nanolight.app" "$app"
    rm -rf "$t"
    [ "$(installed)" = "${1#v}" ] || die "installed $(installed), not $1"
}

launch() { # the feed it reads
    open --env "NANOUI_UPDATE_FEED=$1" "$app"
    n=0
    while [ -z "$(running)" ]; do
        n=$((n + 1))
        [ "$n" -le 60 ] || die "it never started"
        sleep 0.5
    done
    running
}

trusted() { # the app's copy in Applications, as the system sees it
    codesign --verify --deep --strict "$app" || die "signature broken"
    codesign -dv --verbose=2 "$app" 2>&1 | grep -q "TeamIdentifier=$team" || die "not signed by $team"
    a=$(spctl -a -vvv -t exec "$app" 2>&1) || die "Gatekeeper: $a"
    echo "$a" | grep -q 'source=Notarized Developer ID' || die "Gatekeeper: $a"
    try=1
    until xcrun stapler validate "$app" >/dev/null 2>&1; do
        [ "$try" -lt 5 ] || die "no ticket stapled"
        sleep $((try * 10))
        try=$((try + 1))
    done
}

# ----- a clean Mac's first launch -----

echo "== $to, first launch"
install "$to"
pid=$(launch "$releases/$to")
# Past the first update check (20 s), which finds nothing newer.
sleep 25
shot first-launch
[ "$(running)" = "$pid" ] || die "$to died within 25 s of its first launch"
[ "$(installed)" = "$to_version" ] || die "$to replaced itself with $(installed)"
trusted
ok "$to launches from a clean install and stays up"

# ----- a feed that lies -----

# A release newer than anything, whose download must be refused. Run
# from the older copy, so the only thing that could change it is this feed.
feed_of() { # dir, sha256 for the manifest (or "right")
    sum=$2
    [ "$sum" != right ] || sum=$(shasum -a 256 "$1/$asset" | cut -d' ' -f1)
    printf '{"version":"99.0.0","files":{"%s":{"sha256":"%s"}}}\n' "$asset" "$sum" >"$1/manifest.json"
}

refused() { # what's wrong, dir
    echo "== $from refuses: $1"
    install "$from"
    python3 -I -u -m http.server "$port" --bind 127.0.0.1 --directory "$2" >"$work/server.log" 2>&1 &
    server=$!
    sleep 1
    pid=$(launch "http://127.0.0.1:$port")
    n=0
    until grep -q "GET /$asset" "$work/server.log"; do
        n=$((n + 1))
        [ "$n" -le 120 ] || {
            cat "$work/server.log"
            die "$from never asked for the update"
        }
        sleep 1
    done
    # Time to verify it, and for a restart (10 s away) if it had taken it.
    sleep 25
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
    server=
    [ "$(installed)" = "$from_version" ] || die "took a bad update ($1): installed $(installed)"
    [ "$(running)" = "$pid" ] || die "$from restarted or died on a bad update ($1)"
    [ ! -e "$cache/updates/99.0.0" ] || die "kept a bad update ($1) in its cache"
    ok "$from refused it, and kept nothing"
}

sums="$work/feed-sum"
mkdir "$sums"
cp "$(zip_of "$to")" "$sums/$asset"
feed_of "$sums" 0000000000000000000000000000000000000000000000000000000000000000
refused "a checksum that doesn't match" "$sums"

names="$work/feed-name"
mkdir "$names"
cp "$(zip_of "$to")" "$names/$asset"
feed_of "$names" right
refused "a real build that isn't the version named" "$names"

other="$work/feed-other"
mkdir "$other"
t=$(mktemp -d "$work/unpack.XXXXXX")
ditto -x -k "$(zip_of "$to")" "$t"
plutil -replace CFBundleShortVersionString -string 99.0.0 "$t/Nanolight.app/Contents/Info.plist"
codesign --force --deep --sign - "$t/Nanolight.app"
ditto -c -k --keepParent "$t/Nanolight.app" "$other/$asset"
rm -rf "$t"
feed_of "$other" right
refused "a build not signed by the team" "$other"

# ----- the update -----

echo "== $from updates itself to $to"
install "$from"
old=$(launch "$releases/$to")
start=$(date +%s)
# First check at 20 s; then it waits to be out of sight, or for nobody to be
# at the Mac (5 minutes with no input): at worst, a little over 5 minutes.
until [ "$(installed 2>/dev/null || true)" = "$to_version" ]; do
    [ $(($(date +%s) - start)) -le 480 ] || die "still $(installed) after 8 minutes"
    [ "$(running)" = "$old" ] || [ -n "$(running)" ] || die "$from died before updating"
    sleep 2
done
ok "swapped in $to after $(($(date +%s) - start)) s"
n=0
until new=$(running) && [ -n "$new" ] && [ "$new" != "$old" ]; do
    n=$((n + 1))
    [ "$n" -le 60 ] || die "$to didn't come back after the update"
    sleep 1
done
ok "came back on its own, as $to"
# Past its own first update check: it must not update, or restart, again.
sleep 30
shot updated
[ "$(running)" = "$new" ] || die "$to died or restarted after updating"
[ "$(installed)" = "$to_version" ] || die "went on to $(installed) after updating"
[ "$("$bin" --version)" = "nanolight $to_version" ] || die "the program says $("$bin" --version)"
trusted
[ -z "$(xattr -r "$app" 2>/dev/null | grep com.apple.quarantine)" ] || die "the update came quarantined: macOS would ask on its next launch"
[ -z "$(ls -A /Applications | grep '^\.Nanolight')" ] || die "left copies in Applications: $(ls -A /Applications | grep '^\.Nanolight')"
[ ! -e "$cache/updates/$to_version" ] || die "left the update in its cache"
ok "the update is notarized, unquarantined, and left nothing behind"
echo
echo "$from -> $to: all checks passed"
