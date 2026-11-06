import Foundation
import Metal
import simd

/// Reader for the `.mesh` files written by tools/build_assets.py.
final class Mesh {
    struct Part {
        let name: String
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        let pivot: V3
    }
    let parts: [Part]

    init?(url: URL, device: MTLDevice) {
        guard let data = try? Data(contentsOf: url), data.count > 12, data.prefix(4) == Data("WKLM".utf8) else { return nil }
        var offset = 4
        func u32() -> UInt32 {
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return v
        }
        func f32() -> Float { Float(bitPattern: u32()) }
        guard u32() == 1 else { return nil }
        var out: [Part] = []
        for _ in 0..<u32() {
            let nameBytes = data[data.startIndex + offset ..< data.startIndex + offset + 16].prefix { $0 != 0 }
            offset += 16
            let vc = Int(u32()), ic = Int(u32())
            let pivot = V3(f32(), f32(), f32())
            let vb = vc * 28, ib = ic * 4
            guard offset + vb + ib <= data.count,
                  let vbuf = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress! + offset, length: vb, options: .storageModeShared) }),
                  let ibuf = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress! + offset + vb, length: ib, options: .storageModeShared) })
            else { return nil }
            offset += vb + ib
            out.append(Part(name: String(decoding: nameBytes, as: UTF8.self), vertices: vbuf, indices: ibuf, indexCount: ic, pivot: pivot))
        }
        parts = out
    }

    func part(_ name: String) -> Part? { parts.first { $0.name == name } }
}
