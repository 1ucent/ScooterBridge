# Phantomgogo / LQ-AC200F5 scooter — BLE protocol

Reverse engineered from `com.dt.smart.gogo` (GOGO Connect Ride) and confirmed
against a real scooter (`LQ-AC200F5`, `F8:F2:F0:A0:3E:D5`).

## GATT

```
service 0000fff0-0000-1000-8000-00805f9b34fb
  fff1  notify   scooter -> app
  fff2  write-without-response   app -> scooter
  fff3  notify   (second channel)
```

The device also exposes:
- `00001530-1212-efde-1523-785feabcd123` — Nordic DFU (firmware update)
- `49535343-fe7d-4ae5-8fa9-9fafd205e455` — Microchip/ISSC transparent UART

## Outgoing packet (v1) — what the scooter accepts

```
[0] 0x55          header
[1] cmd
[2] len           number of data bytes
[3..] data
[n] checksum      ~(XOR of every preceding byte)
```

Total length = len + 4.

## Incoming packet (v2) — what the scooter sends

```
[0] H             H = ~(XOR of all six MAC bytes)
[1] cmd - r
[2] len + 1
[3..] data        (len bytes)
[len+3] r         random byte
[n] checksum      ~( K2 ^ ((xorAll ^ K0) ^ K1) )
                  xorAll covers every byte before the checksum
                  K = 0x0A, 0x0B, 0x0C
```

Decode: `cmd = (frame[1] + r) & 0xFF`

For MAC `F8:F2:F0:A0:3E:D5`: XOR = 0xB1, so **H = 0x4E**.

### Verified capture

```
4E DF 0D 02 01 05 01 02 00 64 01 01 02 00 00 59 54
   head 0x4E ✓
   cmd = 0xDF + 0x59 = 0x38
   checksum 0x54 ✓ (matches formula exactly)
   data = 02 01 05 01 02 00 64 01 01 02 00 00
                                     0x64 = 100  (battery?)
```

## Authentication

The scooter ignores commands until authenticated (this is the current blocker —
it accepted writes but never replied once the session went stale).

`CMD 0x02` payload is **three (index, value) pairs**:

```
payload = [ i1, table[i1], i2, table[i2], i3, table[i3] ]
```

`table` is 256 bytes from `res/raw/authentication.txt` in the APK — saved here
as `gogo_auth.txt`. The scooter validates each pair against its own copy, then
answers `CMD 0x03` containing a result byte.

The app picks the three indices at random.

## Command bytes (`CommonCMD`)

| cmd | value | meaning |
|---|---|---|
| 0x02 | 2 | auth |
| 0x03 | 3 | auth result (reply) |
| 0x04 | 4 | firmware version request |
| 0x05 | 5 | firmware version (reply) |
| 0x06 | 6 | timing sync |
| 0x09 | 9 | error report |
| 0x0B | 11 | charge report |
| 0x0C | 12 | check protocol version |
| 0x0D | 13 | protocol version (reply) |
| 0x20 | 32 | upgrade reset |
| 0x22 | 34 | upgrade request |
| 0x24 | 36 | upgrade packet |
| 0x26 | 38 | upgrade done |
| **0x32** | **50** | **set control / parameter** |
| 0x34 | 52 | self check |
| 0x37 | 55 | params group |
| 0x38 | 56 | seen on the wire, no handler in this app build |
| 0x63 | 99 | sync history |
| 0x65 | 101 | sync history report |
| 0x70 | 112 | near-unlock RSSI |
| 0x72 | 114 | BLE pair PIN |

## Control command 0x32

```
data = [param_index, value_hi, value_lo]
```

## Parameters (`PARAMS` enum order)

```
 0 firmware_version          14 head_lamp              28 tcs_mode
 1 total_ride_distance       15 auto_power_off_time    29 auto_light_mode
 2 total_ride_time           16 unit                  30 limit_speed_1
 3 trip_mileage              17 gear                  31 limit_speed_2
 4 trip_time                 18 lock                  32 limit_speed_3
 5 trip_avg_speed            19 background_light      33 battery_remain_capacity
 6 avg_speed                 20 boot_mode             34 battery_discharge_rate
 7 battery_percent           21 cruise_mode           35 battery_produced_date
 8 remain_distance           22 energy_recovery       ...
 9 real_power                23 mood_light            42 battery_temperature
10 rated_power               24 auto_lock_of_power_off
11 voltage_value             25 light_color
12 electricity_value         26 light_mode
13 realtime_speed            27 ble_find_car_status
```

Speeds in reports are 16-bit big-endian. `unit`: 0 = km/h, 1 = mph.

