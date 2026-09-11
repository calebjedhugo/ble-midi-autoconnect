import Foundation

/// Decodes the BLE-MIDI framing: a header byte, then timestamp bytes
/// interleaved with MIDI messages, with running status and split SysEx.
struct BLEMIDIParser {
    private var runningStatus: UInt8 = 0
    private var inSysEx = false
    private var sysExBuffer: [UInt8] = []

    private static func dataByteCount(for status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 2
        case 0xC0, 0xD0: return 1
        case 0xF0:
            switch status {
            case 0xF1, 0xF3: return 1
            case 0xF2: return 2
            default: return 0
            }
        default: return 0
        }
    }

    /// Returns complete MIDI messages in arrival order.
    mutating func parse(_ data: [UInt8]) -> [[UInt8]] {
        guard data.count >= 2 else { return [] }
        var out: [[UInt8]] = []
        var i = 1 // skip the header byte

        while i < data.count {
            let byte = data[i]

            if inSysEx {
                if byte == 0xF7 {
                    sysExBuffer.append(byte)
                    out.append(sysExBuffer)
                    sysExBuffer.removeAll()
                    inSysEx = false
                    i += 1
                } else if byte & 0x80 != 0 {
                    i += 1 // timestamp byte embedded in a split SysEx — skip
                } else {
                    sysExBuffer.append(byte)
                    i += 1
                }
                continue
            }

            var status: UInt8
            if byte & 0x80 != 0 {
                // Timestamp byte; a status byte may follow, else running status.
                i += 1
                guard i < data.count else { break }
                if data[i] & 0x80 != 0 {
                    status = data[i]
                    i += 1
                } else {
                    guard runningStatus != 0 else { continue }
                    status = runningStatus
                }
            } else {
                guard runningStatus != 0 else { i += 1; continue }
                status = runningStatus
            }

            // Realtime messages are standalone and never disturb running status.
            if status >= 0xF8 {
                out.append([status])
                continue
            }

            if status == 0xF0 {
                inSysEx = true
                sysExBuffer = [status]
                runningStatus = 0
                continue
            }

            // System common (0xF1-0xF7) clears running status; channel messages set it.
            runningStatus = (status & 0xF0) == 0xF0 ? 0 : status

            let need = Self.dataByteCount(for: status)
            var msg: [UInt8] = [status]
            var consumed = 0
            while consumed < need && i < data.count && data[i] & 0x80 == 0 {
                msg.append(data[i])
                i += 1
                consumed += 1
            }
            guard consumed == need else { break } // truncated; wait for more
            out.append(msg)
        }
        return out
    }

    mutating func reset() {
        runningStatus = 0
        inSysEx = false
        sysExBuffer.removeAll()
    }
}
