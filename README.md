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
- 📝 **Lyrics** — word-by-word karaoke via the OpenSubsonic v2 lyrics extension, falling back to line timings and then plain text. Each word lights as it is sung, and the surrounding lines fall away in size, blur and opacity so only the line being sung competes for attention. Tap a line to jump, adjustable timing offset, full-screen in landscape.
- 📻 **Discovery** — **Instant Mix** from any song/artist, auto-generated genre / mood / time-of-day **"Made For You"** mixes, and a **Year Wrapped** retrospective.
- ✈️ **Offline** — download songs / albums / playlists / whole library, automatic streaming cache, offline search, and a graceful offline mode when the server is unreachable.
- 📚 **Library** — fuzzy unified search ranked by relevance — with a Recently Searched list that records what you actually *played*, not everything you tapped — an A–Z fast-scroll rail on long lists, shuffle-all, custom playlist covers, content-based duplicate detection, multi-folder Navidrome, and **multiple server profiles** switchable from the Home title.
- 🍎 **iOS integration** — Lock Screen & Control Center, system Now Playing in the **Dynamic Island**, **Siri Shortcuts** (play · pause · next · previous · shuffle · repeat · favourite, plus **"play <playlist>"** and **"play <album>"**), AirPlay, Share Sheet, and Keychain-only credentials.
- 🎨 **Appearance** — dark by default, 7 accent colors, pure-black OLED mode, adjustable density, reorderable tabs, a landscape nightstand clock, generated cover art for missing artwork, and titles too long to fit scroll so you can read them in full.

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

> **A note on the typeface.** Aura is set in **Vavin Condensed**, a Garamond-inspired face
> drawn for this app and released under the **SIL Open Font License 1.1**. It lives in this
> repository and ships in the build — no licence to buy, nothing to drop in. `Vavin-OFL.txt`
> travels in the app bundle as the licence requires, and About carries the acknowledgement.

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
