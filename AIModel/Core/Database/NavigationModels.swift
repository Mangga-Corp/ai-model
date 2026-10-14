import Foundation

/// Navigation destinations for the app flow
enum NavigationDestination: Hashable {
    case photoSelection
    case photoAnalysis
    case profileView
}

/// Loading states for the analysis process
enum AnalysisLoadingState: Equatable {
    case idle
    case loading
    case analyzing(photoIndex: Int, total: Int)
    case generatingProfile
    case completed
    case failed(error: String)
}

/// A progress update emitted by the analysis pipeline.
///
/// `fraction` is truthful: it advances only when real work completes,
/// never on a timer. (PRD: "Progress should reflect actual completed tasks.")
struct AnalysisProgress {
    /// Completed work as a fraction of total work, 0...1.
    let fraction: Double
    /// Human-readable status, e.g. "Analyzing photo 3 of 8".
    let message: String
    /// Index of the photo just completed, when applicable.
    let completedPhotoIndex: Int?
    let totalPhotos: Int
}


/// Errors that can occur during the analysis pipeline
enum AnalysisPipelineError: Error, LocalizedError {
    case noPhotosSelected
    case noPhotosAnalyzedSuccessfully
    case visionAnalysisFailed(String)
    case foundationModelUnavailable
    case foundationModelError(String)
    case aggregationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPhotosSelected:
            return "No photos were selected."
        case .noPhotosAnalyzedSuccessfully:
            return "No photos could be successfully analyzed."
        case .visionAnalysisFailed(let reason):
            return "Vision analysis failed: \(reason)"
        case .foundationModelUnavailable:
            return "On-device AI model is not available."
        case .foundationModelError(let reason):
            return "AI model error: \(reason)"
        case .aggregationFailed(let reason):
            return "Pattern aggregation failed: \(reason)"
        }
    }
}
