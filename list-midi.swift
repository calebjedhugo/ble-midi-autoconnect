import CoreMIDI
import Foundation
func name(_ obj: MIDIObjectRef) -> String {
    var cf: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &cf) == noErr,
          let s = cf?.takeRetainedValue() else { return "?" }
    return s as String
}
print("MIDI sources (inputs to this Mac):")
let n = MIDIGetNumberOfSources()
if n == 0 { print("  (none)") }
for i in 0..<n { print("  [\(i)] \(name(MIDIGetSource(i)))") }
print("MIDI destinations:")
let d = MIDIGetNumberOfDestinations()
if d == 0 { print("  (none)") }
for i in 0..<d { print("  [\(i)] \(name(MIDIGetDestination(i)))") }
