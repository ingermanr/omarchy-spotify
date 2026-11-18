#!/usr/bin/env bash
# Regression test: credentials and private API responses must never appear on
# the command line of any process the helper starts, because
# /proc/<pid>/cmdline is readable by other local users. They may travel through
# the environment or stdin only.
#
# `curl` and `python3` are replaced by shims that record their argv. The curl
# shim also records the config it receives on stdin, to check that the
# credentials still reach the request, and returns private looking payloads so
# the test can prove they never reach an argv. Network access is blocked
# through an unreachable proxy so nothing leaves the machine.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../bin/spotify-plugin"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

TOKEN="tok-SECRET-1234567890"
CLIENT_ID="cid-SECRET-abcdef"
CLIENT_SECRET="csec-SECRET-fedcba"
PRIVATE_ARTIST="ARTIST-PRIVATE-Q7"
PRIVATE_TRACK="TRACK-PRIVATE-Q9"
PRIVATE_PLAYLIST="PLAYLIST-PRIVATE-Q3"
REAL_PYTHON="$(command -v python3)"

mkdir -p "$SCRATCH/bin" "$SCRATCH/run"
ARGV_LOG="$SCRATCH/argv.log"
STDIN_LOG="$SCRATCH/stdin.log"
OUT_LOG="$SCRATCH/out.log"
: >"$ARGV_LOG"
: >"$STDIN_LOG"

cat >"$SCRATCH/bin/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"$ARGV_LOG"
for a in "\$@"; do
  if [[ "\$a" == "-" ]]; then cat >>"$STDIN_LOG"; fi
done
case "\$*" in
  *accounts.spotify.com*) echo '{"access_token": "$TOKEN"}' ;;
  *http_code*) printf '204' ;;
  *me/top/artists*)
    echo '{"items": [{"name": "$PRIVATE_ARTIST", "uri": "spotify:artist:a", "id": "a", "images": [], "genres": []}]}'
    ;;
  *top-tracks*)
    echo '{"tracks": [{"name": "$PRIVATE_TRACK", "uri": "spotify:track:t", "artists": [{"name": "A"}], "album": {"name": "B"}, "duration_ms": 1}]}'
    ;;
  *featured-playlists*)
    echo '{"playlists": {"items": [{"name": "$PRIVATE_PLAYLIST", "owner": {"display_name": "A"}, "uri": "spotify:playlist:p", "id": "p"}]}}'
    ;;
  *) echo '{}' ;;
esac
EOF

cat >"$SCRATCH/bin/python3" <<EOF
#!/usr/bin/env bash
printf 'python3 %s\n' "\$*" >>"$ARGV_LOG"
exec "$REAL_PYTHON" "\$@"
EOF
chmod +x "$SCRATCH/bin/curl" "$SCRATCH/bin/python3"

# The artist and top-tracks lookups call the Web API from inside python, so the
# same private payloads are served by patching urllib in this sitecustomize.
mkdir -p "$SCRATCH/py"
cat >"$SCRATCH/py/sitecustomize.py" <<EOF
import io, urllib.request

ARTIST = "$PRIVATE_ARTIST"
TRACK = "$PRIVATE_TRACK"
PLAYLIST = "$PRIVATE_PLAYLIST"

BODIES = {
    "me/top/artists": '{"items": [{"name": "%s", "uri": "spotify:artist:a", "id": "a", "images": [], "genres": []}]}' % ARTIST,
    "top-tracks": '{"tracks": [{"name": "%s", "uri": "spotify:track:t", "artists": [{"name": "A"}], "album": {"name": "B"}, "duration_ms": 1}]}' % TRACK,
    "featured-playlists": '{"playlists": {"items": [{"name": "%s", "owner": {"display_name": "A"}, "uri": "spotify:playlist:p", "id": "p"}]}}' % PLAYLIST,
}

def fake_urlopen(request, *args, **kwargs):
    url = getattr(request, "full_url", str(request))
    for fragment, body in BODIES.items():
        if fragment in url:
            return io.StringIO(body)
    return io.StringIO("{}")

urllib.request.urlopen = fake_urlopen
EOF

run() {
  env PATH="$SCRATCH/bin:$PATH" PYTHONPATH="$SCRATCH/py" \
    XDG_RUNTIME_DIR="$SCRATCH/run" \
    https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    "$@" >"$OUT_LOG" 2>&1 || true
}

fail=0
check_absent() {
  local label="$1" secret="$2"
  if grep -qF -- "$secret" "$ARGV_LOG"; then
    echo "FAIL: $label appears in a process argv:"
    grep -F -- "$secret" "$ARGV_LOG" | sed 's/^/  /'
    fail=1
  fi
}
check_present() {
  local label="$1" secret="$2"
  if ! grep -qF -- "$secret" "$STDIN_LOG"; then
    echo "FAIL: $label was not passed to curl on stdin"
    fail=1
  fi
}
check_in_output() {
  local label="$1" value="$2"
  if ! grep -qF -- "$value" "$OUT_LOG"; then
    echo "FAIL: $label never reached the caller, so the check above proves nothing"
    fail=1
  fi
}

# Bearer token path: every command that calls the Web API.
for args in "search radiohead" "playlists" "artists" "top-tracks abc123" \
  "play-uri spotify:album:x" "play-tracks spotify:track:a spotify:track:b"; do
  # shellcheck disable=SC2086
  run SPOTIFY_ACCESS_TOKEN="$TOKEN" SPOTIFY_ARTISTS="Radiohead" "$HELPER" $args
done

# Client credentials path: the token is fetched from accounts.spotify.com.
rm -f "$SCRATCH/run"/*
run SPOTIFY_CLIENT_ID="$CLIENT_ID" SPOTIFY_CLIENT_SECRET="$CLIENT_SECRET" \
  "$HELPER" search radiohead

# Private response data still has to reach the caller while staying off argv.
rm -f "$SCRATCH/run"/*
run SPOTIFY_ACCESS_TOKEN="$TOKEN" "$HELPER" artists
check_in_output "top artists response" "$PRIVATE_ARTIST"
run SPOTIFY_ACCESS_TOKEN="$TOKEN" "$HELPER" top-tracks abc123
check_in_output "top tracks response" "$PRIVATE_TRACK"
run SPOTIFY_ACCESS_TOKEN="$TOKEN" "$HELPER" playlists
check_in_output "playlists response" "$PRIVATE_PLAYLIST"

check_absent "access token" "$TOKEN"
check_absent "client id" "$CLIENT_ID"
check_absent "client secret" "$CLIENT_SECRET"
check_absent "top artists response" "$PRIVATE_ARTIST"
check_absent "top tracks response" "$PRIVATE_TRACK"
check_absent "playlists response" "$PRIVATE_PLAYLIST"
check_present "access token" "$TOKEN"
check_present "client secret" "$CLIENT_SECRET"

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: no credentials or API responses in process arguments"
fi
exit "$fail"
