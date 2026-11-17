#!/usr/bin/env bash
# Regression test: credentials must never appear on the command line of any
# process the helper starts, because /proc/<pid>/cmdline is readable by other
# local users. Credentials may travel through the environment or stdin only.
#
# `curl` and `python3` are replaced by shims that record their argv. The curl
# shim also records the config it receives on stdin, to check that the
# credentials still reach the request. Network access is blocked through an
# unreachable proxy so nothing leaves the machine.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../bin/spotify-plugin"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

TOKEN="tok-SECRET-1234567890"
CLIENT_ID="cid-SECRET-abcdef"
CLIENT_SECRET="csec-SECRET-fedcba"
REAL_PYTHON="$(command -v python3)"

mkdir -p "$SCRATCH/bin" "$SCRATCH/run"
ARGV_LOG="$SCRATCH/argv.log"
STDIN_LOG="$SCRATCH/stdin.log"
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
  *) echo '{}' ;;
esac
EOF

cat >"$SCRATCH/bin/python3" <<EOF
#!/usr/bin/env bash
printf 'python3 %s\n' "\$*" >>"$ARGV_LOG"
exec "$REAL_PYTHON" "\$@"
EOF
chmod +x "$SCRATCH/bin/curl" "$SCRATCH/bin/python3"

run() {
  env PATH="$SCRATCH/bin:$PATH" XDG_RUNTIME_DIR="$SCRATCH/run" \
    https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    "$@" >/dev/null 2>&1 || true
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

check_absent "access token" "$TOKEN"
check_absent "client id" "$CLIENT_ID"
check_absent "client secret" "$CLIENT_SECRET"
check_present "access token" "$TOKEN"
check_present "client secret" "$CLIENT_SECRET"

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: no credentials in process arguments"
fi
exit "$fail"
