import Foundation
import CoreGraphics
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Protocol defining the photo selection and loading service.
protocol PhotoSelectionServicing {
    func requestAuthorization() async -> Bool
    func loadImages(for references: [ReferencePhoto]) async throws -> [(UUID, CGImage, CGImagePropertyOrientation)]

    /// Converts a `PHPickerResult` into a `UIImage`.
    ///
    /// Lives here, not in the ViewModel, because turning a picker result into an
    /// image is a Photos-framework concern — the same category as loading and
    /// downsampling. Keeping it in the ViewModel duplicated the layer the
    /// service already owns.
    func loadImage(from result: PHPickerResult) async throws -> UIImage?

    /// The photo's 35 mm-equivalent focal length from its EXIF, or nil.
    func loadFocalLength35mm(from result: PHPickerResult) async -> Double?
}

extension PhotoSelectionServicing {
    func loadFocalLength35mm(from result: PHPickerResult) async -> Double? { nil }
}

/// PhotoSelectionService — handles image loading from selected photos.
/// Uses the images already loaded by PHPicker (via ReferencePhoto.image).
/// Does NOT request full photo-library access.
final class PhotoSelectionService: PhotoSelectionServicing {

    func requestAuthorization() async -> Bool {
        // We use PHPicker, which does not require PHPhotoLibrary authorization.
        // This method exists for cases where we need Photos framework access.
        return true
    }

    /// Loads CGImage and orientation for each reference photo.
    /// Uses the UIImage already stored in ReferencePhoto (loaded by PHPicker).
    func loadImages(for references: [ReferencePhoto]) async throws -> [(UUID, CGImage, CGImagePropertyOrientation)] {
        return try await withThrowingTaskGroup(of: (UUID, CGImage, CGImagePropertyOrientation).self) { group in
            for ref in references {
                group.addTask {
                    let image = try await self.loadImage(for: ref)
                    return image
                }
            }

            var results: [(UUID, CGImage, CGImagePropertyOrientation)] = []
            for try await result in group {
                results.append(result)
            }
            // Preserve selection order
            return results.sorted { lhs, rhs in
                let lhsRef = references.first { $0.id == lhs.0 }
                let rhsRef = references.first { $0.id == rhs.0 }
                return (lhsRef?.selectionOrder ?? 0) < (rhsRef?.selectionOrder ?? 0)
            }
        }
    }

    /// Converts a `PHPickerResult` into a `UIImage`.
    ///
    /// Tries the typed object load first, then falls back to raw item data. The
    /// fallback matters: `canLoadObject(ofClass: UIImage.self)` returns false
    /// for some assets (notably Live Photos and certain edited images) that
    /// still load successfully as raw data.
    func loadImage(from result: PHPickerResult) async throws -> UIImage? {
        let provider = result.itemProvider

        if provider.canLoadObject(ofClass: UIImage.self) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: object as? UIImage)
                    }
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: "public.image", options: nil) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                if let image = item as? UIImage {
                    continuation.resume(returning: image)
                } else if let data = item as? Data, let image = UIImage(data: data) {
                    continuation.resume(returning: image)
                } else if let url = item as? URL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Reads the focal length from the picked file's own data, which keeps EXIF (the decoded
    /// `UIImage` does not). Needs no photo-library permission. Nil on any failure: the
    /// analysis then assumes a typical phone lens, as before.
    func loadFocalLength35mm(from result: PHPickerResult) async -> Double? {
        let provider = result.itemProvider
        let type = UTType.image.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
        return data.flatMap(LensMetadataReader.focalLength35mm(imageData:))
    }

    /// Loads the CGImage from the ReferencePhoto's stored UIImage.
    ///
    /// The image is DOWNSAMPLED before it reaches the analysis pipeline.
    /// PHPicker hands back full-resolution images (4032x3024 and up), and every
    /// one of the thirteen analysis passes then pays the cost of that pixel
    /// count. Vision resizes internally anyway, so the full resolution buys
    /// nothing measurable while dominating total analysis time.
    ///
    /// A 1280px long edge keeps every characteristic — subject placement,
    /// horizon angle, face and body pose, leading lines, light direction — well
    /// inside its accuracy range while cutting per-photo work by roughly 90%.
    private func loadImage(for ref: ReferencePhoto) async throws -> (UUID, CGImage, CGImagePropertyOrientation) {
        guard let uiImage = ref.image, let original = uiImage.cgImage else {
            throw NSError(domain: "PhotoSelection", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not load image for photo \(ref.id)"
            ])
        }

        let orientation = uiImage.imageOrientation.toCGImagePropertyOrientation
        let downsampled = Self.downsample(original, maxEdge: Self.analysisMaxEdge) ?? original
        return (ref.id, downsampled, orientation)
    }

    /// Long-edge limit, in pixels, for images entering the analysis pipeline.
    ///
    /// 1280 is well above the resolution at which any of the thirteen passes
    /// loses accuracy, and keeps the per-photo cost low enough that a 5-photo
    /// analysis finishes in a couple of seconds rather than tens of seconds.
    static let analysisMaxEdge = 1280

    /// Scales an image so its long edge does not exceed `maxEdge`, preserving
    /// aspect ratio.
    ///
    /// Uses `UIGraphicsImageRenderer` rather than Core Image or vImage: it
    /// handles arbitrary source formats, and the images involved here are
    /// small enough that its overhead is negligible. Returns nil if rendering
    /// fails, in which case the caller falls back to the original.
    static func downsample(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxEdge else { return image }

        let scale = CGFloat(maxEdge) / CGFloat(longEdge)
        let targetSize = CGSize(
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let downsampled = renderer.image { _ in
            UIImage(cgImage: image, scale: 1.0, orientation: .up)
                .draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return downsampled.cgImage
    }
}

/// Extension to convert UIImage.Orientation to CGImagePropertyOrientation
private extension UIImage.Orientation {
    var toCGImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
