// Which graphics runtimes a Windows PE image links (a port of notproton/helpers/pe-d3d.c)
//
// Only the import and delay-import directories are read, never the strings, so an engine that
// merely carries the name of an optional renderer does not count.

import Foundation

public enum GraphicsRuntime: String, CaseIterable, Sendable {
    case d3d12, d3d11, dxgi, d3d10, d3d9, d3d8, ddraw, opengl, vulkan

    static func from(dllName raw: String) -> GraphicsRuntime? {
        var name = raw.lowercased()
        guard let dot = name.range(of: ".dll") else { return nil }
        name = String(name[..<dot.lowerBound])
        // d3d10_1 and d3d10core count as d3d10
        if name.hasPrefix("d3d10") { return .d3d10 }
        switch name {
        case "opengl32": return .opengl
        case "vulkan-1": return .vulkan
        default: return GraphicsRuntime(rawValue: name)
        }
    }
}

public enum ImportKind: Character, Sendable {
    case direct = "i"   // normal import: needed at load time
    case delayed = "d"  // delay-load import: loaded when first used
}

public struct PEImports: Equatable, Sendable {
    /// Each runtime found, with `.direct` winning over `.delayed`.
    public var runtimes: [GraphicsRuntime: ImportKind] = [:]
    public var isPE = false

    /// pe-d3d's output format, e.g. "d3d11:i,dxgi:i", or "-" when nothing is linked.
    public var flags: String {
        let parts = GraphicsRuntime.allCases.compactMap { r in runtimes[r].map { "\(r.rawValue):\($0.rawValue)" } }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    public init() {}

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.init(data: data)
    }

    public init(data: Data) {
        let pe = Reader(data: data)
        guard data.count >= 0x200 else { return }
        let lfanew = Int(pe.u32(0x3c))
        guard pe.u16(0) == 0x5a4d, pe.u32(lfanew) == 0x0000_4550 else { return }
        isPE = true

        let coff = lfanew + 4
        let sectionCount = min(Int(pe.u16(coff + 2)), 96)
        let opt = coff + 20
        let optSize = Int(pe.u16(coff + 16))
        let magic = pe.u16(opt)
        let dirs = opt + (magic == 0x20b ? 112 : 96)
        let sectionTable = opt + optSize
        let sections = (0..<sectionCount).map { i -> Section in
            let s = sectionTable + i * 40
            return Section(va: pe.u32(s + 12), raw: pe.u32(s + 20), vsize: pe.u32(s + 8), rsize: pe.u32(s + 16))
        }
        func offset(_ rva: UInt32) -> Int? {
            for s in sections {
                let span = max(s.vsize, s.rsize)
                if rva >= s.va, UInt64(rva) < UInt64(s.va) + UInt64(span) {
                    let off = Int(s.raw) + Int(rva - s.va)
                    return off < data.count ? off : nil
                }
            }
            return nil
        }
        func note(_ nameRVA: UInt32, _ kind: ImportKind) {
            guard let off = offset(nameRVA), let runtime = GraphicsRuntime.from(dllName: pe.cString(off, max: 63)) else { return }
            if runtimes[runtime] == nil || kind == .direct { runtimes[runtime] = kind }
        }

        // IMAGE_DIRECTORY_ENTRY_IMPORT: 20-byte descriptors, name RVA at +12
        if case let imp = pe.u32(dirs + 8), imp != 0, var off = offset(imp) {
            for _ in 0..<4096 {
                let name = pe.u32(off + 12)
                if name == 0 && pe.u32(off) == 0 { break }
                note(name, .direct)
                off += 20
            }
        }
        // IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT: 32-byte descriptors, name at +4
        if case let dly = pe.u32(dirs + 13 * 8), dly != 0, var off = offset(dly) {
            for _ in 0..<4096 {
                let attrs = pe.u32(off)
                var name = pe.u32(off + 4)
                if name == 0 { break }
                // pre-VC7 delay descriptors hold VAs instead of RVAs
                if attrs & 1 == 0 {
                    let base: UInt64 = magic == 0x20b
                        ? UInt64(pe.u32(opt + 24)) | UInt64(pe.u32(opt + 28)) << 32
                        : UInt64(pe.u32(opt + 28))
                    name = UInt32(truncatingIfNeeded: UInt64(name) &- base)
                }
                note(name, .delayed)
                off += 32
            }
        }
    }

    private struct Section { var va, raw, vsize, rsize: UInt32 }

    private struct Reader {
        let data: Data
        func u8(_ off: Int) -> UInt8 {
            off >= 0 && off < data.count ? data[data.startIndex + off] : 0
        }
        func u16(_ off: Int) -> UInt16 {
            off >= 0 && off + 2 <= data.count ? UInt16(u8(off)) | UInt16(u8(off + 1)) << 8 : 0
        }
        func u32(_ off: Int) -> UInt32 {
            off >= 0 && off + 4 <= data.count ? UInt32(u16(off)) | UInt32(u16(off + 2)) << 16 : 0
        }
        func cString(_ off: Int, max: Int) -> String {
            var bytes: [UInt8] = []
            var i = off
            while bytes.count < max, i < data.count, case let b = u8(i), b != 0 { bytes.append(b); i += 1 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
