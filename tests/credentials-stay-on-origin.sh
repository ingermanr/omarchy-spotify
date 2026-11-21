#!/usr/bin/env bash
# Regression test: credential-bearing requests use verified HTTPS and never
# leave api.spotify.com / accounts.spotify.com.
#
# - Every curl call starts with `-q`, so ~/.curlrc cannot turn off certificate
#   checks (`insecure`) or forward credentials on redirects (`location-trusted`),
#   and restricts the protocol to HTTPS.
# - The python Web API client refuses redirects, so a response cannot send the
#   bearer token to another origin.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOKEN="tok-SECRET-1234567890"
EVIL="https://evil.example/collect"

for args in "search radiohead" "playlists" "artists" "top-tracks abc123" \
  "play-uri spotify:album:x" "play-tracks spotify:track:a spotify:track:b"; do
  # shellcheck disable=SC2086
  run SPOTIFY_ACCESS_TOKEN="$TOKEN" "$HELPER" $args
done
rm -f "$SCRATCH/run"/*
run SPOTIFY_CLIENT_ID="cid" SPOTIFY_CLIENT_SECRET="csec" "$HELPER" search radiohead

if ! grep -q '^curl ' "$ARGV_LOG"; then
  echo "FAIL: no curl call was recorded, so the check below proves nothing"
  fail=1
fi
unsafe=$(grep '^curl ' "$ARGV_LOG" | grep -v '^curl -q --proto =https --proto-redir =https ' || true)
if [[ -n "$unsafe" ]]; then
  echo "FAIL: curl calls that may load ~/.curlrc or allow non-HTTPS:"
  printf '%s\n' "$unsafe" | sed 's/^/  /'
  fail=1
fi

# A redirecting Web API response must not receive the bearer token elsewhere.
rm -f "$SCRATCH/run"/*
: >"$HTTP_LOG"
run SPOTIFY_ACCESS_TOKEN="$TOKEN" FAKE_REDIRECT_TO="$EVIL" "$HELPER" artists
run SPOTIFY_ACCESS_TOKEN="$TOKEN" FAKE_REDIRECT_TO="$EVIL" "$HELPER" top-tracks abc123
if ! grep -q '^https://api.spotify.com/' "$HTTP_LOG"; then
  echo "FAIL: no Web API request was recorded, so the check below proves nothing"
  fail=1
fi
if grep -q 'evil.example' "$HTTP_LOG"; then
  echo "FAIL: a redirect was followed to another origin:"
  grep 'evil.example' "$HTTP_LOG" | sed 's/^/  /'
  fail=1
fi

finish "credential-bearing requests stay on verified HTTPS and the Spotify origin"
