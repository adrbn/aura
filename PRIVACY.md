---
title: Aura Privacy Policy
description: How Aura handles your data. Short version — it doesn't leave your device.
---

# Aura Privacy Policy

**Last updated:** 2026-09-25
**Effective date:** same as above

Aura ("the app") is a music playback client for Subsonic-API-compatible servers (Navidrome, Airsonic, Gonic, and others) that **you** host or have legitimate access to. This policy explains what information Aura handles and what it does not.

## TL;DR

- Aura collects **no** personal data.
- Aura sends **nothing** to any server owned by the developer.
- All data (server URLs, credentials, playback state, cached audio) stays on your device.
- Aura talks to the servers you configure. To find lyrics, share links, song credits, artist photos and new releases, it also looks up a track's or an artist's name on a few public services, listed below — never on a server run by the developer.

## Data Aura stores on your device

### Stored in iOS Keychain (encrypted by iOS)

- Your server password(s)
- Your Soulseek / slskd password (sideload build only — not present in App Store build)

Keychain entries are scoped to Aura and can be cleared by deleting the app.

### Stored in UserDefaults (plaintext, sandboxed)

- Server URL(s) and usernames
- UI preferences (theme, accent color, home dashboard layout, etc.)
- Playback preferences (EQ curve, transcoding, sleep timer)
- Last-played state (queue, current track, position)
- Download quality settings

### Stored in app container (sandboxed)

- Cover art cache (thumbnails)
- Streaming cache (partial audio files — automatically evicted by LRU policy)
- Downloaded songs (when you explicitly download them for offline use)
- Local database of your library metadata (for offline search)

All of the above is removed when you delete the app.

## Data Aura sends over the network

### To your configured Subsonic/Navidrome server

- Standard Subsonic API requests (authentication, library fetches, stream/download)
- Scrobble submissions (if enabled)

These go **only** to the server URL(s) you explicitly configure in Settings. Aura does not bypass this or contact any other endpoint on your behalf.

### To LRCLIB (optional, on-demand)

- Song metadata (artist, title, album, duration) used solely to look up community-contributed time-synced lyrics

LRCLIB ([lrclib.net](https://lrclib.net)) is a public free service. Aura queries it when your own server does not provide lyrics, and once per song when a song names a version — a featured artist, a remix, a translation — to check that the lyrics found are that version's.

### To streaming-link services (for the song share sheet)

So that the Share sheet can offer "open on Spotify / Apple Music / Deezer / YouTube Music" links, Aura looks up the currently playing track on other platforms. The track's **artist and title**, plus your device's **country/region code**, are sent to these public, free, keyless APIs:

- **Apple iTunes Search API** — `itunes.apple.com`
- **Deezer API** — `api.deezer.com`

The share sheet can also offer a song.link address, which Aura builds from the Apple track ID it found; Aura does not contact song.link itself.

This lookup runs when a song starts playing (so the links are ready instantly) and the result is cached. No account, device identifier, or audio is sent — only the track name to find matching links — and none of it goes to a developer-owned server.

### To Deezer (artist photos and Release Radar)

To put an artist's photo on a "Made For You" mix or radio cover, Aura looks the artist up in Deezer's public, free, keyless catalogue (`api.deezer.com`) and downloads the photo from Deezer's image servers. Only the **artist's name** is sent — no account, device identifier, or listening history. Each photo is fetched once and kept in the app's cache.

For the **Release Radar** mix, Aura asks the same catalogue, about once a day, for the recent releases of the artists you play most on your server — up to 80 of them — and downloads the covers of the releases it lists. Deezer receives each artist's **name** the first time, and their Deezer ID after that; it receives no account, device identifier, play counts, or song you played. Taken together, those requests do say whose music you listen to: if you'd rather Deezer didn't see that, switch the Radar off in **Settings → Release Radar** and Aura makes none of them.

### To MusicBrainz (for song credits)

When you open a song's credits/info, Aura queries the public **MusicBrainz** database (`musicbrainz.org`) with the artist and title to fetch writer/producer/label credits. No account or identifier is sent.

### To Last.fm (optional, opt-in)

If you enable the Last.fm integration in Settings, you supply **your own** Last.fm username and API key. Aura then sends requests to the Last.fm API (`ws.audioscrobbler.com`) to fetch your listening statistics and artist/album images, used for features such as the year Wrapped summary. Your API key is stored in the iOS Keychain (never in UserDefaults); the username is stored locally with your other preferences. These requests go directly from your device to Last.fm — nothing is sent to the developer. The feature is off by default and can be disabled at any time in Settings.

### To Apple (standard iOS mechanisms)

- Crash reports, if you have "Share with App Developers" enabled in iOS Settings → Privacy & Security → Analytics & Improvements. Apple aggregates and forwards these; Aura reads them via Xcode Organizer.
- Apple Music / MediaPlayer / AVKit system integrations (Now Playing metadata for Control Center and the Lock Screen).

Aura does not use any third-party analytics, telemetry, attribution, or advertising SDK.

## Data the developer receives

None, with one exception: if you voluntarily open an issue on our GitHub repository or email us for support, we obviously see whatever you send. We do not aggregate, sell, or share that information.

## Third-party content

Aura is a client for user-hosted music servers. The content displayed and played through Aura is hosted by you or a server you have access to. Aura does not provide, distribute, or host any music content. You are responsible for ensuring that the content on your configured servers is licensed or owned by you.

## Children's privacy

Aura has no account system, no user-generated content surfaces, no ads, and no data collection. Usage by children under 13 is permitted under the app's 4+ age rating. We do not knowingly collect any information from any user.

## Changes to this policy

We may update this policy as Aura evolves. Material changes will be noted in the `Last updated` date at the top and, where relevant, in the app's release notes.

## Contact

- **Issues / general questions:** Contact: via the App Store listing
- **Privacy-specific questions:** Contact: via the App Store listing

## Jurisdiction

Aura is a free/open-source project published from France. EU/GDPR applies by default. Under GDPR Articles 15–22 you have rights to access, rectification, erasure, restriction, portability, and objection — however, because Aura holds no personal data about you on any server we control, there is generally nothing to exercise those rights against. If you believe otherwise, contact us via the App Store listing.
