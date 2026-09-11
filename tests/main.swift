import Foundation

var failures = 0
func check(_ label: String, _ got: [[UInt8]], _ want: [[UInt8]]) {
    if got == want { print("  PASS  \(label)") }
    else { print("  FAIL  \(label)\n        got:  \(got)\n        want: \(want)"); failures += 1 }
}

// Header 0x80, timestamp 0x80, then the message.
var p1 = BLEMIDIParser()
check("single note-on", p1.parse([0x80, 0x80, 0x90, 0x3C, 0x64]), [[0x90, 0x3C, 0x64]])

var p2 = BLEMIDIParser()
check("two messages, each timestamped",
      p2.parse([0x80, 0x80, 0x90, 0x3C, 0x64, 0x81, 0x80, 0x3C, 0x00]),
      [[0x90, 0x3C, 0x64], [0x80, 0x3C, 0x00]])

// Running status: second message omits the status byte after its timestamp.
var p3 = BLEMIDIParser()
check("running status within a packet",
      p3.parse([0x80, 0x80, 0x90, 0x3C, 0x64, 0x81, 0x3E, 0x50]),
      [[0x90, 0x3C, 0x64], [0x90, 0x3E, 0x50]])

// Running status must persist across BLE packets.
var p4 = BLEMIDIParser()
_ = p4.parse([0x80, 0x80, 0x90, 0x3C, 0x64])
check("running status across packets", p4.parse([0x80, 0x80, 0x3E, 0x50]), [[0x90, 0x3E, 0x50]])

// Sustain pedal (CC64) — two data bytes.
var p5 = BLEMIDIParser()
check("control change", p5.parse([0x80, 0x80, 0xB0, 0x40, 0x7F]), [[0xB0, 0x40, 0x7F]])

// Pitch bend and channel pressure (1 data byte).
var p6 = BLEMIDIParser()
check("pitch bend", p6.parse([0x80, 0x80, 0xE0, 0x00, 0x40]), [[0xE0, 0x00, 0x40]])
var p7 = BLEMIDIParser()
check("channel pressure (1 data byte)", p7.parse([0x80, 0x80, 0xD0, 0x55]), [[0xD0, 0x55]])

// Realtime clock interleaved; must not clobber running status.
var p8 = BLEMIDIParser()
check("realtime does not break running status",
      p8.parse([0x80, 0x80, 0x90, 0x3C, 0x64, 0x80, 0xF8, 0x81, 0x3E, 0x50]),
      [[0x90, 0x3C, 0x64], [0xF8], [0x90, 0x3E, 0x50]])

// SysEx split across two BLE packets, with a timestamp byte inside.
var p9 = BLEMIDIParser()
check("sysex start (incomplete yields nothing)",
      p9.parse([0x80, 0x80, 0xF0, 0x42, 0x40]), [])
check("sysex continues and terminates",
      p9.parse([0x80, 0x00, 0x01, 0x80, 0xF7]), [[0xF0, 0x42, 0x40, 0x00, 0x01, 0xF7]])

// Truncated message must not emit garbage.
var p10 = BLEMIDIParser()
check("truncated note-on emits nothing", p10.parse([0x80, 0x80, 0x90, 0x3C]), [])

// Empty / header-only packets.
var p11 = BLEMIDIParser()
check("header only", p11.parse([0x80]), [])

// A realistic burst: chord down then up.
var p12 = BLEMIDIParser()
check("chord burst",
      p12.parse([0x80, 0x80, 0x90, 0x3C, 0x64, 0x80, 0x40, 0x64, 0x80, 0x43, 0x64]),
      [[0x90, 0x3C, 0x64], [0x90, 0x40, 0x64], [0x90, 0x43, 0x64]])

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
