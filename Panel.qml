import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Spotify bar widget + popup panel. Playback control goes through the official
// Spotify client via Mpris/D-Bus (no account needed). Track search and
// playlists use the Spotify Web API (needs Client ID/Secret or an access token).
// All work goes through the `bin/spotify-plugin` helper shipped with this
// plugin; this file only polls status and triggers actions.
Panel {
  id: root
  moduleName: "io.github.ingermanr.spotify"
  ipcTarget: "io.github.ingermanr.spotify"

  // Resolved relative to this file, so the plugin works wherever it is installed.
  readonly property string cli: String(Qt.resolvedUrl("bin/spotify-plugin")).replace(/^file:\/\//, "")

  // ---------- Status ----------
  property var status: ({ running: false })
  property bool statusLoaded: false
  property bool refreshQueued: false

  readonly property bool running: status.running === true
  readonly property bool playing: running && status.playing === true
  readonly property string title: running ? (status.title || "") : ""
  readonly property string artist: running ? (status.artist || "") : ""
  readonly property string album: running ? (status.album || "") : ""

  // ---------- Settings ----------
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 5)), 10)
    if (!isFinite(n)) n = 5
    return Math.max(2, Math.min(300, n))
  }

  readonly property string clientId: setting("spotifyClientId", "")
  readonly property string clientSecret: setting("spotifyClientSecret", "")
  readonly property string accessToken: setting("spotifyAccessToken", "")
  readonly property string favoriteArtists: setting("favoriteArtists", "")

  // Process.environment is a QVariantHash (map), not a list of "KEY=VALUE".
  readonly property var envVars: ({
    "SPOTIFY_CLIENT_ID": root.clientId,
    "SPOTIFY_CLIENT_SECRET": root.clientSecret,
    "SPOTIFY_ACCESS_TOKEN": root.accessToken,
    "SPOTIFY_ARTISTS": root.favoriteArtists
  })

  // Changing any credential (or the favourites list) invalidates every Web API
  // result on screen and any lookup still running, so one account's data is
  // never shown under another's. Each lookup records the generation it started
  // in and its result is dropped if the generation moved on meanwhile.
  readonly property string credentialKey: [root.clientId, root.clientSecret,
    root.accessToken, root.favoriteArtists].join("\u0000")
  property int credentialGeneration: 0
  onCredentialKeyChanged: resetApiState()

  // ---------- UI state ----------
  property string busyAction: ""
  property string errorText: ""
  readonly property bool busy: busyAction !== ""

  property var searchResults: []
  property var playlists: []
  property var artists: []
  property var topTracks: ({})
  property string expandedArtist: ""
  property string topTracksLoading: ""
  property string queuedArtistId: ""
  property string searchQuery: ""

  // ---------- Colours / fonts ----------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------- Labels ----------
  readonly property string stateLabel: {
    if (!statusLoaded) return "Checking…"
    if (!running) return "Not running"
    if (playing) return "Playing"
    return "Paused"
  }

  readonly property string tooltip: {
    if (!statusLoaded) return "Spotify"
    if (!running) return "Spotify not running · Click to launch"
    var t = "Spotify · " + stateLabel
    if (title) t += " · " + title
    if (artist) t += " · " + artist
    return t
  }

  // ---------- Actions ----------
  function refresh() {
    if (statusProc.running) {
      refreshQueued = true
      return
    }
    statusProc.running = true
  }

  function applyStatus(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw).trim()) } catch (e) { parsed = null }
    status = parsed && typeof parsed === "object" ? parsed : { running: false }
    statusLoaded = true
  }

  function run(action, args) {
    if (busy) return
    errorText = ""
    busyAction = action
    actionProc.command = [root.cli].concat(args)
    actionProc.running = true
  }

  function togglePlayback() {
    if (!running || busy) return
    run("play-pause", ["play-pause"])
  }

  function nextTrack() {
    if (!running || busy) return
    run("next", ["next"])
  }

  function prevTrack() {
    if (!running || busy) return
    run("previous", ["previous"])
  }

  function launchSpotify() {
    if (busy) return
    run("launch", ["launch"])
  }

  // The query goes to the helper on stdin (`search -`), never in its argv.
  function doSearch() {
    var query = searchQuery.trim()
    if (!query || busy || searchProc.running) return
    errorText = ""
    busyAction = "search"
    searchProc.query = query
    searchProc.generation = credentialGeneration
    searchProc.command = [root.cli, "search", "-"]
    searchProc.environment = root.envVars
    searchProc.running = true
  }

  // The helper prints {"error": ...} on stdout when it fails, so prefer that
  // over stderr, which only carries unexpected failures.
  function applySearchResults(exitCode, raw, stderrText) {
    var parsed = null
    try { parsed = JSON.parse(String(raw).trim()) } catch (e) { parsed = null }
    searchResults = (parsed && parsed.tracks) ? parsed.tracks : []
    if (parsed && parsed.error) errorText = parsed.error
    else if (exitCode !== 0) {
      var lines = String(stderrText || "").trim().split("\n")
      var last = lines[lines.length - 1].trim()
      errorText = last !== "" ? last : "Search failed (exit " + exitCode + ")"
    }
  }

  function resetApiState() {
    credentialGeneration++
    errorText = ""
    searchResults = []
    playlists = []
    artists = []
    topTracks = ({})
    expandedArtist = ""
    topTracksLoading = ""
    queuedArtistId = ""
    if (opened) { refreshPlaylists(); refreshArtists() }
  }

  function applyPlaylists(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw).trim()) } catch (e) { parsed = null }
    if (parsed && parsed.playlists) playlists = parsed.playlists
    else playlists = []
    busyAction = ""
  }

  function applyArtists(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw).trim()) } catch (e) { parsed = null }
    if (parsed && parsed.artists) artists = parsed.artists
    else artists = []
    if (parsed && parsed.error && artists.length === 0) errorText = parsed.error
    busyAction = ""
  }

  // Play a context/track: the helper tries the Web API first and falls back to
  // opening it in the client, so this works with or without a user token.
  function playUri(uri) {
    if (!uri || busy) return
    run("play-uri", ["play-uri", uri])
    root.close()
  }

  // Play an artist's most popular tracks (helper resolves them and falls back
  // to the artist context when it cannot).
  function playArtist(artist) {
    if (!artist || !artist.id || busy) return
    run("play-artist-top", ["play-artist-top", artist.id])
    root.close()
  }

  function playTracks(uris) {
    if (!uris || uris.length === 0 || busy) return
    run("play-tracks", ["play-tracks"].concat(uris))
    root.close()
  }

  function toggleArtist(artist) {
    if (!artist || !artist.id) return
    if (expandedArtist === artist.id) { expandedArtist = ""; return }
    expandedArtist = artist.id
    if (!topTracks[artist.id]) fetchTopTracks(artist.id)
  }

  function fetchTopTracks(id) {
    if (topTracksProc.running) { queuedArtistId = id; return }
    topTracksLoading = id
    topTracksProc.pendingId = id
    topTracksProc.generation = credentialGeneration
    topTracksProc.command = [root.cli, "top-tracks", id]
    topTracksProc.environment = root.envVars
    topTracksProc.running = true
  }

  function onTopTracksDone() {
    if (queuedArtistId !== "") {
      var q = queuedArtistId
      queuedArtistId = ""
      fetchTopTracks(q)
    }
  }

  function applyTopTracks(id, raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw).trim()) } catch (e) { parsed = null }
    var tracks = (parsed && parsed.tracks) ? parsed.tracks : []
    var m = Object.assign({}, topTracks)
    m[id] = tracks
    topTracks = m
    if (parsed && parsed.error && tracks.length === 0) errorText = parsed.error
    if (topTracksLoading === id) topTracksLoading = ""
  }

  function openUri(uri) {
    if (!uri || busy) return
    run("open-uri", ["open-uri", uri])
    root.close()
  }

  function finishAction(exitCode) {
    if (exitCode !== 0) {
      var lines = String(actionErr.text || "").trim().split("\n")
      var last = lines.length > 0 ? lines[lines.length - 1].trim() : ""
      errorText = (last !== "" ? last : busyAction + " failed (exit " + exitCode + ")")
    }
    busyAction = ""
    refresh()
  }

  onOpenedChanged: if (opened) { refresh(); refreshPlaylists(); refreshArtists() }
  Component.onCompleted: refresh()

  // ---------- Processes ----------
  Process {
    id: statusProc
    command: [root.cli, "status"]
    environment: root.envVars
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onExited: {
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    // Defer one tick so the stderr collector has flushed its final text.
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() { root.finishAction(exitCode) })
    }
  }

  Process {
    id: searchProc
    property string query: ""
    property int generation: 0
    environment: root.envVars
    stdinEnabled: true
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    stderr: StdioCollector { id: searchErr; waitForEnd: true }
    onStarted: {
      write(query + "\n")
      query = ""
    }
    onExited: function(exitCode, exitStatus) {
      var generation = searchProc.generation
      Qt.callLater(function() {
        if (generation === root.credentialGeneration)
          root.applySearchResults(exitCode, searchOut.text, searchErr.text)
        root.busyAction = ""
      })
    }
  }

  Process {
    id: playlistsProc
    property int generation: 0
    environment: root.envVars
    stdout: StdioCollector { id: playlistsOut; waitForEnd: true }
    stderr: StdioCollector { id: playlistsErr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var generation = playlistsProc.generation
      Qt.callLater(function() {
        if (generation !== root.credentialGeneration) {
          if (root.opened) root.refreshPlaylists()
          return
        }
        if (exitCode === 0) root.applyPlaylists(playlistsOut.text)
        root.busyAction = ""
      })
    }
  }

  function refreshPlaylists() {
    if (playlistsProc.running) return
    playlistsProc.generation = credentialGeneration
    playlistsProc.command = [root.cli, "playlists"]
    playlistsProc.environment = root.envVars
    playlistsProc.running = true
  }

  Process {
    id: artistsProc
    property int generation: 0
    environment: root.envVars
    stdout: StdioCollector { id: artistsOut; waitForEnd: true }
    stderr: StdioCollector { id: artistsErr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var generation = artistsProc.generation
      Qt.callLater(function() {
        if (generation !== root.credentialGeneration) {
          if (root.opened) root.refreshArtists()
          return
        }
        if (exitCode === 0) root.applyArtists(artistsOut.text)
        root.busyAction = ""
      })
    }
  }

  function refreshArtists() {
    if (artistsProc.running) return
    artistsProc.generation = credentialGeneration
    artistsProc.command = [root.cli, "artists"]
    artistsProc.environment = root.envVars
    artistsProc.running = true
  }

  Process {
    id: topTracksProc
    property string pendingId: ""
    property int generation: 0
    environment: root.envVars
    stdout: StdioCollector { id: topTracksOut; waitForEnd: true }
    stderr: StdioCollector { id: topTracksErr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var id = topTracksProc.pendingId
      var generation = topTracksProc.generation
      Qt.callLater(function() {
        if (generation === root.credentialGeneration) root.applyTopTracks(id, topTracksOut.text)
        root.onTopTracksDone()
      })
    }
  }

  // Poll faster while the panel is open; never overlaps (refresh() queues).
  Timer {
    interval: root.opened ? 3000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: if (!root.busy) root.refresh()
  }

  // ---------- Bar button ----------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF04C7)   // md-spotify
    opacity: !root.running ? 0.25 : (root.playing ? 1 : 0.6)
    tooltipText: root.tooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePlayback()
      else if (root.statusLoaded && !root.running) root.launchSpotify()
      else root.toggle()
    }
  }

  // ---------- Popup panel ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)
        clip: true

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: String.fromCodePoint(0xF04C7)   // md-spotify
            color: root.playing ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.title !== "" ? root.title : "Spotify"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.artist !== "" ? root.artist
                : (root.album !== "" ? root.album : root.stateLabel.toUpperCase())
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Not running ----------
        Column {
          visible: root.statusLoaded && !root.running
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: "Spotify is not running."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ActionButton {
            width: parent.width
            text: "Launch Spotify"
            iconText: String.fromCodePoint(0xF02CB)  // nf-md-headphones
            enabled: !root.busy
            onClicked: root.launchSpotify()
          }

          PanelSeparator { foreground: root.foreground }
        }

        // ---------- Busy / error line ----------
        Text {
          visible: root.busy || root.errorText !== ""
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
          text: root.busy ? "Working…" : root.errorText
          color: root.busy ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Controls (running only) ----------
        Column {
          visible: root.running
          width: parent.width
          spacing: Style.space(14)

          PanelSeparator { foreground: root.foreground }

          Row {
            id: controlsRow
            width: parent.width
            spacing: Style.space(10)

            readonly property real cellWidth: (width - spacing * 2) / 3

            ActionButton {
              width: controlsRow.cellWidth
              iconText: String.fromCodePoint(0xF04AE)  // nf-md-skip-previous
              text: "Previous"
              enabled: !root.busy
              onClicked: root.prevTrack()
            }

            ActionButton {
              width: controlsRow.cellWidth
              iconText: root.playing ? String.fromCodePoint(0xF03E4) : String.fromCodePoint(0xF040A)
              text: root.playing ? "Pause" : "Play"
              active: root.playing
              enabled: !root.busy
              onClicked: root.togglePlayback()
            }

            ActionButton {
              width: controlsRow.cellWidth
              iconText: String.fromCodePoint(0xF04AD)  // nf-md-skip-next
              text: "Next"
              enabled: !root.busy
              onClicked: root.nextTrack()
            }
          }

          ActionButton {
            width: parent.width
            text: "Open Spotify"
            iconText: String.fromCodePoint(0xF02CB)  // nf-md-headphones
            enabled: !root.busy
            onClicked: root.launchSpotify()
          }

          PanelSeparator { foreground: root.foreground }
        }

        // ---------- Search ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "SEARCH TRACKS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: searchRow
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: searchField
              width: parent.width - searchButton.implicitWidth - Style.space(6)
              placeholderText: "Search tracks…"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              onAccepted: root.doSearch()
              onTextChanged: root.searchQuery = text
            }

            Button {
              id: searchButton
              text: "Search"
              enabled: !root.busy && searchField.text.trim() !== ""
              fontSize: Style.font.bodySmall
              fontFamily: root.fontFamily
              foreground: root.foreground
              bordered: true
              onClicked: root.doSearch()
            }
          }

          Column {
            id: searchResultsCol
            width: parent.width
            spacing: Style.space(4)
            visible: root.searchResults.length > 0

            Repeater {
              model: root.searchResults
              delegate: Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width - srArtist.width - srPlay.implicitWidth - parent.spacing * 2
                }

                Text {
                  id: srArtist
                  textFormat: Text.PlainText
                  text: modelData.artist
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width * 0.28
                }

                ActionButton {
                  id: srPlay
                  text: "Play"
                  fontSize: Style.font.caption
                  padding: Style.space(2)
                  onClicked: root.playUri(modelData.uri)
                }
              }
            }
          }
        }

        // ---------- Main artists ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "MAIN ARTISTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            id: artistsCol
            width: parent.width
            spacing: Style.space(4)
            visible: root.artists.length > 0

            Repeater {
              model: root.artists
              delegate: Column {
                id: artistDelegate
                required property var modelData
                readonly property string artistId: modelData.id
                readonly property var expandedTracks: root.topTracks[artistDelegate.artistId] || []
                readonly property bool expanded: root.expandedArtist === artistDelegate.artistId

                width: parent.width
                spacing: Style.space(4)

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    width: parent.width - arGenre.width - arSongs.implicitWidth - arPlay.implicitWidth - parent.spacing * 3

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleArtist(modelData)
                    }
                  }

                  Text {
                    id: arGenre
                    textFormat: Text.PlainText
                    text: modelData.genre || ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width * 0.18
                  }

                  ActionButton {
                    id: arSongs
                    text: artistDelegate.expanded ? "Hide" : "Songs"
                    fontSize: Style.font.caption
                    padding: Style.space(2)
                    onClicked: root.toggleArtist(modelData)
                  }

                  ActionButton {
                    id: arPlay
                    text: "Play"
                    fontSize: Style.font.caption
                    padding: Style.space(2)
                    enabled: !root.busy
                    onClicked: root.playArtist(modelData)
                  }
                }

                // Expanded: the artist's most popular tracks
                Column {
                  visible: artistDelegate.expanded
                  width: parent.width
                  spacing: Style.space(2)

                  Text {
                    visible: root.topTracksLoading === artistDelegate.artistId
                    text: "Loading popular tracks…"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    width: parent.width
                  }

                  Text {
                    visible: root.topTracksLoading !== artistDelegate.artistId
                      && artistDelegate.expandedTracks.length === 0
                    text: "No popular tracks available."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    width: parent.width
                  }

                  Repeater {
                    model: artistDelegate.expandedTracks
                    delegate: Row {
                      required property var modelData
                      width: parent.width
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: "▸ " + modelData.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        width: parent.width - ttPlay.implicitWidth - parent.spacing
                      }

                      ActionButton {
                        id: ttPlay
                        text: "Play"
                        fontSize: Style.font.caption
                        padding: Style.space(2)
                        enabled: !root.busy
                        onClicked: root.playUri(modelData.uri)
                      }
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.artists.length === 0
            text: root.favoriteArtists !== ""
              ? "No artists found. Configure Spotify API credentials to resolve them."
              : "Tip: set Main artists in plugin settings (e.g. Radiohead, Portishead), or use a user token to load your Spotify top artists."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }
        }

        // ---------- Playlists ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "PLAYLISTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            id: playlistsCol
            width: parent.width
            spacing: Style.space(4)
            visible: root.playlists.length > 0

            Repeater {
              model: root.playlists
              delegate: Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width - plOwner.width - plOpen.implicitWidth - parent.spacing * 2
                }

                Text {
                  id: plOwner
                  textFormat: Text.PlainText
                  text: modelData.owner
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width * 0.28
                }

                ActionButton {
                  id: plOpen
                  text: "Open"
                  fontSize: Style.font.caption
                  padding: Style.space(2)
                  onClicked: { root.openUri(modelData.uri); root.close() }
                }
              }
            }
          }

          Text {
            visible: root.playlists.length === 0 && root.statusLoaded
            text: "No playlists found. Configure Spotify API credentials to search."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }
        }
      }
    }
  }

  // ---------- Reusable components ----------
  component ActionButton: Button {
    iconSize: Style.font.title
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    fontFamily: root.fontFamily
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    opacity: enabled ? 1 : 0.4
  }
}
