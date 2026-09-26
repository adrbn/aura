# Changelog

All notable changes to Aura are documented here.

Format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Made For You
- Radar: this month's releases from the artists you play most, found in Deezer's public catalogue and matched against your server. The releases the server has play as a mix; the others are listed beneath it, opening in Deezer — or in a Soulseek search, in the sideload build. The catalogue is checked once a day and the server every quarter hour, so a release you add joins the mix soon after the server lists it. Off in Settings → Release Radar
- Radar previews: tapping a release that isn't on the server plays its tracks' thirty-second Deezer previews in the player, as a queue — Now Playing, the lock screen and the queue included. A preview is marked as such and asks nothing of the server: no star, no scrobble, no history, no radio when it ends
- Radar leads "Made For You" wherever the mixes are listed, is a Library category of its own (**Radar**, added at the top of the Library once), and comes up in Search — by its name, or as "new releases", "nouveautés", "sorties"
- Play and Shuffle on the Radar play all of it: the server's new songs, then the previews of the releases it doesn't have yet, each release's most popular tracks first. The page counts those songs, instead of showing "0 songs" while nothing was on the server
- Sideload build — **Get It**: one tap on a radar release, or the heart on a preview in Now Playing, and Aura finds it on Soulseek by itself — the copy with the most of the release's tracks, in the best quality, from a peer with a free slot — downloads it, moves on to the next copy if one stalls — searching again for more peers when it runs short — and waits for the server to add it. A card above the mini player follows it step by step (looking, downloading, adding, ready), with the download's share and the time the server usually takes; a Live Activity does the same on the Lock Screen and in the Dynamic Island. A liked song is starred once it's in the library, and the card turns into a Play button. The card counts the tracks in (3/12), and the pages behind it end above it; with the app asleep, the Lock Screen's bar and countdown run on from the download's speed. Try Again asks every peer afresh
- A radar release opens its own page, a level down, like an album — a single of one song just plays, like a row of the radar's playlist: its songs as Deezer lists them, each playing its preview, the ones the server already has marked and played from it. In the sideload build each song can be had on its own, or the whole release at once; a release fetched in part stays listed so the rest can follow. The heart on a preview in Now Playing now gets that song alone. Whatever is played from a release runs on into the rest of the radar
- Search also shows what Deezer has and your server doesn't — songs that play their preview and, in the sideload build, can be had with Get It; releases that open their own page, like the radar's. With the Radar on only
- Previews fade out over their last three seconds instead of stopping dead, and one whose Deezer address has run out — they last a quarter of an hour, less than a long radar queue — is asked for again before it plays
- Every page's list ends above the Get It card, pushed pages included — an inset set around the tabs never reached them

### Fixed — Radar
- A re-issue is no longer a new release: an album Deezer dates anew under a title the artist had already put out stays off the radar — the same day's explicit and clean copies count once, and an album named after the single that announced it still counts
- Songs the server had long before a release came out (more than two weeks) don't join the mix as new; a release made only of such songs leaves the radar. Radars built before are rebuilt at once
- A preview shows its cover in Now Playing, and the background drawn from it — Deezer's artwork was taken for the server's "no cover" picture
- The Radar page drops its "Not in your library yet" header and the note beneath the list
- The Radar page lists releases, newest first, whether the server has them or not: an album is one row instead of its downloaded songs scattered above the rest, and a release on the server is marked — a single plays from it, on into the rest of the radar, previews included, instead of stopping at the last downloaded song. A release's page plays it in its own order, the server's copies and the previews between. Save as Playlist is gone from the radar: a day-to-day list, half previews
- A release the server has only part of stays listed, with how many songs are still to get: an album named after a single already on the server, or whose songs came in one by one — in the app or outside it — no longer passes for held, nor leaves the radar as "already heard". Its page marks every song the server has, wherever it's filed, not only the few the mix plays. Radars stored before are matched again at once
- A release you got a song of stays listed only while the server lacks some of its songs: a single got song by song, or finished outside the app, no longer stays among the missing for good — nor does one whose Get It failed. Once a fetched song completes its release, the release joins the mix at once instead of at the next check
- A release the server has whole offers Shuffle on its page instead of a Get button that had nothing left to get
- The radar plays every song the server has of a release, not only its three most popular; a release still to get keeps to three previews

### Added — Covers & pages
- Editorial covers for "Made For You" mixes and radios: the most-played artist's photo framed on the face (Apple Vision), a type-set title band in Archivo, a duotone for genre mixes, a cut-out figure over the period for Year Wrapped, and a three-artist layout for radios. Falls back to the lead artist's album cover, then to a flat colour field
- Album, playlist, mix and radio pages open in their artwork's colour, fading into the canvas
- Artist headers frame the photo on the face, even for photos stored rotated
- Made For You never puts two covers on the same face: each mix is led by an artist none of the covers before it shows — the radar and the evening mix both went to whoever played most. Search shows the same covers
- Radio covers fill the square: the seed artist in a larger disc sending out rings, the two similar artists riding the first ring in the field's tone, the name in a black band with the similar artists on a strip beneath — the mixes' lockup — over a field that deepens towards its edges, with a fine grain. Every disc is drawn from the start, a tinted stand-in until its photo is in, and the rings travel while the radio is being put together

