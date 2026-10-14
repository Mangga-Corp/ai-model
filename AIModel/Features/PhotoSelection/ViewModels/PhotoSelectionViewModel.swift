import Foundation
import PhotosUI
import os
import Combine

/// ViewModel for the photo selection screen (Page 1).
/// Manages the set of selected reference photos and picker presentation.
@MainActor
final class PhotoSelectionViewModel: ObservableObject {

    @Published var selectedPhotos: [ReferencePhoto] = []
    @Published var isShowingPicker = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    let maxSelectionCount = 5
    /// Advisory only — a smaller selection is allowed but reports weaker evidence.
    let suggestedSelectionCount = 3
    private var processedIdentifiers: Set<String> = []
    private let logger = Logger(subsystem: "com.aimodel.PreferenceAnalyzer", category: "PhotoSelection")

    /// Owns converting picker results into images. Injected so tests can
    /// substitute it without touching the Photos framework.
    private let photoSelectionService: PhotoSelectionServicing

    /// Injectable for testing; defaults to the real service in the app.
    init(photoSelectionService: PhotoSelectionServicing = PhotoSelectionService()) {
        self.photoSelectionService = photoSelectionService
    }

    var canAnalyze: Bool {
        !selectedPhotos.isEmpty && !isLoading
    }

    /// A note shown when the selection is small enough that aggregation has
    /// little to work with. Advisory only — analysis still runs, because the
    /// app reports evidence honestly rather than refusing a small sample.
    var smallSampleNote: String? {
        guard !isLoading, !selectedPhotos.isEmpty, selectedPhotos.count < suggestedSelectionCount else {
            return nil
        }
        return "Patterns are more reliable with 3–5 photos. You can still analyze this selection."
    }

    var remainingSelectionCount: Int {
        max(0, maxSelectionCount - selectedPhotos.count)
    }

    var selectionCountText: String {
        if selectedPhotos.isEmpty {
            return "Recommended: 3–5 photos (max \(maxSelectionCount))"
        } else {
            return "\(selectedPhotos.count) of \(maxSelectionCount) selected"
        }
    }

    // MARK: - Public API

    func selectPhotos() {
        guard selectedPhotos.count < maxSelectionCount else {
            errorMessage = "Maximum selection limit reached (\(maxSelectionCount) photos)."
            return
        }
        isShowingPicker = true
    }

    /// Called when the PHPicker returns selected results.
    func handlePickerResults(_ results: [PHPickerResult]) {
        isShowingPicker = false
        isLoading = true

        Task {
            await processPickerResults(results)
            isLoading = false
        }
    }

    private func processPickerResults(_ results: [PHPickerResult]) async {
        do {
            for (index, result) in results.enumerated() {
                guard selectedPhotos.count < maxSelectionCount else { break }

                // Extract localIdentifier for deduplication
                let localIdentifier = extractLocalIdentifier(from: result)

                // Prevent duplicate selection (PRD 4.1.4)
                if let identifier = localIdentifier {
                    if processedIdentifiers.contains(identifier) ||
                       selectedPhotos.contains(where: { $0.localIdentifier == identifier }) {
                        continue
                    }
                    processedIdentifiers.insert(identifier)
                }

                // Load the image for thumbnail display and future analysis
                let image = try await photoSelectionService.loadImage(from: result)

                let photo = ReferencePhoto(
                    id: UUID(),
                    localIdentifier: localIdentifier ?? UUID().uuidString,
                    image: image,
                    selectionOrder: selectedPhotos.count
                )
                selectedPhotos.append(photo)
            }
        } catch {
            logger.error("Photo loading error: \(error.localizedDescription)")
            errorMessage = "Failed to load some photos. Please try again."
        }
    }

    func removePhoto(_ photo: ReferencePhoto) {
        selectedPhotos.removeAll { $0.id == photo.id }
        processedIdentifiers.remove(photo.localIdentifier)

        // Reorder selection order for remaining photos
        for (index, var photo) in selectedPhotos.enumerated() {
            photo.selectionOrder = index
            selectedPhotos[index] = photo
        }
    }

    func clearAll() {
        selectedPhotos.removeAll()
        processedIdentifiers.removeAll()
    }

    // MARK: - Private Helpers

    private func extractLocalIdentifier(from result: PHPickerResult) -> String? {
        // PHPickerResult provides asset identifier via assetIdentifier property
        // This is the stable identifier for the PHAsset
        return result.assetIdentifier
    }

}
