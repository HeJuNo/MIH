import UIKit

/// RGBA8 pixel buffer that the logo background-removal flood fill and the interactive
/// editor's erase/restore brush operate on directly. `LogoProcessing.cleaned(_:)` and
/// `LogoEditorView` share this instead of each doing their own `CGContext` plumbing.
struct LogoPixelBuffer {
    let width: Int
    let height: Int
    var pixels: [UInt8]   // width * height * 4, premultiplied-last RGBA, row-major top-to-bottom

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    static var empty: LogoPixelBuffer { LogoPixelBuffer(width: 1, height: 1, pixels: [0, 0, 0, 0]) }

    /// Renders `cg` into a fresh buffer, downscaling first if it's larger than `maxDimension`
    /// on its long side — logos never need to be edited at full camera resolution, and
    /// capping this keeps the editor's live brush/gesture updates smooth.
    init?(cgImage cg: CGImage, maxDimension: Int = .max) {
        var w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        if max(w, h) > maxDimension {
            let scale = Double(maxDimension) / Double(max(w, h))
            w = max(1, Int(Double(w) * scale))
            h = max(1, Int(Double(h) * scale))
        }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                       space: Self.colorSpace, bitmapInfo: Self.bitmapInfo)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        width = w
        height = h
        pixels = buffer
    }

    func cgImage() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                       space: Self.colorSpace, bitmapInfo: Self.bitmapInfo)
            else { return nil }
            return ctx.makeImage()
        }
    }

    private func rgba(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    /// Flood-fills a near-uniform background in from the four edges — never from the
    /// inside, so enclosed light pixels (a white number, a stripe) survive — then feathers
    /// the cut boundary so there's no hard white fringe from anti-aliasing. Returns whether
    /// anything was confidently identified as background; a caller can leave the image
    /// untouched when it returns `false` (no light, agreeing corners, or nothing enclosed).
    @discardableResult
    mutating func removeBackground(tolerance: Int) -> Bool {
        func isWhitish(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
            p.3 > 200 && p.0 > 230 && p.1 > 230 && p.2 > 230
        }
        func closeTo(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
            a.3 > 200
                && abs(Int(a.0) - Int(b.0)) <= tolerance
                && abs(Int(a.1) - Int(b.1)) <= tolerance
                && abs(Int(a.2) - Int(b.2)) <= tolerance
        }

        let corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)].map(rgba)
        guard corners.allSatisfy(isWhitish) else { return false }
        let seed = corners[0]

        var visited = [Bool](repeating: false, count: width * height)
        var stack: [(Int, Int)] = []
        func push(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let idx = y * width + x
            if visited[idx] { return }
            visited[idx] = true
            guard closeTo(rgba(x, y), seed) else { return }
            stack.append((x, y))
        }
        for x in 0..<width { push(x, 0); push(x, height - 1) }
        for y in 0..<height { push(0, y); push(width - 1, y) }

        var toClear: [(Int, Int)] = []
        while let (x, y) = stack.popLast() {
            toClear.append((x, y))
            push(x + 1, y); push(x - 1, y); push(x, y + 1); push(x, y - 1)
        }
        guard toClear.count > 0, toClear.count < width * height * 9 / 10 else { return false }
        // RGBA8 here is premultiplied-last: a transparent pixel must also have RGB at 0, or
        // the invalid (RGB > A) data renders as opaque on some compositing paths instead of
        // see-through. Clearing (and the proportional scaling below in feather/erase) always
        // zeroes or scales all four channels together to keep that invariant.
        for (x, y) in toClear {
            let i = (y * width + x) * 4
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
        }
        feather(seed: seed)
        return true
    }

    private mutating func feather(seed: (UInt8, UInt8, UInt8, UInt8)) {
        let snapshot = pixels
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard snapshot[i + 3] > 0 else { continue }
                let bare = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)].contains {
                    $0.0 >= 0 && $0.0 < width && $0.1 >= 0 && $0.1 < height && snapshot[($0.1 * width + $0.0) * 4 + 3] == 0
                }
                guard bare else { continue }
                let dist = abs(Int(snapshot[i]) - Int(seed.0)) + abs(Int(snapshot[i + 1]) - Int(seed.1)) + abs(Int(snapshot[i + 2]) - Int(seed.2))
                guard dist < 180 else { continue }
                let factor = Double(dist) / 180
                pixels[i] = UInt8(Double(snapshot[i]) * factor)
                pixels[i + 1] = UInt8(Double(snapshot[i + 1]) * factor)
                pixels[i + 2] = UInt8(Double(snapshot[i + 2]) * factor)
                pixels[i + 3] = UInt8(Double(snapshot[i + 3]) * factor)
            }
        }
    }

    /// Erases a soft-edged disc (full effect out to 60% of `radius`, feathered to 0 at the
    /// edge) around `center`, for background the automatic flood fill missed.
    mutating func erase(at center: (x: Int, y: Int), radius: Int) {
        for (x, y, falloff) in paintPoints(at: center, radius: radius) {
            let i = (y * width + x) * 4
            let factor = 1 - falloff
            pixels[i] = UInt8(Double(pixels[i]) * factor)
            pixels[i + 1] = UInt8(Double(pixels[i + 1]) * factor)
            pixels[i + 2] = UInt8(Double(pixels[i + 2]) * factor)
            pixels[i + 3] = UInt8(Double(pixels[i + 3]) * factor)
        }
    }

    /// The inverse of `erase`: blends pixels back toward `original`'s values, for content the
    /// flood fill wrongly took, or to walk back an over-eager erase stroke.
    mutating func restore(at center: (x: Int, y: Int), radius: Int, from original: LogoPixelBuffer) {
        guard original.width == width, original.height == height else { return }
        for (x, y, falloff) in paintPoints(at: center, radius: radius) {
            let i = (y * width + x) * 4
            let o = original.rgba(x, y)
            pixels[i] = blend(pixels[i], o.0, falloff)
            pixels[i + 1] = blend(pixels[i + 1], o.1, falloff)
            pixels[i + 2] = blend(pixels[i + 2], o.2, falloff)
            pixels[i + 3] = blend(pixels[i + 3], o.3, falloff)
        }
    }

    private func blend(_ a: UInt8, _ b: UInt8, _ t: Double) -> UInt8 {
        UInt8((Double(a) * (1 - t) + Double(b) * t).rounded())
    }

    private func paintPoints(at center: (x: Int, y: Int), radius: Int) -> [(x: Int, y: Int, falloff: Double)] {
        let r = max(1, radius)
        let minY = max(0, center.y - r), maxY = min(height - 1, center.y + r)
        let minX = max(0, center.x - r), maxX = min(width - 1, center.x + r)
        guard minY <= maxY, minX <= maxX else { return [] }
        let r2 = Double(r * r)
        var points: [(x: Int, y: Int, falloff: Double)] = []
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x - center.x), dy = Double(y - center.y)
                let d2 = dx * dx + dy * dy
                guard d2 <= r2 else { continue }
                let falloff = 1 - smoothstep(Double(r) * 0.6, Double(r), d2.squareRoot())
                points.append((x, y, falloff))
            }
        }
        return points
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Crops to the bounding box of non-transparent content, with a small margin. Returns
    /// `self` unchanged if nothing is opaque.
    func croppedToContent(padding: Double = 0.06) -> LogoPixelBuffer {
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX < maxX, minY < maxY else { return self }
        let pad = max(2, Int(Double(max(maxX - minX, maxY - minY)) * padding))
        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let x1 = min(width - 1, maxX + pad), y1 = min(height - 1, maxY + pad)
        let newW = x1 - x0 + 1, newH = y1 - y0 + 1
        var newPixels = [UInt8](repeating: 0, count: newW * newH * 4)
        for y in 0..<newH {
            let srcStart = ((y0 + y) * width + x0) * 4
            let dstStart = y * newW * 4
            newPixels.replaceSubrange(dstStart..<(dstStart + newW * 4), with: pixels[srcStart..<(srcStart + newW * 4)])
        }
        return LogoPixelBuffer(width: newW, height: newH, pixels: newPixels)
    }
}
