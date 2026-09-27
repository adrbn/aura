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
- A preview becomes its song the moment Get It brings it in: the preview playing hands over to the whole song at the very point it has reached — the two recordings lined up, started in step on the host clock and crossed over in a quarter of a second, so nothing is heard change — and Now Playing dissolves to the song, its length and its lyrics in time. A paused preview gives way at the same point; one that can't be lined up plays out, and its song follows from the top. Queued previews become their songs too
- Previews show their lyrics, from LRCLIB, as a sheet: a preview is thirty seconds from somewhere in the song and nothing says where, so timed lines would run out of step
- The Get It countdown follows the server's real pace, learnt from the last few releases it added, instead of a fixed twenty minutes
- The veil behind the tab bar and the mini player rises behind the Get It card too, so its glass reads the same dark page as the mini player's

### Fixed — Radar
- Get It no longer waits forever for a song whose title holds a semicolon — "You and I, Pt. II (Full Version; 2017 Remaster)": Navidrome refuses a whole request with a bare ";" in it, so the song, already in the library, was never found. Every query sent to the server now spells it out
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

### Added — Lyrics
- Translation by Gemini, with a key of your own (free from Google AI Studio, in Settings → Lyrics → Translation): lyrics in another language than the phone's show a translation under each line, small and dimmed. The whole song goes in one request, so each line is read knowing the rest — a sentence running over several lines is translated as a sentence, then cut back at the line breaks, each line carrying the part sung on it; idioms go by their sense, and a creole is read as itself, not as the language it resembles. The key stays in the Keychain and Settings checks it on the spot. Without a key the button leads to setting one up
- A song is sent only when the translate button is tapped — never on its own when the lyrics open — so the free quota goes on the songs actually read. When one of Google's models has used up its share, the next takes over (Gemini Flash, then Flash-Lite, then Gemma), each set aside until its quota comes back
- A translation is kept, and comes back at once, offline too. Offline, the button only shows for a song that has one kept
- Lines already in the reader's language — a song switching languages — are left as they are
- Translations fade in under their lines instead of snapping the sheet to a new height

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
- The tab roots — Home, Library, Playlists, Search, Settings — open in colour, as album and playlist pages do: a glow at the top in three neighbouring hues that slowly trade places and breathe, fading into the page before the middle of the screen. Its colour follows the time of day — violet at night, rose at dawn, amber through the morning and afternoon, orange and red towards sunset, magenta at dusk — drifting minute by minute, and never green. It scrolls away with the content, holds still under Reduce Motion and stops drawing when out of sight. Home's cutting mat runs through it
- Home is lighter: section titles at 20 points semibold instead of 28 bold, the Made For You covers without a caption beneath them — each already prints its name — Favorite Artists as 110-point circles instead of 140, and the counts under the title as a quiet line of words — "22,563 songs · 18,804 albums · 304 playlists" — without icons
- Now Playing keeps its six controls along the bottom — lyrics, radio, queue, sleep timer, output and Share — each a tap away
- The Get It card is a slim pill: a smaller cover, the title over where it's at, and the four steps as a ring of four arcs at its end — about two thirds of its former height, with nothing drawn over the words
- Playlists open as a list by default
- The pin on pinned playlists is a quiet mark — a small white pin on a dark disc over a cover, a grey one in the list — instead of a bright accent dot
- The playlist filters span the row when they fit on one line, each keeping its proportions, and scroll when they don't
- The layout and options buttons at the top of Playlists are in the secondary colour, like Library's, instead of the accent
- The page's colour rises behind the tab bar and the mini player: over a bright cover the system's tab bar read lighter than the mini player, the one glass Aura draws itself — and the system's takes no tint. It is eased from the foot of the screen, so it thickens behind the bars without drawing a band above the mini player
- With the keyboard up, the mini player and the download and fetch cards stay where they are behind it, hidden, instead of riding up over the results
- Every page's list ends above the mini player and the fetch card: a radio's songs, the genres, a genre's songs, the artists, the "see all" lists, the settings pages, About and Wrapped no longer end underneath them, and the A–Z index keeps its last letters clear of the card
- Home's canvas carries a faint cutting-mat grid — hairlines every 16 points, a firmer one every fifth
- The dark canvas is #121212 instead of pure black, and song rows sit on it instead of painting their own black — the Library menu, recent searches, search results and loading placeholders included
- Artist headers drop the dark fade across the top of the photo; only a photo bright enough to hide the clock gets a light veil, the status bar's height
- A face too high in an artist photo is brought down by zooming in on it (up to 1.7×), instead of sliding the photo down over a stretched, blurred copy of its top edge — pulling the page down zooms the same way
- Artist photos for covers come from Deezer's public catalogue: the server's artist-image queue stalled every cover in the app whenever a shelf asked for a dozen artists at once

