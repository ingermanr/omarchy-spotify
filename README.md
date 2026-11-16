# Spotify for Omarchy

Bar widget for [Omarchy](https://omarchy.org/) Quattro that controls the
official Spotify client and adds quick search from the bar.

## What it does

- **Bar icon**: dimmed when Spotify is not running, normal when paused, bright
  while playing.
- **Left click**: launch Spotify when it is not running, otherwise open the
  panel. **Right click**: toggle play/pause.
- **Panel**: current track (title, artist, album), previous / play-pause /
  next, a launch button, a track search box, a *Main artists* list with each
  artist's most popular tracks, and a list of featured playlists.
- **Playback control needs no account.** It goes through Mpris/D-Bus, so
  play/pause/next/previous and the current track work out of the box.
- **Search, artists and playlists** use the Spotify Web API and need
  credentials.

Everything runs through `bin/spotify-plugin`, a bash helper shipped inside this
plugin. The QML resolves it relative to `Panel.qml`, so the plugin is
self-contained and works wherever it is installed.

## Requirements

- Omarchy Quattro (4.x) with the `omarchy plugin` commands.
- The official Spotify client installed as `spotify`, and running for playback
  control.
- `curl`, `jq`, `python3` and `gdbus` (part of glib2).
- Spotify API credentials, only for search, main artists and playlists.

## Install

```bash
omarchy plugin add https://github.com/ingermanr/omarchy-spotify --enable
```

Validate the folder at any time:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.ingermanr.spotify
```

## Credentials

Search, main artists and playlists need a Client ID and Client Secret from
<https://developer.spotify.com/dashboard>. Set them in the widget settings.

> **These values are stored in plain text** in `~/.config/omarchy/shell.json`.
> Use a dedicated Spotify app for this widget and do not reuse a secret you
> also keep somewhere sensitive. Playback control keeps working with the
> credential fields empty.

A bearer token can be configured instead of the client credentials. A token
created with the `user-modify-playback-state` scope is also what allows the
panel to start playback; without it, *Play* opens the item in the Spotify
client.

## Settings

| Key | Default | Description |
| --- | --- | --- |
| `refreshIntervalSec` | `5` | Status polling interval in seconds (2–300). |
| `favoriteArtists` | empty | Comma-separated artists for the *Main artists* list. Empty uses your personal top artists when a user token is configured. |
| `spotifyClientId` | empty | Spotify app Client ID. |
| `spotifyClientSecret` | empty | Spotify app Client Secret, stored in plain text. |
| `spotifyAccessToken` | empty | Optional bearer token used directly instead of the client credentials flow. |

## Removal

```bash
omarchy plugin remove io.github.ingermanr.spotify
```

Removal deletes the plugin folder. Cached artist and track data lives in your
runtime directory and clears on logout.

## Helper commands

The bundled helper can also be used from a shell:

```bash
~/.config/omarchy/plugins/io.github.ingermanr.spotify/bin/spotify-plugin status
```

```
status                    JSON: running/playing/title/artist/album
play-pause | next | previous | play | pause
launch                    start Spotify if it is not running
search <query>            search tracks
playlists                 featured playlists
artists                   main artists (favourites or top artists)
top-tracks <artist_id>    an artist's most popular tracks
play-uri <uri>            play a context or track
play-tracks <uri>...      queue several tracks
play-artist-top <id>      play an artist's popular tracks
open-uri <uri>            open a URI in the client
```

## License

MIT. See [LICENSE](LICENSE).
