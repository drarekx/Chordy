import Foundation
import Network
import QuartzCore
import UIKit

/// Finds Chordy on the local network (Bonjour), keeps one connection, receives the state
/// and the playhead, and sends commands. Reconnects on its own.
@MainActor
final class RemoteClient: ObservableObject {
    enum Status: Equatable {
        case searching
        case connecting(String)
        case connected(String)
    }

    @Published private(set) var status = Status.searching
    @Published private(set) var state: RemoteState?
    @Published private(set) var step: Int?
    @Published private(set) var playingPattern: Int?
    @Published private(set) var chainPosition: Int?
    @Published private(set) var flash: Set<Int> = []
    /// Chordy Macs found on the network.
    @Published private(set) var macs: [String] = []
    /// The Mac's count: beat in the bar (0…3) and bar, nil when stopped.
    @Published private(set) var beatInBar: Int?
    @Published private(set) var bar: Int?
    @Published private(set) var recording = false
    @Published private(set) var armed = false
    /// Round-trip time to the Mac in milliseconds (smoothed), nil until measured.
    @Published private(set) var latency: Double?
    /// Keys held on each Mac MIDI keyboard; its own object so only the keyboard drawings redraw.
    let live = LiveKeys()
    /// Song playhead; its own object so only the song card redraws 8 times a second.
    let song = SongClock()
    /// Chord being played in the open song; its own object so only the music stand redraws.
    let sheet = SheetFollow()

    private var browser: NWBrowser?
    private var results: [String: NWEndpoint] = [:]
    private var connection: NWConnection?
    private var buffer = LineBuffer()
    private let queue = DispatchQueue(label: "chordypads.net")
    private let encoder = JSONEncoder()
    private var preferred = UserDefaults.standard.string(forKey: "preferredMac")
    private var pingTimer: Timer?
    private var pingId = 0
    private var pingSent: [Int: CFTimeInterval] = [:]

    var connected: Bool { if case .connected = status { return true } else { return false } }

    func start() {
        guard browser == nil else { return }
        // Straight to the last Mac's address while Bonjour is still looking.
        if let host = UserDefaults.standard.string(forKey: "lastHost"),
           let port = NWEndpoint.Port(rawValue: UInt16(UserDefaults.standard.integer(forKey: "lastPort"))),
           let name = preferred {
            results[name] = .hostPort(host: NWEndpoint.Host(host), port: port)
            connect(to: name)
        }
        startPings()
        let browser = NWBrowser(for: .bonjour(type: RemoteProtocol.service, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [(String, NWEndpoint)] = results.compactMap { r in
                if case .service(let name, _, _, _) = r.endpoint { return (name, r.endpoint) }
                return nil
            }
            DispatchQueue.main.async { self?.found(found) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func found(_ list: [(String, NWEndpoint)]) {
        for (name, endpoint) in list { results[name] = endpoint }
        macs = results.keys.sorted()
        // The chosen Mac showed up after settling for another one: go to it.
        if let p = preferred, results[p] != nil, currentName != p {
            connect(to: p)
        } else if connection == nil, let name = macs.first {
            connect(to: name, remember: false)
        }
    }

    /// Mac connected or connecting to.
    private var currentName: String? {
        switch status {
        case .connecting(let n), .connected(let n): return n
        case .searching: return nil
        }
    }

    /// Connect to a Mac by its Bonjour name (remembered for next time, unless it's just the
    /// first one found while the chosen one isn't around).
    func connect(to name: String, remember: Bool = true) {
        guard let endpoint = results[name] else { return }
        connection?.cancel()
        if remember {
            preferred = name
            UserDefaults.standard.set(name, forKey: "preferredMac")
        }
        status = .connecting(name)
        buffer = LineBuffer()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVoice
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.status = .connected(name)
                    self.send(.hello(version: RemoteProtocol.version, device: UIDevice.current.name))
                    if name == self.preferred { self.remember(connection) }
                case .failed, .cancelled:
                    self.lost()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    /// Keep the resolved address for an instant reconnect next launch.
    private func remember(_ connection: NWConnection) {
        guard case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return }
        let address: String
        switch host {
        case .ipv4(let a): address = "\(a)"
        case .ipv6(let a): address = "\(a)"
        case .name(let n, _): address = n
        @unknown default: return
        }
        UserDefaults.standard.set(address.components(separatedBy: "%").first ?? address, forKey: "lastHost")
        UserDefaults.standard.set(Int(port.rawValue), forKey: "lastPort")
    }

    /// Ping ~10 times a second: shows the latency and keeps the wifi radio from napping.
    private func startPings() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.connected else { return }
                self.pingId += 1
                self.pingSent[self.pingId] = CACurrentMediaTime()
                if self.pingSent.count > 50 { self.pingSent = self.pingSent.filter { $0.key > self.pingId - 20 } }
                self.send(.ping(id: self.pingId))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func lost() {
        connection = nil
        state = nil
        latency = nil
        status = .searching
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.connection == nil else { return }
            if let p = self.preferred, self.results[p] != nil {
                self.connect(to: p)
            } else if let name = self.macs.first {
                self.connect(to: name, remember: false)
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            DispatchQueue.main.async {
                guard let self, connection === self.connection else { return }
                if let data, !data.isEmpty {
                    for line in self.buffer.append(data) {
                        if let message = try? JSONDecoder().decode(RemoteMessage.self, from: line) { self.handle(message) }
                    }
                }
                if done || error != nil { self.lost() } else { self.receive(connection) }
            }
        }
    }

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .state(let s):
            state = s
        case .tick(let s, let p, let c):
            step = s
            playingPattern = p
            chainPosition = c
        case .flash(let track):
            light(track)
        case .beat(let inBar, let bar, let recording, let armed):
            beatInBar = inBar
            self.bar = bar
            self.recording = recording
            self.armed = armed
        case .song(let playing, let beat, let bpm):
            song.playing = playing
            song.beat = beat
            song.bpm = bpm
        case .sheetPosition(let id, let index):
            sheet.id = id
            sheet.index = index
        case .notes(let device, let midi):
            live.notes[device] = Set(midi)
        case .pong(let id):
            guard let sent = pingSent.removeValue(forKey: id) else { return }
            let ms = (CACurrentMediaTime() - sent) * 1000
            latency = latency.map { $0 * 0.8 + ms * 0.2 } ?? ms
        }
    }

    private func light(_ track: Int) {
        flash.insert(track)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.flash.remove(track) }
    }

    func send(_ command: RemoteCommand) {
        guard let connection, let data = encoder.line(command) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Pads light at once on the iPad, without waiting for the Mac.
    func hit(track: Int, velocity: Int) {
        light(track)
        send(.hit(track: track, velocity: velocity))
    }
}

/// Keys held now on each MIDI device of the Mac.
@MainActor
final class LiveKeys: ObservableObject {
    @Published var notes: [String: Set<Int>] = [:]
}

/// Chord being played in the Mac's open song (−1: before the first).
@MainActor
final class SheetFollow: ObservableObject {
    @Published var id: String?
    @Published var index = -1
}

/// The Mac's song: playing or not and where (beats from the start).
@MainActor
final class SongClock: ObservableObject {
    @Published var playing = false
    @Published var beat = 0.0
    @Published var bpm = 120
}
