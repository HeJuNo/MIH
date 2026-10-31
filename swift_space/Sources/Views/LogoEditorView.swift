import SwiftUI

/// Full logo editor, reached from `ClubSettingsView` either on a freshly picked photo or
/// to touch up the club's current logo: pinch-zoom, pan and free rotation to frame it, plus
/// automatic background removal with an adjustable sensitivity and a manual erase/restore
/// brush for whatever the flood fill can't resolve on its own.
struct LogoEditorView: View {
    let clubName: String
    let onSave: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var original: LogoPixelBuffer
    @State private var working: LogoPixelBuffer
    @State private var previewImage: UIImage?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var lastRotation: Angle = .zero
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    @State private var mode: Mode = .transform
    @State private var retouchTool: RetouchTool = .erase
    @State private var brushRadius: Double = 28
    @State private var tolerance: Double = 18

    private let canvasSide: CGFloat = 280
    private let outputSide: CGFloat = 1024

    enum Mode: CaseIterable, Identifiable {
        case transform, retouch
        var id: Self { self }
        var label: String { self == .transform ? "Anpassen" : "Freistellen" }
    }
    enum RetouchTool { case erase, restore }

    init(image: UIImage, clubName: String, initialMode: Mode = .transform, onSave: @escaping (UIImage) -> Void) {
        self.clubName = clubName
        self.onSave = onSave
        let cg = image.cgImage ?? UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }.cgImage
        let buffer = cg.flatMap { LogoPixelBuffer(cgImage: $0, maxDimension: LogoProcessing.editingMaxDimension) } ?? .empty
        _original = State(initialValue: buffer)
        _working = State(initialValue: buffer)
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvas
                    .frame(width: canvasSide, height: canvasSide)
                    .padding(.top, 20)
                Text(clubName).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                Spacer(minLength: 0)
                controls
            }
            .navigationTitle("Logo bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { save() }
                }
            }
            .task {
                working.removeBackground(tolerance: Int(tolerance))
                refreshPreview()
            }
        }
    }

    private var canvas: some View {
        ZStack {
            checkerboard
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .frame(width: CGFloat(working.width) * baseFitScale, height: CGFloat(working.height) * baseFitScale)
                    .scaleEffect(scale)
                    .rotationEffect(rotation)
                    .offset(offset)
            }
        }
        .frame(width: canvasSide, height: canvasSide)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.separator))
        .contentShape(Rectangle())
        .simultaneousGesture(dragGesture)
        .simultaneousGesture(magnificationGesture)
        .simultaneousGesture(rotationGesture)
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            let cols = Int(ceil(size.width / tile)), rows = Int(ceil(size.height / tile))
            for row in 0..<rows {
                for col in 0..<cols where (row + col) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    context.fill(Path(rect), with: .color(.secondary.opacity(0.15)))
                }
            }
        }
        .background(Color(uiColor: .systemGray6))
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch mode {
            case .transform: transformControls
            case .retouch: retouchControls
            }

            Button(role: .destructive) { resetAll() } label: {
                Label("Alles zurücksetzen", systemImage: "arrow.counterclockwise")
            }
            .font(.footnote)
        }
        .padding(.vertical, 12)
    }

    private var transformControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 28) {
                Button { rotateBy(-90) } label: { Image(systemName: "rotate.left") }
                Button { rotateBy(90) } label: { Image(systemName: "rotate.right") }
            }
            .buttonStyle(.bordered)
            .imageScale(.large)
            Text("Ziehen zum Verschieben · zwei Finger zum Zoomen und frei Drehen")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    private var retouchControls: some View {
        VStack(spacing: 12) {
            Button {
                working.removeBackground(tolerance: Int(tolerance))
                refreshPreview()
            } label: {
                Label("Hintergrund automatisch entfernen", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)

            LabeledContent("Empfindlichkeit") {
                Slider(value: $tolerance, in: 4...60)
            }

            Picker("", selection: $retouchTool) {
                Text("Radieren").tag(RetouchTool.erase)
                Text("Wiederherstellen").tag(RetouchTool.restore)
            }
            .pickerStyle(.segmented)

            LabeledContent("Pinselgröße") {
                Slider(value: $brushRadius, in: 8...60)
            }

            Text("Mit dem Finger über das Bild streichen, um Hintergrundreste zu entfernen oder fälschlich entfernte Stellen wiederherzustellen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch mode {
                case .transform:
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                     height: lastOffset.height + value.translation.height)
                case .retouch:
                    paint(at: value.location)
                }
            }
            .onEnded { _ in
                if mode == .transform { lastOffset = offset }
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in if mode == .transform { scale = lastScale * value } }
            .onEnded { _ in lastScale = scale }
    }

    private var rotationGesture: some Gesture {
        RotationGesture()
            .onChanged { value in if mode == .transform { rotation = lastRotation + value } }
            .onEnded { _ in lastRotation = rotation }
    }

    private func rotateBy(_ degrees: Double) {
        withAnimation(.snappy) {
            rotation += .degrees(degrees)
            lastRotation = rotation
        }
    }

    // MARK: - Pixel editing

    private var baseFitScale: CGFloat {
        canvasSide / CGFloat(max(working.width, working.height, 1))
    }

    /// Maps a touch point in the canvas's own coordinate space back through the current
    /// pan/zoom/rotation to the matching pixel in `working`, then erases or restores a
    /// soft-edged disc there.
    private func paint(at location: CGPoint) {
        let center = CGPoint(x: canvasSide / 2, y: canvasSide / 2)
        let rel = CGPoint(x: location.x - center.x - offset.width, y: location.y - center.y - offset.height)
        let theta = -rotation.radians
        let rotated = CGPoint(x: rel.x * cos(theta) - rel.y * sin(theta),
                               y: rel.x * sin(theta) + rel.y * cos(theta))
        let totalScale = baseFitScale * scale
        guard totalScale > 0 else { return }
        let px = Int(CGFloat(working.width) / 2 + rotated.x / totalScale)
        let py = Int(CGFloat(working.height) / 2 + rotated.y / totalScale)
        let radiusPx = max(1, Int(brushRadius / totalScale))
        switch retouchTool {
        case .erase: working.erase(at: (px, py), radius: radiusPx)
        case .restore: working.restore(at: (px, py), radius: radiusPx, from: original)
        }
        refreshPreview()
    }

    private func refreshPreview() {
        previewImage = working.cgImage().map { UIImage(cgImage: $0) }
    }

    private func resetAll() {
        working = original
        scale = 1; lastScale = 1
        rotation = .zero; lastRotation = .zero
        offset = .zero; lastOffset = .zero
        refreshPreview()
    }

    // MARK: - Export

    private func save() {
        onSave(render())
        dismiss()
    }

    /// Composites the current pan/zoom/rotation of `working` onto a fixed-size transparent
    /// canvas at a resolution well above the on-screen preview, then trims to content —
    /// the final file shouldn't be limited by how big the editor's canvas looked on screen.
    private func render() -> UIImage {
        guard let workingImage = working.cgImage() else { return previewImage ?? UIImage() }
        let renderScale = outputSide / canvasSide
        let totalScale = baseFitScale * scale * renderScale
        let effectiveOffset = CGSize(width: offset.width * renderScale, height: offset.height * renderScale)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide))
        let composited = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: outputSide / 2 + effectiveOffset.width, y: outputSide / 2 + effectiveOffset.height)
            cg.rotate(by: CGFloat(rotation.radians))
            cg.scaleBy(x: totalScale, y: totalScale)
            let w = CGFloat(working.width), h = CGFloat(working.height)
            cg.draw(workingImage, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
        guard let finalCG = composited.cgImage, let buffer = LogoPixelBuffer(cgImage: finalCG) else { return composited }
        return buffer.croppedToContent(padding: 0.04).cgImage().map(UIImage.init(cgImage:)) ?? composited
    }
}