The app's speed-limit UI wheel only goes 1–13; the protocol field is one byte
(0–255). The real ceiling is whatever the motor controller firmware enforces —
sending above it will be ignored or clamped.


## Connection handshake (THE KEY FINDING)

Commands are **ignored** until the handshake completes. This is why writes
succeeded but the scooter stayed silent and only beeped.

The app walks a state machine (`ConnectStep` in DeviceVM):

```
Connect -> Version -> Auth -> Time -> Firmware -> Communicating
```

In order:

| step | cmd | payload |
|---|---|---|
| 1 | `0x0C` | none — check protocol version |
| 2 | `0x02` | `[authIndex, i1, v1, i2, v2, i3, v3]` (7 bytes, v2 form) |
| 3 | `0x06` | `[tz_hours, year%2000, month, day, hour, min, sec]` |
| 4 | `0x04` | none — firmware version request |

auth retries up to 3 times with `authIndex` = 0, 1, 2.
If `VERSION >= 2` use the 7-byte auth form, else the 6-byte form
(`[i1,v1,i2,v2,i3,v3]`).

`build_handshake()` in `gogo_tool.py` produces this sequence:

```
1 version    55 0C 00 A6
2 auth       55 02 07 00 7A C3 79 7E CC DF 02
3 time       55 06 07 FB 1A 0B 08 0B 0E 1A 56
4 firmware   55 04 00 AE
```

Run it with:

```bash
python3 gogo_tool.py <MAC> handshake
```

## Controls (CMD 0x32)

`sendControl(item, value)` -> payload `[item, value_hi, value_lo]`.
These ids are **separate from the PARAMS enum**:

| item | control | notes |
|---|---|---|
| 3 | speed limit | hi byte = gear (1-3), lo byte = speed |
| 4 | unit | 0 = km/h, 1 = mph |
| 5 | gear | 1, 2, 3 |
| 6 | lock | 0 unlocked, 1 locked |
| 8 | **zero start** | 0 = kick start, 1 = zero start |
| 10 | energy recovery | |
| 13 | auto power off | |

Speed limit is sent as `sendControl([3, gear, speed])` (see `setLimitV2`).

## Tools

| file | purpose |
|---|---|
| `gogo_tool.py` | connect, auth, send commands, decode v2 replies |
| `gogo_auth.txt` | the 256-byte auth table |
| `gogo.py` | packet builder / parameter table reference |
| `gogo_re.py` | re-run the APK analysis from scratch |

```bash
python3 gogo_tool.py F8:F2:F0:A0:3E:D5 probe
python3 gogo_tool.py F8:F2:F0:A0:3E:D5 send 5532030E000194
```

## Current blocker

The scooter answered **once**, on the first fresh connection, then stopped
replying to everything — including the exact script that had worked.

Writes still succeed; no notifications come back on either fff1 or fff3.

Likely causes, in order:
1. BLE session stuck from repeated connect/disconnect — needs a real
   power-cycle of the scooter between attempts.
2. The scooter requires the auth handshake *before* it will transmit anything,
   and our auth is being rejected silently.
3. The BLE module is still bonded/held by the phone app.

Next step: power-cycle the scooter, run the probe **immediately** on a fresh
connection, and watch for a `CMD 0x03` auth reply.


## Confirmed on hardware (what works vs what does not)

**Works:**
- scan / connect / GATT discovery
- subscribe to fff1 + fff3 (notify)
- writes to fff2 succeed with both write-with-response and write-without-response
- one inbound frame was captured and decoded correctly (cmd 0x38)

**Does not work:**
- the scooter never transmits in response to anything we send
- controls are ignored: zero_start, speed limit, lock — sent, accepted by
  BlueZ, no effect on the scooter

### Two corrections found late

1. **Auth format depends on protocol version.** If the version check (0x0C)
   gets no reply 3 times, the app logs "版本确认超时，为旧协议仪表" and treats
   the meter as OLD protocol:
   - `setVersion(0)` -> uses `packAuthCmd()` = **6 bytes, no authIndex**
   - authIndex (sort) starts at 1
   Otherwise it uses `packAuthCmdV2(authIndex)` = 7 bytes.

2. **The app writes WITH response.** FastBle never calls `setWriteType`, so
   Android uses WRITE_TYPE_DEFAULT (with response).

Even with both corrected, the scooter still ignores our commands.

### Remaining unknown

The one thing never verified: an actual write as the app performs it.
Everything else is inferred from decompiled code. Without a phone or working
Waydroid Bluetooth, that last detail cannot be observed.

Likely remaining causes:
- a cloud-issued session/binding token the app holds and we do not
- a characteristic or UUID supplied per-device by the server via `BleUUID`
- a pairing/bond step that Android performs and BlueZ from a script does not


