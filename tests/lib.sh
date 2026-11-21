#!/usr/bin/env bash
# Shared fixture for the helper tests. Source it from a test script.
#
# `curl` and `python3` are replaced by shims that record their argv. The curl
# shim also records the config it receives on stdin and answers from canned
# payloads. Python's HTTPS handler is patched through sitecustomize so the
# Web API calls made from python are answered locally and recorded with their
# Authorization header. Payloads that depend on the account embed the bearer
# token they were requested with, so tests can tell accounts apart. Network
# access is blocked through an unreachable proxy so nothing leaves the machine.
#
# Environment understood by the fake HTTPS handler:
#   FAKE_REDIRECT_TO   answer every api.spotify.com request with a 302 to this URL

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../bin/spotify-plugin"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REAL_PYTHON="$(command -v python3)"
PRIVATE_ARTIST="ARTIST-PRIVATE-Q7"
PRIVATE_TRACK="TRACK-PRIVATE-Q9"
PRIVATE_PLAYLIST="PLAYLIST-PRIVATE-Q3"
SEARCH_RESULT="SEARCH-RESULT-Q1"

mkdir -p "$SCRATCH/bin" "$SCRATCH/run" "$SCRATCH/py"
ARGV_LOG="$SCRATCH/argv.log"
STDIN_LOG="$SCRATCH/stdin.log"
HTTP_LOG="$SCRATCH/http.log"
OUT_LOG="$SCRATCH/out.log"
: >"$ARGV_LOG"
: >"$STDIN_LOG"
: >"$HTTP_LOG"

cat >"$SCRATCH/bin/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"$ARGV_LOG"
cfg=""
for a in "\$@"; do
  if [[ "\$a" == "-" ]]; then cfg=\$(cat); printf '%s\n' "\$cfg" >>"$STDIN_LOG"; fi
done
case "\$* \$cfg" in
  *accounts.spotify.com*) echo '{"access_token": "tok-from-client-credentials"}' ;;
  *http_code*) printf '204' ;;
  *v1/search*)
    echo '{"tracks": {"items": [{"name": "$SEARCH_RESULT", "artists": [{"name": "A"}], "album": {"name": "B"}, "uri": "spotify:track:s", "id": "s"}]}}'
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

cat >"$SCRATCH/py/sitecustomize.py" <<EOF
import email.message, io, os, urllib.request, urllib.response

LOG = "$HTTP_LOG"
ARTIST = "$PRIVATE_ARTIST"
TRACK = "$PRIVATE_TRACK"


def _respond(req, code, body, location=None):
    headers = email.message.Message()
    headers["Content-Type"] = "application/json"
    if location:
        headers["Location"] = location
    resp = urllib.response.addinfourl(io.BytesIO(body.encode()), headers, req.full_url, code)
    resp.msg = "OK" if code == 200 else "Found"
    return resp


def _fake_https_open(self, req):
    url = req.full_url
    auth = req.get_header("Authorization") or ""
    with open(LOG, "a") as log:
        log.write("%s %s\n" % (url, auth))
    redirect = os.environ.get("FAKE_REDIRECT_TO", "")
    if redirect and url.startswith("https://api.spotify.com/"):
        return _respond(req, 302, "", location=redirect)
    account = auth.rsplit(" ", 1)[-1]
    if "me/top/artists" in url:
        body = '{"items": [{"name": "%s for %s", "uri": "spotify:artist:a", "id": "a", "images": [], "genres": []}]}' % (ARTIST, account)
    elif "top-tracks" in url:
        body = '{"tracks": [{"name": "%s for %s", "uri": "spotify:track:t", "artists": [{"name": "A"}], "album": {"name": "B"}, "duration_ms": 1}]}' % (TRACK, account)
    else:
        body = "{}"
    return _respond(req, 200, body)


urllib.request.HTTPSHandler.https_open = _fake_https_open
EOF

# run <VAR=value...> <command...>: run with the shims, stdout+stderr to OUT_LOG.
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
    echo "FAIL: $label is missing from the output:"
    sed 's/^/  /' "$OUT_LOG"
    fail=1
  fi
}
check_not_in_output() {
  local label="$1" value="$2"
  if grep -qF -- "$value" "$OUT_LOG"; then
    echo "FAIL: $label appears in the output:"
    sed 's/^/  /' "$OUT_LOG"
    fail=1
  fi
}

finish() {
  if [[ "$fail" -eq 0 ]]; then echo "PASS: $1"; fi
  exit "$fail"
}
