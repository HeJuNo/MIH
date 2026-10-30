import UIKit

/// Best-effort club-logo cleanup: many club crests ship as a small badge centered on a
/// plain white (or near-white) card. This flood-fills that card away starting from the
/// four edges — never from the inside, so a white number or stripe *inside* the crest
/// survives — then crops to the remaining opaque content, which also fixes crests that
/// are tiny specks on an oversized canvas. A logo that isn't on a plain light background
/// (photo, colored card, already-transparent PNG, …) is returned unchanged; `SettingsView`
/// lets the user pick a replacement for those.
enum LogoProcessing {
    static func cleaned(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage, let trimmed = removeBackground(cg) else { return image }
        return UIImage(cgImage: trimmed, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func removeBackground(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        guard w > 4, h > 4, w * h <= 4_000_000 else { return nil }   // skip absurd sources; not worth the pass

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                       space: colorSpace, bitmapInfo: bitmapInfo)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        func rgba(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let i = (y * w + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }

        // A near-white, opaque corner is the signature of "badge on a white card". If the
        // corners disagree, there's nothing confidently background-colored to strip.
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)].map(rgba)
        guard corners.allSatisfy(isWhitish) else { return nil }
        let seed = corners[0]

        var visited = [Bool](repeating: false, count: w * h)
        var stack: [(Int, Int)] = []
        func push(_ x: Int, _ y: Int) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            let idx = y * w + x
            if visited[idx] { return }
            visited[idx] = true
            guard closeTo(rgba(x, y), seed) else { return }
            stack.append((x, y))
        }
        for x in 0..<w { push(x, 0); push(x, h - 1) }
        for y in 0..<h { push(0, y); push(w - 1, y) }

        var cleared = 0
        while let (x, y) = stack.popLast() {
            pixels[(y * w + x) * 4 + 3] = 0
            cleared += 1
            push(x + 1, y); push(x - 1, y); push(x, y + 1); push(x, y - 1)
        }
        // Nothing enclosed to cut out (e.g. a plain white photo) — leave it alone rather
        // than guess.
        guard cleared > 0, cleared < w * h * 9 / 10 else { return nil }

        feather(&pixels, w: w, h: h, seed: seed)

        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                       space: colorSpace, bitmapInfo: bitmapInfo)
            else { return nil }
            return ctx.makeImage()
        }
        guard let image else { return nil }
        return crop(image, pixels: pixels, w: w, h: h)
    }

    private static func isWhitish(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        p.3 > 200 && p.0 > 230 && p.1 > 230 && p.2 > 230
    }

    private static func closeTo(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8), tolerance: Int = 18) -> Bool {
        a.3 > 200
            && abs(Int(a.0) - Int(b.0)) <= tolerance
            && abs(Int(a.1) - Int(b.1)) <= tolerance
            && abs(Int(a.2) - Int(b.2)) <= tolerance
    }

    /// One ring of pixels right around a cut gets its alpha scaled down if it's still
    /// background-ish, instead of leaving a hard white fringe from anti-aliasing.
    private static func feather(_ pixels: inout [UInt8], w: Int, h: Int, seed: (UInt8, UInt8, UInt8, UInt8)) {
        let snapshot = pixels
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard snapshot[i + 3] > 0 else { continue }
                let bare = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)].contains {
                    $0.0 >= 0 && $0.0 < w && $0.1 >= 0 && $0.1 < h && snapshot[($0.1 * w + $0.0) * 4 + 3] == 0
                }
                guard bare else { continue }
                let dist = abs(Int(snapshot[i]) - Int(seed.0)) + abs(Int(snapshot[i + 1]) - Int(seed.1)) + abs(Int(snapshot[i + 2]) - Int(seed.2))
                guard dist < 180 else { continue }
                pixels[i + 3] = UInt8(Int(snapshot[i + 3]) * dist / 180)
            }
        }
    }

    private static func crop(_ image: CGImage, pixels: [UInt8], w: Int, h: Int) -> CGImage {
        var minX = w, minY = h, maxX = 0, maxY = 0
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX < maxX, minY < maxY else { return image }
        let pad = max(2, Int(Double(max(maxX - minX, maxY - minY)) * 0.06))
        let rect = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 1 + pad * 2, height: maxY - minY + 1 + pad * 2)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return image.cropping(to: rect) ?? image
    }
}
