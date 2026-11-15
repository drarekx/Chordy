import Foundation

/// Rewrites a single-instrument SoundFont keeping every `n`-th velocity layer per key range
/// (from the loudest down) and widening the kept layers to cover the dropped ones.
///
/// Why: AUSampler loses the left channel of part of a very big bank. With the 1.27 GB Salamander
/// (16 layers), notes G#4–E6 came out of the right side only at every velocity; the same samples in
/// a smaller file play on both sides. 8 layers (≈ 640 MB) sound the same across the keyboard.
enum SF2Slimmer {
    struct Failure: Error { let reason: String }

    private struct Chunk { let id: String; let offset: UInt64; let size: UInt32 }

    static func reduceLayers(source: URL, destination: URL, every n: Int) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try input.seek(toOffset: offset)
            guard let data = try input.read(upToCount: count), data.count == count else { throw Failure(reason: "short read") }
            return data
        }
        func u32(_ d: Data, _ at: Int) -> UInt32 { d.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u16(_ d: Data, _ at: Int) -> UInt16 { d.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        func chunks(from start: UInt64, to end: UInt64) throws -> [Chunk] {
            var list: [Chunk] = []
            var offset = start
            while offset + 8 <= end {
                let header = try read(offset, 8)
                let id = String(decoding: header.prefix(4), as: UTF8.self)
                let size = u32(header, 4)
                list.append(Chunk(id: id, offset: offset + 8, size: size))
                offset += 8 + UInt64(size) + UInt64(size & 1)
            }
            return list
        }

        let riff = try read(0, 12)
        guard String(decoding: riff.prefix(4), as: UTF8.self) == "RIFF" else { throw Failure(reason: "not RIFF") }
        var lists: [String: (UInt64, UInt64)] = [:]
        for c in try chunks(from: 12, to: 12 + UInt64(u32(riff, 4))) where c.id == "LIST" {
            let kind = String(decoding: try read(c.offset, 4), as: UTF8.self)
            lists[kind] = (c.offset + 4, c.offset + UInt64(c.size))
        }
        guard let pdta = lists["pdta"], let sdta = lists["sdta"], let info = lists["INFO"] else { throw Failure(reason: "missing lists") }
        var sub: [String: Data] = [:]
        for c in try chunks(from: pdta.0, to: pdta.1) { sub[c.id] = try read(c.offset, Int(c.size)) }
        guard let smpl = try chunks(from: sdta.0, to: sdta.1).first(where: { $0.id == "smpl" }),
              let instData = sub["inst"], let ibagData = sub["ibag"], let igenData = sub["igen"], let shdrData = sub["shdr"],
              let phdr = sub["phdr"], let pbag = sub["pbag"], let pmod = sub["pmod"], let pgen = sub["pgen"], let imod = sub["imod"]
        else { throw Failure(reason: "missing chunks") }

        // Instrument zones (single instrument).
        guard instData.count / 22 == 2 else { throw Failure(reason: "more than one instrument") }
        let instName = instData.prefix(20)
        let zoneStart = Int(u16(instData, 20)), zoneEnd = Int(u16(instData, 42))
        typealias Gen = (op: UInt16, amount: UInt16)
        var zones: [[Gen]] = []
        for z in zoneStart..<zoneEnd {
            let g0 = Int(u16(ibagData, z * 4)), g1 = Int(u16(ibagData, (z + 1) * 4))
            zones.append((g0..<g1).map { (u16(igenData, $0 * 4), u16(igenData, $0 * 4 + 2)) })
        }
        func gen(_ zone: [Gen], _ op: UInt16) -> UInt16? { zone.first { $0.op == op }?.amount }
        let keyRange: UInt16 = 43, velRange: UInt16 = 44, sampleID: UInt16 = 53

        // Keep every n-th layer per key range, from the top; widen ranges downward.
        var kept: [[Gen]] = zones.filter { gen($0, sampleID) == nil }
        var byKeys: [UInt16: [[Gen]]] = [:]
        var order: [UInt16] = []
        for z in zones where gen(z, sampleID) != nil {
            let k = gen(z, keyRange) ?? 0x7F00
            if byKeys[k] == nil { order.append(k) }
            byKeys[k, default: []].append(z)
        }
        for k in order {
            let group = byKeys[k]!
            let layers = Array(Set(group.map { gen($0, velRange) ?? 0x7F00 })).sorted { ($0 & 0xFF) < ($1 & 0xFF) }
            let chosen = Array(Array(layers.reversed()).enumerated().filter { $0.offset % n == 0 }.map(\.element).reversed())
            var ranges: [UInt16: UInt16] = [:]
            var previous: UInt16 = 0
            for (i, v) in chosen.enumerated() {
                let hi = i == chosen.count - 1 ? 127 : v >> 8
                ranges[v] = hi << 8 | (previous + 1)
                previous = hi
            }
            for z in group {
                guard let v = gen(z, velRange) ?? Optional(0x7F00), let range = ranges[v] else { continue }
                kept.append(z.map { $0.op == velRange ? ($0.op, range) : $0 })
            }
        }

        // Samples used (stereo partners too), renumbered.
        let sampleCount = shdrData.count / 46
        func sh(_ i: Int) -> Data { shdrData.subdata(in: i * 46..<(i + 1) * 46) }
        var used = Set(kept.compactMap { gen($0, sampleID).map(Int.init) })
        for s in used {
            let h = sh(s)
            let type = u16(h, 44)
            if type == 2 || type == 4 { used.insert(Int(u16(h, 42))) }
        }
        let samples = used.filter { $0 < sampleCount - 1 }.sorted()
        let remap = Dictionary(uniqueKeysWithValues: samples.enumerated().map { ($0.element, $0.offset) })

        // New sample headers and sample data size.
        var newShdr = Data()
        var position: UInt32 = 0
        var copies: [(offset: UInt64, bytes: Int)] = []
        for s in samples {
            var h = sh(s)
            let start = u32(h, 20), end = u32(h, 24), loopStart = u32(h, 28), loopEnd = u32(h, 32)
            let length = end - start
            func put(_ value: UInt32, _ at: Int) { withUnsafeBytes(of: value.littleEndian) { h.replaceSubrange(at..<at + 4, with: $0) } }
            put(position, 20); put(position + length, 24)
            put(position + (loopStart &- start), 28); put(position + (loopEnd &- start), 32)
            let link = UInt16(remap[Int(u16(h, 42))] ?? 0)
            withUnsafeBytes(of: link.littleEndian) { h.replaceSubrange(42..<44, with: $0) }
            newShdr.append(h)
            copies.append((smpl.offset + UInt64(start) * 2, Int(length) * 2))
            position += length + 46
        }
        var eos = Data("EOS".utf8); eos.append(Data(count: 43)); newShdr.append(eos)

        // New instrument zones.
        var ibag = Data(), igen = Data()
        func append16(_ d: inout Data, _ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        var genIndex: UInt16 = 0
        for z in kept {
            append16(&ibag, genIndex); append16(&ibag, 0)
            for g in z {
                append16(&igen, g.op)
                append16(&igen, g.op == sampleID ? UInt16(remap[Int(g.amount)] ?? 0) : g.amount)
                genIndex += 1
            }
        }
        append16(&ibag, genIndex); append16(&ibag, 0)
        append16(&igen, 0); append16(&igen, 0)
        var inst = Data(instName); append16(&inst, 0)
        var eoi = Data("EOI".utf8); eoi.append(Data(count: 17)); inst.append(eoi); append16(&inst, UInt16(kept.count))

        func chunk(_ id: String, _ body: Data) -> Data {
            var d = Data(id.utf8)
            withUnsafeBytes(of: UInt32(body.count).littleEndian) { d.append(contentsOf: $0) }
            d.append(body)
            if body.count & 1 == 1 { d.append(0) }
            return d
        }
        var pdtaBody = Data("pdta".utf8)
        for (id, body) in [("phdr", phdr), ("pbag", pbag), ("pmod", pmod), ("pgen", pgen), ("inst", inst),
                           ("ibag", ibag), ("imod", imod), ("igen", igen), ("shdr", newShdr)] {
            pdtaBody.append(chunk(id, body))
        }
        let infoBody = try read(info.0 - 4, Int(info.1 - info.0 + 4))
        let smplBytes = UInt64(position) * 2
        let sdtaListSize = 4 + 8 + smplBytes
        let total = 4 + UInt64(chunk("LIST", infoBody).count) + 8 + sdtaListSize + UInt64(chunk("LIST", pdtaBody).count)
        guard total < UInt64(UInt32.max) else { throw Failure(reason: "too big") }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var head = Data("RIFF".utf8)
        withUnsafeBytes(of: UInt32(total).littleEndian) { head.append(contentsOf: $0) }
        head.append(Data("sfbk".utf8))
        head.append(chunk("LIST", infoBody))
        head.append(Data("LIST".utf8))
        withUnsafeBytes(of: UInt32(sdtaListSize).littleEndian) { head.append(contentsOf: $0) }
        head.append(Data("sdtasmpl".utf8))
        withUnsafeBytes(of: UInt32(smplBytes).littleEndian) { head.append(contentsOf: $0) }
        try output.write(contentsOf: head)
        let padding = Data(count: 92)
        for copy in copies {
            try output.write(contentsOf: try read(copy.offset, copy.bytes))
            try output.write(contentsOf: padding)
        }
        try output.write(contentsOf: chunk("LIST", pdtaBody))
    }
}
