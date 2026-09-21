import CJumpnbump
import Foundation

public enum PaletteError: Error {
    case decodeFailed
}

/// One 256-color VGA palette, display-scaled RGB triples (`jnb_pcx_palette_decode`'s
/// output) — fireworks mode's star/horizon colours all come from
/// `data/level.pcx`'s embedded palette (fireworks.c loads it purely for
/// this; see the module doc on `FireworksFrameRenderer`).
public struct Palette {
    private var rgb: [UInt8] // JNB_ASSET_PALETTE_SIZE bytes, 3 per index

    /// Direct construction from an already-decoded 768-byte palette — used
    /// by tests (`@testable import`) to avoid needing a real .pcx fixture
    /// for pure colour-math tests.
    init(rgbBytes: [UInt8]) {
        precondition(rgbBytes.count == Int(JNB_ASSET_PALETTE_SIZE))
        self.rgb = rgbBytes
    }

    public init(pcxData: Data) throws {
        var out = [UInt8](repeating: 0, count: Int(JNB_ASSET_PALETTE_SIZE))
        let result = pcxData.withUnsafeBytes { raw -> jnb_result in
            out.withUnsafeMutableBufferPointer { dst in
                jnb_pcx_palette_decode(
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    raw.count,
                    dst.baseAddress,
                    dst.count
                )
            }
        }
        guard result == JNB_OK else { throw PaletteError.decodeFailed }
        self.rgb = out
    }

    /// (r, g, b), each 0...255. `index` must be in 0..<256.
    public func color(at index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let base = index * 3
        return (rgb[base], rgb[base + 1], rgb[base + 2])
    }
}
