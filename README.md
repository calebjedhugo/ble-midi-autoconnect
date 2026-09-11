# ble-midi-autoconnect

Keeps the Korg microKEY2-25 Air usable on macOS without opening Audio MIDI Setup
every time it powers on.

## Why this exists

macOS never auto-reconnects BLE MIDI devices. Apple's `midibluetoothd` publishes
the `microKEY2-25 Air Bluetooth` endpoints only for a device paired by hand in
the Bluetooth MIDI panel, and on power-off those endpoints vanish for good until
you click Connect again.

**A CoreBluetooth connection alone does not bring the endpoints back** — that was
the first attempt, and it failed: the radio reconnected in 3s and CoreMIDI still
showed zero endpoints.

So this agent *is* the driver. It connects over CoreBluetooth, subscribes to the
BLE MIDI characteristic, decodes the packets itself, and publishes its own
virtual CoreMIDI source. Apple's pairing UI is not involved.

## Layout

| Path | What |
|---|---|
| `main.swift` | Agent: CoreBluetooth connect + virtual CoreMIDI source |
| `BLEMIDIParser.swift` | BLE-MIDI packet decoder (timestamps, running status, split SysEx) |
| `tests/main.swift` | Parser unit tests — 13 cases |
| `monitor/main.swift` | `midi-monitor` — prints live MIDI from a port |
| `list-midi.swift` | `list-midi` — prints CoreMIDI sources/destinations |
| `~/Applications/BLEMIDIAutoConnect.app` | Installed copy — **TCC keys off this path** |
| `~/Library/LaunchAgents/com.calebhugo.ble-midi-autoconnect.plist` | Login agent |
| `~/Library/Logs/ble-midi-autoconnect.log` | Runtime log |

## Build + install

```bash
./build.sh          # builds, runs parser tests, installs, restarts
```

### First-time install

`build.sh` expects the app bundle and LaunchAgent to already be in place:

```bash
mkdir -p ~/Applications/BLEMIDIAutoConnect.app/Contents/MacOS
cp -R BLEMIDIAutoConnect.app/Contents/Info.plist ~/Applications/BLEMIDIAutoConnect.app/Contents/
envsubst < launchagent.plist > ~/Library/LaunchAgents/com.calebhugo.ble-midi-autoconnect.plist
./build.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.calebhugo.ble-midi-autoconnect.plist
```

`launchagent.plist` uses `$HOME` placeholders — expand them (`envsubst`, or edit by
hand) before installing. macOS will ask for Bluetooth permission on first run.

## Operate

```bash
tail -f ~/Library/Logs/ble-midi-autoconnect.log
./list-midi                    # expect: microKEY2-25 Air (auto)
./midi-monitor "(auto)"        # watch live notes
launchctl bootout  gui/$(id -u)/com.calebhugo.ble-midi-autoconnect   # stop
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.calebhugo.ble-midi-autoconnect.plist
```

A healthy startup ends with `LIVE — MIDI flowing to '...'`.

Target another keyboard by editing `--name` / `--port-name` in the plist
(`--name` is a case-insensitive substring; empty matches any BLE MIDI device).

## IMPORTANT gotchas

- **Must run under launchd.** TCC attributes Bluetooth access to the *responsible
  process*. Launched from a terminal it inherits the terminal's missing
  `NSBluetoothAlwaysUsageDescription` and dies with SIGABRT. launchd makes it its
  own responsible process.
- **Must be an `.app` bundle.** A bare executable with an embedded
  `__TEXT,__info_plist` section is still refused for CoreBluetooth.
- **Ad-hoc signing resets the TCC grant** when the code hash changes. If it stops
  working after `./build.sh`, re-approve in System Settings > Privacy & Security
  > Bluetooth. A denied grant logs `bluetooth permission denied`.
- **The keyboard only advertises on battery power.** Plugged into USB it is a USB
  MIDI device and the radio is off.
- microKEY auto-power-off (4 hr) drops the link; the agent reconnects in ~4s.
- Apple's `...Bluetooth` endpoint and this `(auto)` endpoint can coexist — both
  processes share the BLE link. If both are up, apps may see the keyboard twice.

## Design notes

- **Delivery timestamps.** Messages are delivered at receipt time
  (`mach_absolute_time`), not from the device's BLE timestamps, which would need
  clock reconciliation. piano-by-ear stamps with `performance.now()` on arrival
  (`src/midi.js`), so this loses nothing there. Revisit only if something needs
  sample-accurate jitter correction.
- **The virtual source outlives the connection** so clients keep their port open
  across power cycles instead of reopening on every reconnect.
- **Input only.** The microKEY has no sound engine, so no virtual destination is
  published. Adding one means writing to the BLE characteristic.
- `kMIDIPropertyUniqueID` is pinned so DAWs remember the port across restarts.

## Verified

- Parser: 13/13 unit tests (`./parser-tests`).
- Keyboard power-cycle: disconnect -> reconnect in ~4s, notes flow, virtual port
  never drops.
- Mac reboot: agent auto-starts at login, Bluetooth grant survives, pending
  connect fires the moment the keyboard is switched on. Apple's `...Bluetooth`
  endpoint stays absent - the `(auto)` port is the only one, and it works.