### Added — Pages
- A long press on a cover lifts that cover alone, in its own shape, with its actions — Change, Save and Remove Cover Art on a playlist, Save on an album — instead of the whole header rising with it
- The accent can be any colour, picked with the system's colour picker, beside the nine ready-made ones
- An artist's page says how many times you've played them, under the name, where it used to count their albums; a shimmering placeholder holds its place while it loads. Instant Mix and Shuffle stretch across the row beside the small round heart, lined up with the name and Top Songs, instead of sitting centred at their own widths
- Playing from the Radar says "Release Radar" in Now Playing, with the radar's icon
- A radar release lists every artist credited on it: a collaboration shows under each of its artists, and its byline names them all

### Changed — Landscape clock
- Turning the phone on its side no longer rotates the whole interface: the clock turns its own content to face the phone, fades in and out instead of sliding up while the screen turned, and follows the phone from one side to the other. Closing it no longer leaves Now Playing squeezed into landscape
- Lyrics on their side are the whole sheet in one size, the sung line held in the middle and brightened, instead of three or four lines of changing sizes that jumped to re-centre; a tapped line is sung from its start, and translations show under their lines
- Real targets: previous, play and next are 56-point buttons, a tap on the clock switches between digital and analog — remembered — and a close button and a clock/lyrics switch sit in the corner, instead of a long press anywhere on the screen
- A progress line with the time played and left, the blurred cover from the artwork cache — offline too — and the screen kept lit while the phone charges

### Changed — Offline
- Offline mode switched on by hand stays on when the app is reopened; only an offline mode the app chose itself, for want of a server, lifts on its own
- Aura decides on opening: online if the server answers, offline if it doesn't, instead of trusting the mode it was left in
- Offline pages follow the online pages' spacing, and close their lists with the album's "2024 · 12 songs · 48 min" line; the "on this iPhone" counts and the system's "The Internet connection appears to be offline" message are gone
- Offline Wrapped playlists show their Wrapped cover, and playlist covers show offline as they do online

### Changed — Appearance
- Home's shelves and the queue move smoothly when a song is played — Up Next and Recently Played slide their covers into place instead of changing at once, and sections appear and leave with a fade
- The ⋮ menus on album, playlist, radio and mix pages, and on the Playlists tab, are in the text colour instead of the accent
- A radio's page, and every page listing songs, share the same spacing between header, list and closing line
- Now Playing's background keeps a light cover's own hue, only deeper, so white controls stay readable; a very dark cover gets its most vibrant colour blended in
- Loading placeholders stand where the answer will appear, in its shape

### Fixed
- Saving a cover to Photos no longer closes the app: Aura now asks to add to the photo library, as iOS requires, and says so if it's refused. A Wrapped playlist saves the cover shown, and a downloaded album's cover saves offline
- A song autoplay adds after a one-song album no longer says it's playing from that album: where autoplay begins is now kept with the queue across relaunches, and a song that isn't on the album named above it shows as Autoplay
- Made For You covers no longer fall back to flat colour when many covers load at once: artist photos have their own pace for Deezer's catalogue, apart from the Radar's, and a cover that couldn't get its photos tries again

### Developer
- `scripts/set-build-number.sh` stamps the build number from the commit count before an archive

### Fixed — Appearance
- The Add to Playlist sheet lists on the page's own dark background, like its header, instead of the system grey
- With several Get It fetches running, their cards sit side by side, one on screen at a time: a swipe slides the next one in, settling with a small bounce and giving a little past either end, and the card says which it is (2/3) — instead of one card and a "+2"
- Home's title no longer carries the logs button: the logs are in Settings → Beta Features, under View Logs
- Album pages close their song list with "2024 · 12 songs · 48 min", as a sleeve does, instead of a lone "12 Songs" adrift above the first song
- Albums the server has no artwork for show their real cover: Navidrome's generic record — which it now resizes to order, so it slipped past the size test — is recognised by eye at any size, and the album is looked up in Deezer's catalogue by artist and title. Aura's own stand-in only appears when the catalogue has nothing either. Covers already cached as the record are cleared once

### Fixed — Search
- A song no longer loses its place to an album of the same name: an exact hit on a title now leads the results, and an artist still outranks both
- The search field is tappable across its whole width, and the cross that cleared it is now a full-size **Clear** button
- The search field keeps one height: it no longer grows when the first letter brings up **Clear**
- "Did you mean" sits on a row its own height: every row was held to 44 points, which opened a gap above the first section
- A section's **See All** sits on its title, at the same place in every section, instead of on a row under its last result — sections run to different lengths, so those rows landed at scattered heights, between one section and the next. It turns into **Show Less** once the section is open
- Deezer's finds come in two titled sections, **Songs on Deezer** and **Albums on Deezer**: under one "On Deezer" the albums ran straight on from the songs
- The title and the search field scroll away with the results, as every other tab's title does, instead of the results sliding up in plain sight around them and under the clock

### Fixed — Lyrics
- Turning the translation on or off, or translations arriving, no longer leaves the line being sung off the centre until the next line: the lyrics re-centre on it once the lines have changed height
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
- Nine accent colours
- Light, dark or system appearance
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