## ⚠️ THE CRITICAL CORRECTION — outgoing packets must be v2

This is what made everything work. Earlier sections describing a `0x55`
v1 packet for *outgoing* traffic are WRONG for this scooter.

```java
// CommonPacker
return this.VERSION > 0 ? packCmdV2(cmd, data) : packCmd(cmd, data);
```

Once the protocol version is > 0 the app builds **every outgoing packet** in
v2 form, starting with `CMD_HEAD_MAC` = `~XOR(MAC)` = **0x4E** — the same
header the scooter uses when it talks.

Sending v1 (`0x55`) frames gets a correct checksum, a valid command byte, and
is silently ignored. That is exactly what happened for hours.

### Outgoing v2 packet

```
[0]     0x4E                 = ~XOR(all six MAC bytes)
[1]     cmd - r
[2]     len(data) + 1
[3..]   data
[len+3] r                    random byte
[last]  ~( K2 ^ ((xorAll ^ K0) ^ K1) )
        K = 0x0A, 0x0B, 0x0C ; xorAll covers every byte before the checksum
```

### Verified working

```
>> 4E 9F 04 03 01 05 93 B3      gear 1 limit = 5 km/h
<< 4E BF 04 03 01 05 74 74      echo  data = 03 01 05

>> 4E 67 04 03 03 20 CB 34      gear 3 limit = 32 km/h (20 mph)
<< 4E 61 04 03 03 20 D2 2B      echo  data = 03 03 20

>> 4E AA 04 08 00 00 88 92      zero_start OFF
<< 4E 0B 04 08 00 00 28 93      echo  data = 08 00 00
```

The scooter **echoes the data payload back**, which is a free read-back for
confirming a setting took.

### Second gotcha: only one central at a time

A BLE peripheral stops advertising while connected. While the laptop held a
connection to the scooter, the phone could not see it at all. Disconnect and
forget on every other host before scanning from the one you want to use.

### Third gotcha: control ids are not the PARAMS enum

`sendControl(item, value)` -> `[item, value_hi, value_lo]`

| item | control |
|---|---|
| 3 | speed limit — hi = gear (1-3), lo = speed in km/h |
| 4 | unit (0 km, 1 miles) |
| 5 | gear (1/2/3) |
| 6 | lock |
| 8 | zero start |
| 10 | energy recovery |
| 13 | auto power off |


## Empirically measured limit range (LQ-AC200F5)

Tested by writing values and riding:

| Sent | Echoed back | Actually enforced |
|---|---|---|
| 48 km/h (30 mph) | 48 km/h | **no** - motor caps itself |
| 32 km/h (20 mph) | 32 km/h | **no** |
| 16 km/h (10 mph) | 16 km/h | yes |
| 8 km/h (5 mph) | 8 km/h | accepted but outside range |

**The motor controller only honours 10-15 mph.** Values outside that are
stored and echoed back faithfully but do not change the actual top speed.

So the speed-limit parameter is a *request*, not an authoritative setting:
the controller firmware enforces its own ceiling. There is no "unlock" on
this model - the commonly described trick of raising the limit does nothing
here, because the write succeeds and the motor ignores it.

Downward adjustment (slowing the scooter) does work and is enforced.


## No telemetry - confirmed experimentally

The scooter is **write-only** from the host's point of view.

Measured with a live read channel, subscribed to both FFF1 and FFF3:

| Situation | Frames received |
|---|---|
| Send a command | 1 echo, immediately |
| Ride it (coast / throttle / hard throttle) | **0** |
| Press power / light / mode buttons | **0** |
| Idle, listening 55 s | **0** |

Earlier one-off frames (cmd 0x38) were replies to something, not a periodic
broadcast - a 55 second silent listen produced nothing.

### Consequence

Remote throttling is **impossible** on this hardware, for two independent
reasons:

1. There is no motor / throttle command in the protocol. Control ids are
   limits and gates only (gear, lock, limits, lights, zero-start).
2. There is no throttle or speed telemetry to react to. The command `0x38`
   frames seen once carried `02 01 05 01 03 00 64 01 01 02 00 00` - a
   snapshot with gear (0x03) and what looks like battery (0x64 = 100) - but
   it does not stream, and no byte was observed tracking throttle.

The closest achievable thing is a **remote speed cap**: set all three gear
limits to the floor (10 mph) and the scooter cannot exceed it. That is a step
change with ~1-2 s latency, not a throttle.

## Safety note

`limit_speed_1/2/3` are the speed limiters. Raising them is the one change here
that can physically hurt you — brakes, tyres and frame are rated for the legal
limit. Lights, gear, cruise, TCS and telemetry reads are all harmless.
