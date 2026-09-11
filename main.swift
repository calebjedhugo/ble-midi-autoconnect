import Foundation
import CoreBluetooth
import CoreMIDI

// MIDI-over-BLE spec UUIDs
let midiServiceUUID = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
let midiCharUUID    = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")

let defaultsKey = "lastPeripheralUUID"
// Stable so DAWs remember the port across restarts.
let virtualUniqueID: Int32 = 0x4B52_4757

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(msg)")
    fflush(stdout)
}

// MARK: - Virtual CoreMIDI source

/// Publishes a virtual MIDI source. Stays alive across keyboard power cycles so
/// clients keep their port open instead of churning on every disconnect.
final class VirtualSource {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    let name: String

    init?(name: String) {
        self.name = name
        var status = MIDIClientCreate("BLEMIDIAutoConnect" as CFString, nil, nil, &client)
        guard status == noErr else {
            log("ERROR: MIDIClientCreate failed (\(status))")
            return nil
        }
        status = MIDISourceCreate(client, name as CFString, &source)
        guard status == noErr else {
            log("ERROR: MIDISourceCreate failed (\(status))")
            return nil
        }
        // Non-fatal: a collision just means the port gets a fresh id.
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, virtualUniqueID)
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyManufacturer, 0)
        log("virtual MIDI source published: '\(name)'")
    }

    func send(_ bytes: [UInt8], at timestamp: MIDITimeStamp) {
        guard !bytes.isEmpty, source != 0 else { return }
        let bufSize = 1024
        // Leave room for the packet list header; oversized SysEx is dropped
        // rather than silently truncated.
        guard bytes.count <= bufSize - 64 else {
            log("WARN: message too large (\(bytes.count) bytes), dropped")
            return
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var pkt = MIDIPacketListInit(list)
        pkt = MIDIPacketListAdd(list, bufSize, pkt, timestamp, bytes.count, bytes)
        let status = MIDIReceived(source, list)
        if status != noErr { log("WARN: MIDIReceived failed (\(status))") }
    }
}

// MARK: - BLE MIDI packet parser

// MARK: - Connector

final class Connector: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private let nameMatch: String
    private var target: CBPeripheral?
    private var parser = BLEMIDIParser()
    private var virtual: VirtualSource?
    private let portName: String

    init(nameMatch: String, portName: String) {
        self.nameMatch = nameMatch.lowercased()
        self.portName = portName
        super.init()
        virtual = VirtualSource(name: portName)
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func startScan() {
        guard central.state == .poweredOn, target == nil else { return }

        if let saved = UserDefaults.standard.string(forKey: defaultsKey),
           let uuid = UUID(uuidString: saved),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            log("known peripheral \(p.identifier); issuing pending connect")
            connect(p)
            return
        }
        if let p = central.retrieveConnectedPeripherals(withServices: [midiServiceUUID])
            .first(where: { nameMatch.isEmpty || ($0.name ?? "").lowercased().contains(nameMatch) }) {
            log("already connected to system: \(p.name ?? "unnamed"); adopting")
            connect(p)
            return
        }
        if central.isScanning { return }
        log("scanning for BLE MIDI peripherals matching '\(nameMatch)'")
        central.scanForPeripherals(withServices: [midiServiceUUID], options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        target = p
        p.delegate = self
        central.stopScan()
        // CoreBluetooth holds this pending indefinitely and fires when the
        // keyboard powers on.
        central.connect(p, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:  log("bluetooth powered on"); startScan()
        case .poweredOff: log("bluetooth powered off"); target = nil
        case .unauthorized:
            log("ERROR: bluetooth permission denied — System Settings > Privacy & Security > Bluetooth")
        case .unsupported: log("ERROR: BLE unsupported")
        default: log("bluetooth state: \(c.state.rawValue)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData adv: [String: Any], rssi RSSI: NSNumber) {
        let advName = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let name = p.name ?? advName
        guard nameMatch.isEmpty || name.lowercased().contains(nameMatch)
                || advName.lowercased().contains(nameMatch) else { return }
        log("discovered \(name) rssi=\(RSSI); connecting")
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("CONNECTED \(p.name ?? "unnamed") \(p.identifier)")
        UserDefaults.standard.set(p.identifier.uuidString, forKey: defaultsKey)
        parser.reset()
        p.discoverServices([midiServiceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "unknown"); retrying")
        target = nil
        startScan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("disconnected (\(error?.localizedDescription ?? "clean")); awaiting power-on")
        parser.reset()
        target = nil
        connect(p) // re-arm the pending connect
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { log("service discovery error: \(error.localizedDescription)"); return }
        for s in p.services ?? [] where s.uuid == midiServiceUUID {
            p.discoverCharacteristics([midiCharUUID], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let error = error { log("characteristic discovery error: \(error.localizedDescription)"); return }
        for ch in s.characteristics ?? [] where ch.uuid == midiCharUUID {
            log("subscribing to MIDI characteristic")
            p.setNotifyValue(true, for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error = error { log("subscribe failed: \(error.localizedDescription)"); return }
        log(ch.isNotifying ? "LIVE — MIDI flowing to '\(portName)'" : "notifications stopped")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let data = ch.value, !data.isEmpty else { return }
        // Deliver at receipt time; the device's own timestamps would need clock
        // reconciliation and clients timestamp on arrival anyway.
        let now = mach_absolute_time()
        for msg in parser.parse([UInt8](data)) {
            virtual?.send(msg, at: now)
        }
    }
}

// MARK: - Entry

let args = CommandLine.arguments
func argValue(_ flag: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
    return fallback
}
let nameMatch = argValue("--name", ProcessInfo.processInfo.environment["BLE_MIDI_NAME"] ?? "microKEY")
let portName  = argValue("--port-name", "microKEY2-25 Air (auto)")

log("ble-midi-autoconnect v2 starting (match: '\(nameMatch)', port: '\(portName)')")
let connector = Connector(nameMatch: nameMatch, portName: portName)
dispatchMain()
