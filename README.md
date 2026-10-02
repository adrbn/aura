<div align="center">

<img src="docs/assets/icon.png" width="128" height="128" alt="Aura app icon" />

# Aura

### A native iPhone and Apple Watch player for your Navidrome or Subsonic server.

Lossless streaming, lyrics that light up word by word, mixes built from your own listening, and your whole library offline.

<br/>

<a href="https://github.com/adrbn/aura/releases/latest"><img alt="Download the IPA" src="https://img.shields.io/badge/Download%20the%20IPA-Releases-0D1117?style=for-the-badge&logo=github&logoColor=white" /></a>

<sub>App Store: coming soon, as <b>Aura: Self-Hosted Music</b> · Free and open source · Bring your own server</sub>

[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-3DA639)](LICENSE)
[![Platform: iOS 26+](https://img.shields.io/badge/iOS-26%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Latest release](https://img.shields.io/github/v/release/adrbn/aura?include_prereleases&label=release)](https://github.com/adrbn/aura/releases/latest)

<br/>

<img src="docs/assets/preview.webp" width="300" alt="Aura's App Store slides in turn: Home, Made For You mixes, an artist radio, synced lyrics, an artist page, the library, downloads with CarPlay and Apple Watch, and the privacy promise" />

</div>

> **Aura is a client, not a music service.** Point it at a Navidrome or Subsonic-compatible server you own or have access to. It plays your library; it doesn't host, provide or find music for you.

## Screenshots

<p align="center">
  <img src="docs/assets/shot-1-hero.webp" width="200" alt="Now Playing over the album's colours" />
  <img src="docs/assets/shot-2-mixes.webp" width="200" alt="Home with Year Wrapped, Made For You mixes and favourite artists" />
  <img src="docs/assets/shot-3-radio.webp" width="200" alt="A radio started from one song, with its cover and Play, Shuffle and Save as Playlist" />
  <img src="docs/assets/shot-4-lyrics.webp" width="200" alt="Synced lyrics over the blurred cover" />
</p>
<p align="center">
  <img src="docs/assets/shot-5-artist.webp" width="200" alt="An artist page with play count, Instant Mix, Shuffle and Top Songs" />
  <img src="docs/assets/shot-6-library.webp" width="200" alt="The Library tab: songs, albums, favourites, genres, artists and Radar" />
  <img src="docs/assets/shot-7-anywhere.webp" width="200" alt="Downloads, CarPlay and Apple Watch" />
  <img src="docs/assets/shot-8-private.webp" width="200" alt="No account, no tracking" />
</p>
<p align="center">
  <img src="docs/assets/watch-1-now-playing.webp" width="180" alt="Apple Watch: Now Playing with the transport over the blurred cover" />
  <img src="docs/assets/watch-2-lyrics.webp" width="180" alt="Apple Watch: lyrics" />
  <img src="docs/assets/watch-3-up-next.webp" width="180" alt="Apple Watch: Up Next" />
  <img src="docs/assets/watch-4-library.webp" width="180" alt="Apple Watch: the library with search and Made For You" />
</p>

## Features

### Playback
- Streams your original files, FLAC and ALAC kept lossless, or at 128, 192 or 320 kbps on a slow connection. Formats iOS can't open (OGG, Opus, WMA) are converted by the server.
- A five-band equalizer from 60 Hz to 14 kHz, drawn as one curve you drag, with 15 presets. ReplayGain is a switch in Settings.
- An editable queue: play next, add to the end, drag to reorder. When it runs out, autoplay carries on with similar songs.
- Shuffle, repeat one or all, and a sleep timer that stops after a set time or at the end of the song.
- Plays are scrobbled to your server, and held on the iPhone while you're offline.

### Lyrics
- From your server first (OpenSubsonic lyrics extension), then [LRCLIB](https://lrclib.net) when it has none.
- Word by word when the server has per-word timing, line by line otherwise. Tap a line to jump to it; shift the timing if your Bluetooth headphones lag.
- Put lyrics in time yourself: tap *Now* as each marked line starts. The result stays on the iPhone and wins over every other source.
- For a duet, a remix or another version of a song, Aura checks that the lyrics match the version playing.
- Optional translation under each line by Google's Gemini, with a free API key of your own (Settings → Lyrics → Translation). A song is sent only when you tap translate, and only its lines, title and artist. Translations are kept for offline use.

### Mixes & Radar
- Instant Mix starts a radio from any song or artist. Save it as a playlist on your server and its cover goes with it.
- Made For You builds mixes from your library by time of day, mood and genre, each with its own cover.
- Radar lists this month's releases from the artists you play most. What your server has plays in full; the rest plays as 30-second Deezer previews. It can be switched off in Settings.
- Year Wrapped shows your top songs, artists and genres, counted on your iPhone.

### Offline
- Download a song, an album, a playlist or the whole library, each at its own quality.
- What you stream is cached as it plays, up to a size you set.
- With no connection, the library, search and playback keep working with what's on the iPhone. An offline mode you switch on stays on across launches.

### Library & Search
- One search across songs, albums, artists and playlists that forgives typos, with a Recently Searched list of what you played.
- Playlists as a grid or a list, filtered to pinned, radios, mixes, yours, shared or downloaded. Create them, reorder them and give them a cover from your photos; changes go to your server.
- Album, playlist and mix pages take the colour of their artwork. When your server has no cover for an album, Aura finds it in Deezer's catalogue.
- Several servers, switched from the Home title, and libraries split across music folders.

### iPhone integration
- Controls on the Lock Screen, in Control Center and in the Dynamic Island, with AirPlay.
- Siri and Shortcuts in English and French: play, pause, skip, go back, shuffle, repeat, favourite a song, play a playlist or album by name, or play your favourites.
- Share a song as links that open it on other services.
- Light or dark, any accent colour, and tabs and Home sections in the order you choose.
- A nightstand clock: switch it on, turn the phone sideways while music plays, and the artwork, the time or the lyrics fill the screen.

### Apple Watch
- A remote for the iPhone's player: Now Playing over the blurred cover, lyrics, Up Next, and the Digital Crown on the phone's volume.
- The library from the wrist: search, Made For You with the Radar, favourites and playlists, each with Play and Shuffle.

### CarPlay
- The library laid out as on the phone: Home with the mixes and the Radar, Playlists with your favourites first, and the newest albums. Each page opens under its cover with Play and Shuffle.
- Now Playing keeps the heart, Up Next and the album a tap away. CarPlay is in the App Store build only (see below).

### Privacy
- No account, no analytics, nothing sent to the developer. Server passwords are kept in the iOS Keychain.
- Lyrics, credits, covers, artist photos, the Radar and share links come from public services, each listed in the [privacy policy](https://adrbn.github.io/aura-site/privacy.html).

## Two builds

Both are free, and everything not listed here is the same in both.

| | App Store build | Sideload IPA |
|---|---|---|
| CarPlay | Yes | No: re-signing the IPA drops Apple's CarPlay entitlement |
| Get It (Soulseek via your own [slskd](https://github.com/slskd/slskd)) | No | Opt-in, under Settings → Beta Features |
| NetEase lyrics-timing check for remixes and edits | No | Yes |

**Get It** fetches what your library is missing: a Radar release, a Deezer result in Search, the missing songs of an album you have only part of (one by one, or with Get All), or the heart on a preview in Now Playing. Aura finds the release on Soulseek through your slskd, downloads it, and waits for your server to add it, with a card above the mini player and a Live Activity following each step. Nothing goes through anyone else's server. Only download music you have the right to.

The **NetEase check** asks NetEase's catalogue, by title, artist and length, for lyrics timed to the exact recording, since lyrics sources often file a remix under the original's timing.

The sideload build can also follow a SoulSync watchlist from the Radar, and write lyrics you time by hand to your server as `.lrc` files through File Browser.

## Install

### Sideload the IPA

1. Install a sideloading tool on your iPhone: [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or Feather.
2. Download `Aura-v<version>.ipa` from the [latest release](https://github.com/adrbn/aura/releases/latest). Each release lists its SHA-256 checksum.
3. Open the IPA in your sideloading tool and install it.
4. On first launch iOS blocks the app: go to **Settings → General → VPN & Device Management** and trust the developer profile.
5. Open Aura and enter your server's address, username and password.

Installing a new IPA over an earlier sideload keeps your servers, passwords, downloads and pins. With a free Apple ID, the signature expires after 7 days and the sideloading tool has to refresh it; that's an iOS limit, not Aura's.

### App Store

Aura is in App Review as **Aura: Self-Hosted Music**. It will be free, with no in-app purchases.

## Requirements

- iPhone with iOS 26 or later.
- Apple Watch with watchOS 26 or later, for the watch app.
- A [Navidrome](https://www.navidrome.org) server, or any server speaking Subsonic API 1.16.1. OpenSubsonic extensions are used when the server offers them.

No server yet? Try Aura against Navidrome's public demo: `https://demo.navidrome.org`, user `demo`, password `demo`.

## Build from source

```bash
git clone https://github.com/adrbn/aura
cd aura
open Aura/Aura.xcodeproj
```

- Xcode 26 or later (App Store archives are made with Xcode 26.6).
- Select your own team under Signing & Capabilities, and set the `AURA_BUNDLE_BASE` build setting at the project level to a bundle identifier you own. The widget, watch app and Mac targets derive theirs from it.
- Schemes and configurations:
  - **Aura**, with `Debug` and `Release`: the sideload build, with Get It and the NetEase check.
  - **Aura-AppStore**, with `Release-AppStore`: built with the `APPSTORE_BUILD` flag, which compiles the sideload-only features out.
  - **Aura-mac**: a macOS preview build; only the iPhone is tested daily.
- CarPlay needs Apple's `carplay-audio` entitlement on your own team.
- `scripts/watch-screenshots.sh` draws the watch app's pages on a Mac without a watch or simulator.

The fonts (Vavin and Archivo, both SIL OFL 1.1) are in the repository, so a fresh clone builds with nothing to add.

## Privacy

Aura has no account and no analytics, and sends nothing to the developer. It talks to your server and to the public services listed in the [privacy policy](https://adrbn.github.io/aura-site/privacy.html), which says exactly what each one receives.

## Contributing

Bugs and feature requests: [github.com/adrbn/aura/issues](https://github.com/adrbn/aura/issues). Pull requests are welcome. The [changelog](CHANGELOG.md) describes what changed and why.

## Support

Aura is free, and stays free. If it earns a place on your home screen:

<a href="https://ko-fi.com/adrbn"><img alt="Ko-fi" src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=ko-fi&logoColor=white" /></a> &nbsp;
<a href="https://github.com/sponsors/adrbn"><img alt="GitHub Sponsors" src="https://img.shields.io/badge/GitHub-Sponsors-EA4AAA?logo=githubsponsors&logoColor=white" /></a> &nbsp;, or star the repo.

## License

[GPL-3.0](LICENSE) © 2026 adrbn. You may share and change Aura under the same license; a modified version you distribute must stay open under GPL-3.0.

## Credits

- [LRCLIB](https://lrclib.net) for lyrics, [MusicBrainz](https://musicbrainz.org) for song credits, [Deezer](https://www.deezer.com)'s public catalogue for covers, artist photos, the Radar and previews, and the iTunes Search API for share links.
- Optional, with your own key: [Google Gemini](https://ai.google.dev) for lyrics translation and [Last.fm](https://www.last.fm) for listening statistics.
- Fonts: [Archivo](https://github.com/Omnibus-Type/Archivo) and Vavin, both under the SIL Open Font License 1.1.

<sub>Aura is not affiliated with Navidrome, Subsonic or Apple. All trademarks belong to their respective owners.</sub>
