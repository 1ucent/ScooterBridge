# ScooterBridge

Turns an iPhone into a **Bluetooth LE gateway on your local network**.

Your phone has a real Bluetooth radio. Your laptop usually doesn't — or can't
reach BLE from inside a container (Waydroid, Anbox, VMs). ScooterBridge runs a
tiny HTTP server inside an iOS app and relays every request to CoreBluetooth,
so anything that can speak HTTP can drive a BLE peripheral through the phone.

Nothing about it is scooter-specific. It moves bytes; you decide what they mean.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | help + status |
| GET | `/status` | connection state, known characteristics |
| GET | `/scan` | scan ~6 s, return devices with RSSI |
| POST | `/connect?uuid=UUID` | connect to a peripheral from `/scan` |
| POST | `/disconnect` | drop the link |
| GET | `/services` | dump the whole GATT tree |
| POST | `/subscribe?char=FFF1` | enable notifications |
| POST | `/write?char=FFF2&data=55AABB[&type=cmd\|req]` | write bytes |
| GET | `/rx?clear=1` | drain buffered notifications |

`type=cmd` = write without response (default), `type=req` = with response.
If the characteristic only supports one, that one is used regardless.

## Usage

Launch the app, note the IP it shows, then:

```bash
BASE=http://192.168.1.50:8081

curl $BASE/scan
curl -X POST "$BASE/connect?uuid=PASTE-UUID-FROM-SCAN"
curl $BASE/services
curl -X POST "$BASE/subscribe?char=FFF1"
curl -X POST "$BASE/write?char=FFF2&data=0C0D0E&type=req"
curl "$BASE/rx?clear=1"
```

Notifications are buffered on the phone (last 500) and drained by `/rx`, so
you can poll instead of holding a socket open.

## Building

No Mac needed — push to GitHub and the workflow builds an unsigned `.ipa` on
`macos-latest`, attaches it as an artifact, and publishes it to the `nightly`
release.

Locally, on a Mac with Xcode and XcodeGen:

```bash
./build.sh
```

## Installing

Sideload the `.ipa` with **AltStore**, **Sideloadly**, or **TrollStore**.
iOS will ask for Bluetooth and Local Network permission on first launch —
both are required.

## Why this exists

Some BLE work needs a radio the computer doesn't have. Rather than buying a
USB adapter or fighting container passthrough, use the phone you already own
as the radio and keep the logic on the computer.

## Layout

```
project.yml                  XcodeGen spec (no .xcodeproj committed)
Sources/ScooterBridgeApp.swift  SwiftUI shell + status screen
Sources/BLEBridge.swift      CoreBluetooth + HTTP server
build.sh                     local unsigned IPA build
.github/workflows/build.yml  CI build + release
```
