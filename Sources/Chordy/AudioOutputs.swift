import AVFoundation
import CoreAudio
import SwiftUI

/// The Mac's audio outputs and the one Chordy plays through: the system's (default) or a chosen
/// device, remembered by its UID. When the chosen one disappears Chordy follows the system
/// output, and goes back to it when it returns.
@MainActor
final class AudioOutputs: ObservableObject {
    static let shared = AudioOutputs()

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32

        var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
        var symbol: String {
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: return "speaker.wave.2"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeUSB: return "cable.connector"
            default: return "hifispeaker"
            }
        }
    }

    @Published private(set) var devices: [Device] = []
    /// UID of the chosen device; nil = follow the system output.
    @Published private(set) var selectedUID: String? = UserDefaults.standard.string(forKey: "audioOutput")
    /// The device sound goes to now.
    @Published private(set) var current: Device?
    @Published private(set) var systemDefault: Device?

    private var listening = false

    private init() {}

    /// Read the devices, listen for changes and route the engine (call once audio is running).
    func start() {
        refresh()
        guard !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { AudioOutputs.shared.refresh() }
            }
        }
    }

    /// nil = the system output.
    func select(_ uid: String?) {
        selectedUID = uid
        UserDefaults.standard.set(uid, forKey: "audioOutput")
        apply()
    }

    private func refresh() {
        devices = Self.outputDevices()
        let defaultId = Self.defaultOutputId()
        systemDefault = devices.first { $0.id == defaultId }
        apply()
    }

    private func apply() {
        let chosen = selectedUID.flatMap { uid in devices.first { $0.uid == uid } }
        let target = chosen ?? systemDefault
        current = target
        // nil = let the engine follow the system output by itself.
        Synth.shared.setOutputDevice(chosen?.id)
    }

    // MARK: Core Audio

    private static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            // Hide virtual helpers nobody picks by hand (Chordy's own MIDI-less aggregates, etc.).
            if name.hasPrefix("CADefaultDeviceAggregate") { return nil }
            return Device(id: id, uid: uid, name: name, transport: uint(id, kAudioDevicePropertyTransportType) ?? 0)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func defaultOutputId() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// Header menu: where Chordy's sound comes out.
struct AudioOutputMenu: View {
    @ObservedObject var outputs = AudioOutputs.shared

    var body: some View {
        Menu {
            Button { outputs.select(nil) } label: {
                item(tr("Sistema (%@)", outputs.systemDefault?.name ?? "—"), on: outputs.selectedUID == nil)
            }
            Divider()
            ForEach(outputs.devices) { d in
                Button { outputs.select(d.uid) } label: {
                    item(d.isBluetooth ? tr("%@ · Bluetooth, más retardo", d.name) : d.name, on: outputs.selectedUID == d.uid)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: outputs.current?.symbol ?? "speaker.wave.2").font(.system(size: 11))
                Text(outputs.current?.name ?? tr("Salida")).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(outputs.current?.isBluetooth == true ? Theme.warn : Theme.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 180)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line) }
        .help(tr("Salida de sonido de Chordy"))
    }

    @ViewBuilder
    private func item(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
