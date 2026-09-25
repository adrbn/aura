# Changelog

All notable changes to Aura are documented here.

Format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Made For You
- Radar: this month's releases from the artists you play most, found in Deezer's public catalogue and matched against your server. The releases the server has play as a mix; the others are listed beneath it, opening in Deezer — or in a Soulseek search, in the sideload build. The catalogue is checked once a day and the server hourly, so a release you add joins the mix within the hour. Off in Settings → Release Radar

### Added — Covers & pages
- Editorial covers for "Made For You" mixes and radios: the most-played artist's photo framed on the face (Apple Vision), a type-set title band in Archivo, a duotone for genre mixes, a cut-out figure over the period for Year Wrapped, and a three-artist layout for radios. Falls back to the lead artist's album cover, then to a flat colour field
- Album, playlist, mix and radio pages open in their artwork's colour, fading into the canvas
- Artist headers frame the photo on the face, even for photos stored rotated

### Changed — Appearance
- The dark canvas is #121212 instead of pure black, and song rows sit on it instead of painting their own black — the Library menu, recent searches, search results and loading placeholders included
- Artist headers drop the dark fade across the top of the photo; only a photo bright enough to hide the clock gets a light veil, the status bar's height
- Artist photos for covers come from Deezer's public catalogue: the server's artist-image queue stalled every cover in the app whenever a shelf asked for a dozen artists at once

### Fixed — Search
- A song no longer loses its place to an album of the same name: an exact hit on a title now leads the results, and an artist still outranks both
- The search field is tappable across its whole width, and the cross that cleared it is now a full-size **Clear** button
- The search field keeps one height: it no longer grows when the first letter brings up **Clear**

### Fixed — Lyrics
- A duet, a remix or a translated version shows its own words: when a song names its version, the lyrics found are checked against that version's sheets on LRCLIB, once per song, and replaced when most of them disagree — *These Walls* with Pierre de Maere gets its French verse
- Lyrics can no longer be left over from the previous song: a fetch still running when the track changes is cancelled, and can neither put its words on the new song nor end its spinner

### Fixed — Playback
- A new radio can no longer be filled, or have its loader switched off, by a fetch still running for the one before it
- Opening lyrics tucks the song title behind the shrinking artwork instead of laying it over
- A stream that dies mid-song moves to the next track instead of stopping on a silent pause
- The audio session is reclaimed at every track change, so the queue keeps playing after an interruption

### Fixed — Artwork
- Full-width artwork is drawn from a full-resolution copy instead of being stretched from a thumbnail
- The in-memory artwork cache now measures what it holds, so its 120 MB limit is real
- An album or artist the server has no picture for gets Aura's own generated cover, instead of the server's "no cover" vinyl or grey silhouette — and is remembered, so it stops costing a ten-second round trip each time it scrolls past

## [1.0.0] — TBD

Initial public release. Native SwiftUI music client for Navidrome and Subsonic-API-compatible servers.

### Added — Playback
- Replay gain support
- Streaming at 128 / 192 / 320 kbps plus original lossless (FLAC, ALAC, others)
- Smart transcoding: MP3, AAC, OGG, or server-decided
- 5-band parametric equalizer with 15 presets plus custom curves
- Sleep timer, including "stop after this song"
- Full queue management: play next, add to queue, drag-reorder, auto-queue
- Shuffle and three repeat modes
- Scrobbling with configurable threshold

### Added — Lyrics
- Time-synced scrolling lyrics with tap-to-seek
- Server-provided lyrics with LRCLIB community fallback
- Full-screen lyrics in landscape
- Search entire library by lyric content

### Added — Instant Mix & Radio
- Generate a radio station from any song or artist
- Autoplay when queue is exhausted
- Save a generated mix as a real playlist on the server

### Added — Offline Mode
- Download individual songs, whole albums, playlists, or the entire library
- Automatic streaming cache (`AVAssetResourceLoaderDelegate` + LRU)
- Full offline search across downloads
- Separate quality settings for streaming vs downloads

### Added — Search
- Unified search: songs, albums, artists, playlists
- Fuzzy matching
- Smart ranking based on tap history
- Search by lyric content

### Added — Playlists
- Create / edit / reorder, synced to server
- Custom cover art from Photos
- Pin favorites
- Multi-select bulk delete
- Smart duplicate detection (by content, not name)
- Add whole playlist to queue, shuffled

### Added — Now Playing
- Full-screen player with audio route picker
- File info panel: codec, bitrate, sample rate
- "Playing from" indicator with jump-back to source
- Landscape clock mode

### Added — iOS Integration
- Lock Screen and Control Center
- Dynamic Island and Live Activities
- Siri: play, pause, skip, previous, shuffle, repeat, favourite, play a playlist or album by name
- AirPlay and Bluetooth auto-detection
- Share Sheet
- Keychain credential storage

### Added — Home Dashboard
- Recently Played, Favorites, Recently Added, Frequently Played, Up Next, Random Albums
- Fully customizable and reorderable sections

### Added — Appearance
- 7 accent colors
- Pure black OLED mode
- Adjustable list density
- Customizable tab bar order

### Added — Compatibility
- Navidrome (primary target)
- Any Subsonic-API v1.16.1-compatible server (Airsonic, Gonic, etc.)
- LRCLIB community lyrics
- Multiple server profiles

### Developer
- Split build configurations: `Release` (sideload IPA) and `Release-AppStore` (App Store; optional self-hosted integrations are excluded from the App Store configuration via compile flags)
- MIT licensed. Source available on GitHub.
