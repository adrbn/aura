<div align="center">

<img src="./aura-iOS-Default-1024x1024@1x.png" width="118" alt="Aura app icon" />

# Aura

**A native SwiftUI music client for Navidrome, Subsonic & compatible servers.**

Lossless streaming · time-synced lyrics · 5-band EQ · Instant Mix · full offline mode — the polish of Apple Music, for the library *you* host.

<p>
<img alt="Platform: iOS 26+" src="https://img.shields.io/badge/iOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white" />
<img alt="Built with SwiftUI" src="https://img.shields.io/badge/SwiftUI-000000?style=flat-square&logo=swift&logoColor=F05138" />
<img alt="Swift" src="https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white" />
<img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-3DA639?style=flat-square" />
<img alt="Price: Free" src="https://img.shields.io/badge/Price-Free-2ea44f?style=flat-square" />
</p>

<p>
<a href="https://github.com/adrbn/aura/releases"><img alt="Download IPA" src="https://img.shields.io/badge/⬇_Download_IPA-Releases-0D1117?style=for-the-badge&logo=github&logoColor=white" /></a>
<a href="https://ko-fi.com/adrbn"><img alt="Ko-fi" src="https://img.shields.io/badge/Ko--fi-Buy_me_a_coffee-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white" /></a>
<a href="https://github.com/sponsors/adrbn"><img alt="Sponsor" src="https://img.shields.io/badge/Sponsor-EA4AAA?style=for-the-badge&logo=githubsponsors&logoColor=white" /></a>
</p>

</div>

---

> **Aura is a client, not a server.** Point it at a Navidrome / Subsonic-compatible server you own — it plays your library, it doesn't host or provide any music.

## ✨ Highlights

- 🎧 **Playback** — gapless + crossfade, replay gain, lossless FLAC/ALAC or smart transcoding, **5-band parametric EQ** (15 presets + custom), sleep timer, full queue (play next / add / drag-reorder / autoplay), scrobbling.
- 📝 **Lyrics** — time-synced scrolling lyrics (tap to jump), server-first with **LRCLIB** fallback, and full-screen in landscape.
- 📻 **Discovery** — **Instant Mix** from any song/artist, auto-generated genre / mood / time-of-day **"Made For You"** mixes, and a **Year Wrapped** retrospective.
- ✈️ **Offline** — download songs / albums / playlists / whole library, automatic streaming cache, offline search, and a graceful offline mode when the server is unreachable.
- 📚 **Library** — fuzzy unified search, smart ranking, custom playlist covers, content-based duplicate detection, multi-folder Navidrome, and **multiple server profiles** switchable from the Home title.
- 🍎 **iOS integration** — Lock Screen & Control Center, system Now Playing in the **Dynamic Island**, **Siri Shortcuts** (play/pause · next · previous · shuffle), AirPlay, Share Sheet, and Keychain-only credentials.
- 🎨 **Appearance** — 7 accent colors, pure-black OLED mode, adjustable density, reorderable tabs, a landscape nightstand clock, and generated cover art for missing artwork.

## 🛠️ Built with

`SwiftUI` · `Swift Concurrency` · `AVFoundation` (playback + EQ) · `MediaPlayer` (Now Playing / remote commands) · `App Intents` (Siri) · `WidgetKit` + `ActivityKit` · `CryptoKit` (cache) · `Security` / Keychain · `URLSession` — talking to the **Subsonic API** and **LRCLIB**. 100% native, no third-party UI frameworks.

## 📊 How it compares

| | Aura | Arpeggi | Amperfy | play:Sub | Substreamer |
|---|:-:|:-:|:-:|:-:|:-:|
| Native SwiftUI | ✅ | ✅ | ~ | ❌ | ❌ |
| Open source | ✅ MIT | ❌ | ✅ | ❌ | ❌ |
| Price | **Free** | Donation | Free | $4.99+sub | Free+IAP |
| 5-band EQ + presets | ✅ | ❌ | ❌ | ✅ | ❌ |
| Time-synced lyrics | ✅ | ~ | ✅ | ❌ | ❌ |
| Auto streaming cache | ✅ | ❌ | ❌ | ~ | ❌ |
| Instant Mix / radio | ✅ | ❌ | ❌ | ❌ | ❌ |
| Siri Shortcuts | ✅ | ❌ | ❌ | ❌ | ❌ |
| Offline + downloads | ✅ | ✅ | ✅ | ✅ | ✅ |
| Multiple servers | ✅ | ✅ | ✅ | ❌ | ✅ |
| Dynamic Island | ✅ | ✅ | ❌ | ❌ | ❌ |

<sub>Corrections welcome — open an issue.</sub>

## 📦 Install

| | |
|---|---|
| **App Store** | _Coming soon_ |
| **Free IPA** (AltStore / SideStore) | [**Releases →**](https://github.com/adrbn/aura/releases) |
| **Build from source** | See below |

```bash
git clone https://github.com/adrbn/aura
cd aura
open Aura/Aura.xcodeproj   # Xcode 26+, iOS 26 target — run the "Aura" scheme
```

> **A note on the typeface.** Aura's display font is [**Tuaf**](https://www.futurefonts.xyz/), a
> commercial font. Its licence covers embedding it in a built app — not redistributing the file —
> so the `.otf` is **not** in this repository. The app builds and runs fine without it and falls
> back to the system font; the headings just won't look like the screenshots. To get the intended
> typography, buy a licence and drop `TuafTrial-Bold.otf` into `Aura/Aura/` — the build picks it
> up automatically.

> Two configurations ship: the App Store build, and a sideload build that additionally bundles an optional Soulseek/slskd integration (compiled out of the App Store version).

## 🔌 Compatibility

**Navidrome** (primary, tested daily) · any **Subsonic API v1.16.1**-compatible server (Airsonic, Gonic…) · **LRCLIB** for community lyrics. Requires an existing server — Aura hosts nothing.

## ❤️ Support

Aura is free and open source. If it earns a place on your home screen, you can support development:

<a href="https://ko-fi.com/adrbn"><img alt="Ko-fi" src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?style=flat-square&logo=ko-fi&logoColor=white" /></a> &nbsp;
<a href="https://github.com/sponsors/adrbn"><img alt="GitHub Sponsors" src="https://img.shields.io/badge/GitHub-Sponsors-EA4AAA?style=flat-square&logo=githubsponsors&logoColor=white" /></a> &nbsp; and ⭐ **star the repo** — it genuinely helps discovery.

## 📄 License

MIT © 2026 Adrien Robino — see [LICENSE](./LICENSE).

<sub>Aura is not affiliated with Navidrome, Subsonic, Apple, or any server project mentioned. All trademarks belong to their respective owners.</sub>
