#!/usr/bin/env bash
# Regression test: credentials, private API responses and the search query must
# never appear on the command line of any process the helper starts, because
# /proc/<pid>/cmdline is readable by other local users. They may travel through
# the environment or stdin only.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOKEN="tok-SECRET-1234567890"
CLIENT_ID="cid-SECRET-abcdef"
CLIENT_SECRET="csec-SECRET-fedcba"
QUERY="QUERY-PRIVATE-Q5"

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

# The widget sends the search query on stdin (`search -`).
printf '%s\n' "$QUERY" | run SPOTIFY_ACCESS_TOKEN="$TOKEN" "$HELPER" search -
check_in_output "search results" "$SEARCH_RESULT"

check_absent "access token" "$TOKEN"
check_absent "client id" "$CLIENT_ID"
check_absent "client secret" "$CLIENT_SECRET"
check_absent "top artists response" "$PRIVATE_ARTIST"
check_absent "top tracks response" "$PRIVATE_TRACK"
check_absent "playlists response" "$PRIVATE_PLAYLIST"
check_absent "search query" "$QUERY"
check_present "access token" "$TOKEN"
check_present "client secret" "$CLIENT_SECRET"
check_present "search query" "$QUERY"

finish "no credentials, API responses or search queries in process arguments"
