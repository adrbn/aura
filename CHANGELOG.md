# Changelog

All notable changes to Aura are documented here.

Format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed — Search
- A song no longer loses its place to an album of the same name: an exact hit on a title now leads the results, and an artist still outranks both
- The search field is tappable across its whole width, and the cross that cleared it is now a full-size **Clear** button

### Fixed — Playback
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
