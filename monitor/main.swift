import CoreMIDI
import Foundation

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "(auto)"

func name(_ o: MIDIObjectRef) -> String {
    var cf: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &cf) == noErr,
          let s = cf?.takeRetainedValue() else { return "?" }
    return s as String
}
func noteName(_ n: UInt8) -> String {
    let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    return "\(names[Int(n) % 12])\(Int(n)/12 - 1)"
}

var client = MIDIClientRef()
MIDIClientCreate("midi-monitor" as CFString, nil, nil, &client)
var port = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { pktList, _ in
    let packets = pktList.unsafeSequence()
    for p in packets {
        let len = Int(p.pointee.length)
        var bytes: [UInt8] = []
        withUnsafeBytes(of: p.pointee.data) { raw in bytes = Array(raw.prefix(len)) }
        guard let st = bytes.first else { continue }
        var desc = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        if st & 0xF0 == 0x90, bytes.count >= 3, bytes[2] > 0 {
            desc += "   NOTE ON  \(noteName(bytes[1])) vel=\(bytes[2])"
        } else if st & 0xF0 == 0x80 || (st & 0xF0 == 0x90 && bytes.count >= 3) {
            desc += "   note off \(noteName(bytes[1]))"
        } else if st & 0xF0 == 0xB0, bytes.count >= 3 {
            desc += "   CC\(bytes[1])=\(bytes[2])"
        }
        print(desc); fflush(stdout)
    }
}

var found = false
for i in 0..<MIDIGetNumberOfSources() {
    let src = MIDIGetSource(i)
    if name(src).contains(wanted) {
        MIDIPortConnectSource(port, src, nil)
        print("monitoring: \(name(src))"); fflush(stdout)
        found = true
    }
}
if !found { print("no source matching '\(wanted)'"); exit(1) }
dispatchMain()