### Added — Playlists
- Filters on the Playlists page — Pinned, Radios, Mixes, Mine, Shared, Downloaded — as a row of small, quiet capsules under the search field, each offered only when it would leave some playlists out. The chosen one takes the accent and a cross; tapping it again shows every playlist. They narrow the search too
- A list view beside the grid: one row per playlist, cover, name, songs and length. The switch sits beside the menu at the top of the page, and the choice is remembered
- A saved radio or mix keeps its cover: saving it sends the cover Aura drew — photos, band and all — as the playlist's picture on the server, instead of the server's collage of its songs

### Changed — Equalizer
- The equalizer is a response curve: the five bands as points on one smooth line over a decibel grid with its scale beside it, dragged up or down from anywhere on the graph, with each band's gain and frequency beneath it. Presets sit in an even grid of capsules under the curve, which glides to each one; Reset goes back to flat
- Equalizer changes are saved as they're made: opened from Now Playing, a change was lost at the next launch unless the Settings tab had been visited

### Added — In the car
- Shuffle and repeat buttons on a car stereo or a remote now work; the system is told which modes are on
- Now Playing reports the song's place in the queue ("4 of 20") where there is room for it, and the rate playback returns to, so a car's progress bar keeps moving between updates
- Siri: "Play my favourites in Aura" — « Joue mes favoris sur Aura » — shuffles your favourite songs, with the app closed

### Changed — Offline
- The offline library is laid out like the online tabs: what's on the iPhone at a glance, with Shuffle and Play, the search field, and Songs, Albums, Artists and Playlists as a row of capsules instead of a segmented control. Albums are a grid of covers
- Offline album, playlist and artist pages open in their artwork's colour, with the online pages' header — the cover, the name, Shuffle beside a wide Play — and say how much of each is on the iPhone
- The card explaining why Aura is offline carries the one action that applies — Retry, or Go Online — in place of a Wi-Fi button in the title

### Changed — Appearance
- The page's colour rises behind the tab bar and the mini player: over a bright cover the system's tab bar read lighter than the mini player, the one glass Aura draws itself — and the system's takes no tint. It is eased from the foot of the screen, so it thickens behind the bars without drawing a band above the mini player
- With the keyboard up, the mini player and the download and fetch cards stay where they are behind it, hidden, instead of riding up over the results
- Every page's list ends above the mini player and the fetch card: a radio's songs, the genres, a genre's songs, the artists, the "see all" lists, the settings pages, About and Wrapped no longer end underneath them, and the A–Z index keeps its last letters clear of the card
- Home's canvas carries a faint cutting-mat grid — hairlines every 16 points, a firmer one every fifth
- The dark canvas is #121212 instead of pure black, and song rows sit on it instead of painting their own black — the Library menu, recent searches, search results and loading placeholders included
- Artist headers drop the dark fade across the top of the photo; only a photo bright enough to hide the clock gets a light veil, the status bar's height
- A face too high in an artist photo is brought down by zooming in on it (up to 1.7×), instead of sliding the photo down over a stretched, blurred copy of its top edge — pulling the page down zooms the same way
- Artist photos for covers come from Deezer's public catalogue: the server's artist-image queue stalled every cover in the app whenever a shelf asked for a dozen artists at once

### Fixed — Search
- A song no longer loses its place to an album of the same name: an exact hit on a title now leads the results, and an artist still outranks both
- The search field is tappable across its whole width, and the cross that cleared it is now a full-size **Clear** button
- The search field keeps one height: it no longer grows when the first letter brings up **Clear**
- "Did you mean" and "Show more" sit on rows their own height: every row was held to 44 points, which opened a gap above the first section

### Fixed — Lyrics
- A duet, a remix or a translated version shows its own words: when a song names its version, the lyrics found are checked against that version's sheets on LRCLIB, once per song, and replaced when most of them disagree — *These Walls* with Pierre de Maere gets its French verse
- Lyrics can no longer be left over from the previous song: a fetch still running when the track changes is cancelled, and can neither put its words on the new song nor end its spinner

### Fixed — Playback
- Seeking into a part of a song that hasn't loaded yet plays from there instead of snapping back: a song the server converts as it sends (lossless files at any quality short of Lossless) is asked for again from the moment picked, the bar staying on it while it loads — and one cached by then reopens from the cache. A session restored at a point past what has loaded resumes there too
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
