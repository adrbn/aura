# Installing a build over cellular

`scripts/ota-publish.sh` puts a development build on the iPhone with no cable,
no shared Wi-Fi and no Xcode in front of it: one command here, one tap there.

```bash
./scripts/ota-publish.sh
```

It prints a URL. Open it on the phone, with Tailscale on, tap **Install**, then
open Aura once.

## Why not devicectl

`devicectl` only talks to a device CoreDevice found itself, over Bonjour, on
the local link, and iOS only runs `remotepairingd` while on Wi-Fi. Off that
network there is nothing to connect to (`CoreDeviceError 1000`, or `4016` when
the phone has gone to sleep). Apple's over-the-air install runs over plain
HTTPS, so it works from anywhere the phone can reach the server.

## How it works

1. `xcodebuild archive` with the Aura scheme, then `-exportArchive` with
   `method: debugging` and a `manifest` dictionary, which makes Xcode write
   `manifest.plist` next to the `.ipa`.
2. The `.ipa`, the manifest, two icon sizes and a small install page are copied
   to an always-on machine on the tailnet.
3. `tailscale serve --bg --set-path /aura <dir>` publishes them over HTTPS with
   a real certificate — `itms-services://` refuses anything less.
4. The script fetches the manifest back and fails loudly unless it answers 200.

## Settings

The host is personal infrastructure, so it lives in `scripts/ota.env`, which is
gitignored:

```sh
AURA_OTA_HOST=machine.your-tailnet.ts.net   # what the phone will reach
AURA_OTA_SSH=root@machine.your-tailnet.ts.net
AURA_OTA_DIR=/opt/aura-ota
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer   # optional
```

The serving machine must run open-source `tailscaled`: the App Store build of
Tailscale on a Mac refuses `--set-path`. Xcode must be signed in to the team
that owns the bundle id, and the phone's UDID must be in the development
profile — the same conditions as any local install.

## What it does not do

It installs; it does not launch. Until Aura has run once after an install, its
App Intents aren't registered again, so Siri and Shortcuts can't find it.

## When it goes wrong

| Symptom | Cause |
| --- | --- |
| The page loads, **Install** does nothing | The manifest wasn't served over valid HTTPS, or its `appURL` doesn't match where the `.ipa` is. |
| "Unable to install" on the phone | The device isn't in the provisioning profile, or the profile expired. |
| Nothing loads at all | Tailscale is off on the phone; the tailnet name resolves nowhere else. |

To clean up, remove only `/aura` from `tailscale serve`. Never turn off the
whole HTTPS listener: it serves other paths too.
