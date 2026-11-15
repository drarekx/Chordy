import CoreMIDI
import Foundation

/// CoreMIDI plumbing: listens to every source, publishes a virtual "Chordy" source
/// (so DAWs can record what you play) and sends to devices (Launchkey LEDs).
/// Callbacks arrive on the main queue.
final class MidiIO: @unchecked Sendable {
    struct Message {
        let status: UInt8
        let data1: UInt8
        let data2: UInt8
        let device: String
    }

    var onMessage: ((Message) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var connected = Set<MIDIUniqueID>()
    private var names: [MIDIUniqueID: String] = [:]
    private(set) var ready = false

    func start() {
        guard !ready else { return }
        var status = MIDIClientCreateWithBlock(AppInfo.name as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.connectSources() }
        }
        guard status == noErr else { return NSLog("Chordy: MIDI client failed (\(status))") }

        status = MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &inputPort) { [weak self] list, refCon in
            self?.receive(list, from: refCon)
        }
        guard status == noErr else { return NSLog("Chordy: MIDI input port failed (\(status))") }
        MIDIOutputPortCreate(client, "Output" as CFString, &outputPort)
        MIDISourceCreateWithProtocol(client, AppInfo.name as CFString, ._1_0, &virtualSource)
        ready = true
        connectSources()
    }

    /// Display names of the connected inputs.
    var inputNames: [String] { connected.compactMap { names[$0] }.sorted() }

    /// Connects new sources (hot-plug) and forgets removed ones.
    private func connectSources() {
        var present = Set<MIDIUniqueID>()
        let ownId = Self.uniqueId(virtualSource)
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            let id = Self.uniqueId(source)
            guard id != 0, id != ownId else { continue }
            present.insert(id)
            names[id] = Self.name(source)
            if !connected.contains(id) {
                // The unique id rides along as refCon to know which device sent each message.
                MIDIPortConnectSource(inputPort, source, UnsafeMutableRawPointer(bitPattern: Int(id)))
                connected.insert(id)
            }
        }
        connected.formIntersection(present)
        onDevicesChanged?()
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, from refCon: UnsafeMutableRawPointer?) {
        let id = MIDIUniqueID(truncatingIfNeeded: Int(bitPattern: refCon))
        var messages: [(UInt8, UInt8, UInt8)] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for w in 0..<min(count, words.count) {
                    let word = words[w]
                    // Universal MIDI Packet type 2 = MIDI 1.0 channel voice message.
                    guard word >> 28 == 0x2 else { continue }
                    messages.append((UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)))
                }
            }
        }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let device = self.names[id] ?? "MIDI"
            for (status, d1, d2) in messages {
                self.onMessage?(Message(status: status, data1: d1, data2: d2, device: device))
            }
        }
    }

    // MARK: - Output

    /// Sends to the virtual "Chordy" source (DAWs listening to it receive it).
    func sendVirtual(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        guard ready else { return }
        withEventList(status, data1, data2) { MIDIReceivedEventList(virtualSource, $0) }
    }

    /// Sends to every destination whose name matches (e.g. the Launchkey InControl port).
    func send(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, to destination: MIDIEndpointRef) {
        guard ready else { return }
        withEventList(status, data1, data2) { MIDISendEventList(outputPort, destination, $0) }
    }

    /// Destinations with their names, for picking a device to light up.
    func destinations() -> [(MIDIEndpointRef, String)] {
        (0..<MIDIGetNumberOfDestinations()).map { i in
            let endpoint = MIDIGetDestination(i)
            return (endpoint, Self.name(endpoint))
        }
    }

    private func withEventList(_ status: UInt8, _ data1: UInt8, _ data2: UInt8,
                               _ body: (UnsafePointer<MIDIEventList>) -> Void) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = UInt32(0x2000_0000) | UInt32(status) << 16 | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F)
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        body(&list)
    }

    // MARK: - Properties

    private static func uniqueId(_ object: MIDIObjectRef) -> MIDIUniqueID {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &id)
        return id
    }

    private static func name(_ object: MIDIObjectRef) -> String {
        var value: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value) == noErr, let value {
            return value.takeRetainedValue() as String
        }
        return "MIDI"
    }
}
