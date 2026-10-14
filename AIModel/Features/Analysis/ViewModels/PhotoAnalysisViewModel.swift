import Foundation
import os
import Combine

/// ViewModel for the photo analysis screen (Page 2).
/// Manages the analysis pipeline, progress reporting, and cancellation.
@MainActor
final class PhotoAnalysisViewModel: ObservableObject {

    // MARK: - Published State

    @Published var loadingState: AnalysisLoadingState = .idle
    @Published var analyzedPhotos: [PhotoAnalysis] = []
    @Published var profile: PhotographicPreferenceProfile?
    @Published var progress: Double = 0.0
    @Published var currentPhotoName: String = ""
    @Published var errorMessage: String?
    @Published var totalPhotos: Int = 0

    // MARK: - Dependencies

    private let coordinator: AnalysisCoordinating
    private let logger = Logger(subsystem: "com.aimodel.PreferenceAnalyzer", category: "PhotoAnalysis")

    /// Held so a new run can cancel an in-flight one.
    private var analysisTask: Task<Void, Never>?

    // MARK: - Init

    init(coordinator: AnalysisCoordinating = AnalysisCoordinator()) {
        self.coordinator = coordinator
    }

    // MARK: - Public API

    var statusText: String {
        switch loadingState {
        case .idle:
            return "Preparing analysis..."
        case .loading:
            return "Loading photos..."
        case .analyzing(let index, let total):
            return "Analyzing photo \(index) of \(total)"
        case .generatingProfile:
            return "Generating your photography profile..."
        case .completed:
            return "Analysis complete"
        case .failed(let error):
            return "Analysis failed: \(error)"
        }
    }

    var isAnalyzing: Bool {
        switch loadingState {
        case .idle, .completed, .failed:
            return false
        case .loading, .analyzing, .generatingProfile:
            return true
        }
    }

    func startAnalysis(photos: [ReferencePhoto]) {
        guard !photos.isEmpty else {
            errorMessage = "No photos selected for analysis."
            return
        }

        analysisTask?.cancel()
        analysisTask = Task {
            await runAnalysis(photos: photos)
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        coordinator.cancel()
        loadingState = .idle
        progress = 0.0
    }

    // MARK: - Private

    private func runAnalysis(photos: [ReferencePhoto]) async {
        loadingState = .loading
        progress = 0.0

        do {
            // The coordinator reports truthful progress as real work completes.
            let result = try await coordinator.runAnalysis(photos: photos) { [weak self] update in
                guard let self else { return }

                Task { @MainActor in
                    guard self.loadingState != .completed else { return }

                    self.progress = update.fraction
                    self.totalPhotos = update.totalPhotos

                    if let completed = update.completedPhotoIndex {
                        self.loadingState = .analyzing(
                            photoIndex: completed,
                            total: update.totalPhotos
                        )
                    } else if update.fraction > 0.85 {
                        self.loadingState = .generatingProfile
                    }
                }
            }

            loadingState = .completed
            progress = 1.0
            profile = result

            // Partial success is still success, but the user should know some
            // photos contributed nothing rather than wondering why the profile
            // reflects fewer photos than they selected.
            let skipped = photos.count - result.successfullyAnalyzedCount
            if skipped > 0 {
                errorMessage = skipped == 1
                    ? "1 photo had no detectable subject and was excluded."
                    : "\(skipped) photos had no detectable subject and were excluded."
            }

            logger.info("Analysis completed successfully for \(photos.count) photos")

        } catch is CancellationError {
            loadingState = .idle
            progress = 0.0

        } catch {
            loadingState = .failed(error: error.localizedDescription)
            // The failure view reads `errorMessage`, not `loadingState`, so both
            // must be set or the screen shows an empty error state.
            errorMessage = error.localizedDescription
            logger.error("Analysis failed: \(error.localizedDescription)")
        }
    }
}
