import UIKit

/// Best-effort club-logo cleanup: many club crests ship as a small badge centered on a
/// plain white (or near-white) card. `LogoPixelBuffer.removeBackground` flood-fills that
/// card away starting from the four edges — never from the inside, so a white number or
/// stripe *inside* the crest survives — then this crops to the remaining opaque content,
/// which also fixes crests that are tiny specks on an oversized canvas. A logo that isn't
/// on a plain light background (photo, colored card, already-transparent PNG, …) is
/// returned unchanged; `LogoEditorView` lets the user fix those up by hand.
enum LogoProcessing {
    static let defaultTolerance = 18
    static let editingMaxDimension = 900

    static func cleaned(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage,
              var buffer = LogoPixelBuffer(cgImage: cg, maxDimension: 1600),
              buffer.width > 4, buffer.height > 4, buffer.width * buffer.height <= 4_000_000
        else { return image }
        guard buffer.removeBackground(tolerance: defaultTolerance) else { return image }
        guard let cropped = buffer.croppedToContent().cgImage() else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
