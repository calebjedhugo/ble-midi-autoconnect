#!/bin/bash
# Build, install, and restart the agent. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")"

swiftc -swift-version 5 -O main.swift BLEMIDIParser.swift -o ble-midi-autoconnect \
  -framework CoreBluetooth -framework CoreMIDI -framework Foundation
swiftc -swift-version 5 BLEMIDIParser.swift tests/main.swift -o parser-tests
swiftc -swift-version 5 list-midi.swift -o list-midi -framework CoreMIDI
swiftc -swift-version 5 monitor/main.swift -o midi-monitor -framework CoreMIDI

./parser-tests   # abort the install if parsing regressed

cp ble-midi-autoconnect BLEMIDIAutoConnect.app/Contents/MacOS/ble-midi-autoconnect
cp ble-midi-autoconnect ~/Applications/BLEMIDIAutoConnect.app/Contents/MacOS/ble-midi-autoconnect
codesign -s - --force --deep ~/Applications/BLEMIDIAutoConnect.app
launchctl kickstart -k "gui/$(id -u)/com.calebhugo.ble-midi-autoconnect"
echo "installed and restarted — tail ~/Library/Logs/ble-midi-autoconnect.log"
echo "NOTE: re-signing may reset the Bluetooth permission grant."
