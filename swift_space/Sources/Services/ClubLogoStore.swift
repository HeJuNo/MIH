import UIKit

/// User-supplied replacement club logos, for crests the automatic white-background
/// removal in `LogoProcessing` can't clean up confidently. One PNG per club in
/// Application Support; takes priority over the club's remote logo when present.
final class ClubLogoStore: @unchecked Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyHockeyData/club-logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
    }

    private func url(for clubID: String) -> URL { directory.appendingPathComponent("\(clubID).png") }

    func load(_ clubID: String) -> UIImage? {
        (try? Data(contentsOf: url(for: clubID))).flatMap(UIImage.init(data:))
    }

    func save(_ image: UIImage, for clubID: String) {
        guard let data = image.pngData() else { return }
        try? data.write(to: url(for: clubID), options: .atomic)
    }

    func remove(_ clubID: String) {
        try? FileManager.default.removeItem(at: url(for: clubID))
    }
}
