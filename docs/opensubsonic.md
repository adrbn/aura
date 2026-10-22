# OpenSubsonic support in Aura

Aura talks to any Subsonic API server (1.16.1). When the server says it speaks OpenSubsonic (`openSubsonic: true` in its responses), Aura also reads these:

| OpenSubsonic feature | What Aura does with it |
|---|---|
| `getLyricsBySongId` (`songLyrics` v1 and v2, asked with `enhanced=true`) | Synced lyrics line by line, and word by word from v2's cues, shifted by the server's `offset`. Falls back to `getLyrics` and other sources when a song has none. |
| `replayGain` on songs | Track gain, or album gain when the track has none, applied when ReplayGain is on in Settings. |
| `releaseTypes` on albums | Splits an artist's page into albums, then singles and EPs. |
| `sortName` on albums and artists | Sorts lists the way the server does ("The Beatles" under B). |
| `played` on songs | Recently Played lists songs by their last play. |

Everything else uses the original Subsonic API, so Aura works the same on servers without these fields.

This page is updated when Aura reads a new OpenSubsonic feature.
