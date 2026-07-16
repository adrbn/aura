<div align="center">

# Aura

**A native SwiftUI music client for Navidrome, Subsonic & compatible servers.**

Lossless streaming · time-synced lyrics · 5-band EQ · Instant Mix · full offline mode — with the polish of Apple Music, for the music *you* host.

*Free. Open source (MIT). No ads. No subscriptions. No feature gates.*

</div>

---

> **Aura is a client, not a server.** You point it at a Navidrome / Subsonic-compatible server you own or have access to — it plays your library, it doesn't host or provide any music.

## Why another client?

Every iOS Subsonic client felt dated, missed features that are table stakes in Apple Music, or wasn't *really* native. Aura is 100% SwiftUI, built for iOS 26, by one person who listens to a lot of music.

- **Free everywhere** — App Store, build-from-source, or sideload IPA
- **Open source (MIT)** — read it, audit it, build it yourself
- **No ads, no subscriptions, no locked features**
- Support development via **GitHub Sponsors / Ko-fi** (optional, never required)

## Features

**Playback** — gapless + adjustable crossfade, replay gain, stream at 128/192/320 kbps or keep lossless FLAC/ALAC, smart transcoding, **5-band parametric EQ** with 15 presets + custom curves, sleep timer (incl. "stop after this song"), full queue management (play next / add to queue / drag-reorder / autoplay), shuffle + three repeat modes, scrobbling with a configurable threshold.

**Lyrics** — time-synced scrolling lyrics (tap a line to jump), pulled from your server with **LRCLIB** as a community fallback, full-screen in landscape, and **search your whole library by lyric content**.

**Discovery** — **Instant Mix** radio from any song/artist, auto-generated **"Made For You"** genre / mood / time-of-day mixes, autoplay so the music never stops, and a **Year Wrapped** retrospective.

**Offline** — download songs, albums, playlists, or your whole library; streamed songs cache automatically for later; full offline search; a graceful offline mode that keeps working when the server is unreachable.

**Library** — unified fuzzy search (songs / albums / artists / playlists), smart result ranking, custom playlist cover art, smart duplicate detection (compares contents, not names), multi-folder Navidrome support, and **multiple server profiles** you can switch between right from the Home title.

**iOS integration** — Lock Screen & Control Center, system Now Playing in the **Dynamic Island**, **Siri Shortcuts** (play/pause, next, previous, shuffle — hands-free), AirPlay & Bluetooth auto-detection, Share Sheet, and Keychain-only credential storage (never plaintext).

**Appearance** — 7 accent colors, pure-black OLED mode, adjustable list density, reorderable tab bar, a landscape nightstand clock, and procedurally-generated cover art for anything missing artwork.

## How does it compare?

| Feature | Aura | Arpeggi | Amperfy | play:Sub | Substreamer |
|---|:-:|:-:|:-:|:-:|:-:|
| Native SwiftUI | ✅ | ✅ | Partial | ❌ | ❌ |
| Open source | ✅ MIT | ❌ | ✅ | ❌ | ❌ |
| On the App Store | ✅ | ❌ TestFlight | ✅ | ✅ | ✅ |
| Price | **Free** | Donation | Free | $4.99 + sub | Free + IAP |
| 5-band EQ + presets | ✅ | ❌ | ❌ | ✅ | ❌ |
| Time-synced lyrics | ✅ | Basic | ✅ | ❌ | ❌ |
| Search by lyric content | ✅ | ❌ | ❌ | ❌ | ❌ |
| Automatic streaming cache | ✅ | ❌ | ❌ | Partial | ❌ |
| Instant Mix / radio | ✅ | ❌ | ❌ | ❌ | ❌ |
| Siri Shortcuts | ✅ | ❌ | ❌ | ❌ | ❌ |
| Gapless + crossfade | ✅ | ✅ | Partial | ✅ | ✅ |
| Offline mode + downloads | ✅ | ✅ | ✅ | ✅ | ✅ |
| Multiple server profiles | ✅ | ✅ | ✅ | ❌ | ✅ |
| Duplicate detection (playlists) | ✅ | ❌ | ❌ | ❌ | ❌ |
| Custom playlist cover art | ✅ | ❌ | ❌ | ❌ | ❌ |
| Dynamic Island / Now Playing | ✅ | ✅ | ❌ | ❌ | ❌ |

*Corrections welcome — open an issue.*

## Compatibility

- **Navidrome** — primary target, tested daily
- Any **Subsonic API v1.16.1**-compatible server (Airsonic, Gonic, …)
- **LRCLIB** for community lyrics
- Requires an existing server; Aura does not host content.

## Build from source

```bash
git clone https://github.com/adrbn/aura
cd aura
open Musika/Aura.xcodeproj
```

Requires **Xcode 26+** and an **iOS 26** deployment target. Select the `Aura` scheme and run.

> There are two build configurations: the App Store build, and a sideload build that additionally bundles an optional Soulseek/slskd integration (stripped from the App Store version via a compile flag).

## Support the project

- **GitHub Sponsors** · **Ko-fi**
- ⭐ **Star the repo** — it genuinely helps discovery

## License

MIT — Copyright (c) 2026 Adrien Robino. See [LICENSE](./LICENSE).

Aura is not affiliated with Navidrome, Subsonic, Apple, or any server project mentioned. All trademarks belong to their respective owners.
