import Foundation
import CoreGraphics
import UIKit

// `PreparedPhoto` lives in PreparedPhoto.swift (it has no UIKit dependency).

/// A plain, thread-safe snapshot of a selected `ReferencePhoto`.
///
/// Taken on the main actor so the analysis stages never touch the UI-layer
/// model. The stable `id` is the `ReferencePhoto.id`, which is what keeps the
/// image, evidence and profile contribution associated.
nonisolated struct PhotoSource: @unchecked Sendable {
    let id: UUID
    let selectionOrder: Int
    let localIdentifier: String
    let image: UIImage?
    /// 35 mm-equivalent focal length from the photo's EXIF, when known.
    let focalLength35mm: Double?

    @MainActor
    init(_ reference: ReferencePhoto) {
        self.id = reference.id
        self.selectionOrder = reference.selectionOrder
        self.localIdentifier = reference.localIdentifier
        self.image = reference.image
        self.focalLength35mm = reference.focalLength35mm
    }

    init(id: UUID, selectionOrder: Int, localIdentifier: String = "", image: UIImage?,
         focalLength35mm: Double? = nil) {
        self.id = id
        self.selectionOrder = selectionOrder
        self.localIdentifier = localIdentifier
        self.image = image
        self.focalLength35mm = focalLength35mm
    }
}

/// Stage A: Input Preparation.
///
/// Renders ONE upright copy of each photo, long edge limited to `longEdge`.
/// That single image serves Vision, the Core ML models and the on-screen
/// display, so all of them share one coordinate space and no full-resolution
/// copy is kept per result. Aspect ratio is never changed and nothing is
/// cropped.
nonisolated enum PhotoPreparer {

    static let defaultLongEdge = 1280

    static func prepare(_ source: PhotoSource, longEdge: Int = defaultLongEdge) -> PreparedPhoto {
        func unreadable(_ reason: String) -> PreparedPhoto {
            PreparedPhoto(id: source.id, selectionOrder: source.selectionOrder,
                          localIdentifier: source.localIdentifier, outcome: .unreadable(reason))
        }

        guard let ui = source.image else { return unreadable("The photo could not be loaded from the library.") }
        guard let cg = ui.cgImage, cg.width > 0, cg.height > 0 else {
            return unreadable("The photo has no readable pixel data.")
        }

        let orientation = ui.imageOrientation
        let swapsAxes: Bool
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let uprightW = swapsAxes ? cg.height : cg.width
        let uprightH = swapsAxes ? cg.width : cg.height

        let scale = min(1.0, Double(longEdge) / Double(max(uprightW, uprightH)))
        let width = max(1, Int((Double(uprightW) * scale).rounded()))
        let height = max(1, Int((Double(uprightH) * scale).rounded()))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)

        // Drawing a UIImage applies its orientation, so the result is upright.
        let rendered = renderer.image { _ in
            UIImage(cgImage: cg, scale: 1, orientation: orientation)
                .draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let output = rendered.cgImage else { return unreadable("The photo could not be resized for analysis.") }

        var record = ImagePreparationRecord(
            originalPixelWidth: cg.width, originalPixelHeight: cg.height,
            orientationRaw: orientation.rawValue,
            uprightWidth: uprightW, uprightHeight: uprightH,
            preparedWidth: output.width, preparedHeight: output.height,
            longEdgeLimit: longEdge)
        record.focalLength35mm = source.focalLength35mm
        return PreparedPhoto(id: source.id, selectionOrder: source.selectionOrder,
                             localIdentifier: source.localIdentifier,
                             outcome: .ready(image: output, record: record))
    }
}

// MARK: - Caches

/// Upright display images by photo ID. Filled once during preparation, so
/// opening a result never re-decodes or re-analyses anything.
nonisolated final class PhotoImageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [UUID: UIImage] = [:]

    func set(_ image: UIImage, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        images[id] = image
    }

    func image(for id: UUID) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return images[id]
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        images.removeAll()
    }
}

/// Heavy model outputs (segmentation and depth grids) by photo ID, kept only
/// for overlays and reproducibility.
nonisolated final class AnalysisArtifactStore: @unchecked Sendable {
    private let lock = NSLock()
    private var artifacts: [UUID: PhotoArtifacts] = [:]

    func set(_ value: PhotoArtifacts, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        artifacts[id] = value
    }

    func artifacts(for id: UUID) -> PhotoArtifacts? {
        lock.lock(); defer { lock.unlock() }
        return artifacts[id]
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        artifacts.removeAll()
    }
}
