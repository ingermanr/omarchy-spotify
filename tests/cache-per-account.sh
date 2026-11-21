#!/usr/bin/env bash
# Regression test: cached Web API results belong to the credentials that
# fetched them. Switching or clearing the credentials must never show the
# previous account's top artists or top tracks, and drops the old cache.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

A="tok-ACCOUNT-A"
B="tok-ACCOUNT-B"

# Top artists: A, then B, then no credentials.
run SPOTIFY_ACCESS_TOKEN="$A" "$HELPER" artists
check_in_output "account A top artists" "for $A"

run SPOTIFY_ACCESS_TOKEN="$B" "$HELPER" artists
check_in_output "account B top artists" "for $B"
check_not_in_output "account A top artists after switching to B" "for $A"
if grep -qF -- "for $A" "$SCRATCH/run/spotify-plugin-artists.json" 2>/dev/null; then
  echo "FAIL: account A top artists are still cached after switching to B"
  fail=1
fi

run "$HELPER" artists
check_not_in_output "account B top artists without credentials" "for $B"
check_in_output "missing credentials error" "credentials not configured"

# Top tracks: A, then B, then no credentials.
rm -f "$SCRATCH/run"/*
run SPOTIFY_ACCESS_TOKEN="$A" "$HELPER" top-tracks abc123
check_in_output "account A top tracks" "for $A"

run SPOTIFY_ACCESS_TOKEN="$B" "$HELPER" top-tracks abc123
check_in_output "account B top tracks" "for $B"
check_not_in_output "account A top tracks after switching to B" "for $A"

run "$HELPER" top-tracks abc123
check_not_in_output "account B top tracks without credentials" "for $B"

# The same account still gets its cached result.
rm -f "$SCRATCH/run"/*
run SPOTIFY_ACCESS_TOKEN="$A" "$HELPER" artists
: >"$HTTP_LOG"
run SPOTIFY_ACCESS_TOKEN="$A" "$HELPER" artists
check_in_output "account A cached top artists" "for $A"
if grep -q 'me/top/artists' "$HTTP_LOG"; then
  echo "FAIL: the second lookup for the same account did not use the cache"
  fail=1
fi

finish "cached results are scoped to the active credentials"
