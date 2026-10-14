import Foundation
import os

/// Protocol defining the analysis coordinator interface.
protocol AnalysisCoordinating {
    /// Runs the full pipeline, emitting truthful progress updates.
    /// The stream finishes before the returned profile is available.
    func runAnalysis(
        photos: [ReferencePhoto],
        progress: @escaping (AnalysisProgress) -> Void
    ) async throws -> PhotographicPreferenceProfile

    func cancel()
}

/// AnalysisCoordinator — orchestrates the full analysis pipeline (Stages A-E).
///
/// Pipeline:
///   Stage A: Image Preparation (load CGImage)
///   Stage B: Per-Image Visual Analysis (Vision)
///   Stage C: Cross-Image Pattern Analysis (deterministic aggregation)
///   Stage D: Preference Interpretation (Foundation Models or deterministic fallback)
///   Stage E: Evidence Validation (post-processing)
///
/// The coordinator handles:
/// - Concurrency control (limits simultaneous image processing)
/// - Progress reporting (truthful — advances only on completed work)
/// - Cancellation
/// - Error handling for individual photo failures
final class AnalysisCoordinator: AnalysisCoordinating {

    // MARK: - Dependencies (dependency injection for testability)

    private let photoSelectionService: PhotoSelectionServicing
    private let visionAnalysisService: VisionAnalyzing
    private let aggregationService: PreferenceAggregating
    private let interpretationService: PreferenceInterpreting

    // MARK: - State

    private let logger = Logger(subsystem: "com.aimodel.PreferenceAnalyzer", category: "AnalysisCoordinator")

    /// Guards `isCancelled` and `completedCount`, which are touched from
    /// multiple concurrent tasks in the Stage B task group.
    private let stateLock = NSLock()
    private var _isCancelled = false
    private var _completedCount = 0

    private var isCancelled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isCancelled }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isCancelled = newValue }
    }

    /// Increments the completed-photo counter and returns the new value.
    /// Thread-safe because photos finish out of order under concurrency.
    private func incrementCompletedCount() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        _completedCount += 1
        return _completedCount
    }

    /// Maximum concurrent analyses to avoid memory pressure (PRD Section 10).
    private let maxConcurrentAnalyses = 3

    // Fraction of total progress consumed by each pipeline stage.
    // Stage B dominates because it runs every Vision pass on every photo.
    private let stageBFraction = 0.85
    private let stageAFraction = 0.05
    private let stageCDFraction = 0.10

    // MARK: - Init

    init(
        photoSelectionService: PhotoSelectionServicing = PhotoSelectionService(),
        visionAnalysisService: VisionAnalyzing = VisionAnalysisService(),
        aggregationService: PreferenceAggregating = PreferenceAggregationService(),
        interpretationService: PreferenceInterpreting = PreferenceInterpretationService()
    ) {
        self.photoSelectionService = photoSelectionService
        self.visionAnalysisService = visionAnalysisService
        self.aggregationService = aggregationService
        self.interpretationService = interpretationService
    }

    // MARK: - Public API

    func runAnalysis(
        photos: [ReferencePhoto],
        progress: @escaping (AnalysisProgress) -> Void
    ) async throws -> PhotographicPreferenceProfile {
        // Reset per-run state so a reused coordinator instance is safe.
        stateLock.lock()
        _isCancelled = false
        _completedCount = 0
        stateLock.unlock()

        logger.info("Starting analysis pipeline for \(photos.count) photos")

        // ---- Stage A: Image Preparation ----
        progress(AnalysisProgress(
            fraction: 0.0,
            message: "Loading photos...",
            completedPhotoIndex: nil,
            totalPhotos: photos.count
        ))

        let loadedImages = try await photoSelectionService.loadImages(for: photos)

        guard !loadedImages.isEmpty else {
            throw AnalysisPipelineError.noPhotosSelected
        }

        progress(AnalysisProgress(
            fraction: stageAFraction,
            message: "Analyzing photos...",
            completedPhotoIndex: nil,
            totalPhotos: photos.count
        ))

        // ---- Stage B: Per-Image Visual Analysis ----
        let semaphore = DispatchSemaphore(value: maxConcurrentAnalyses)
        var analyses: [PhotoAnalysis] = []
        let total = Double(loadedImages.count)

        try Task.checkCancellation()

        try await withThrowingTaskGroup(of: PhotoAnalysis?.self) { group in
            for (photoID, cgImage, orientation) in loadedImages {
                group.addTask { [weak self] in
                    guard let self else { return nil }

                    semaphore.wait()
                    defer { semaphore.signal() }

                    // Cooperative cancellation: skip work that hasn't started.
                    if self.isCancelled { return nil }

                    let analysis: PhotoAnalysis?
                    do {
                        analysis = try await self.visionAnalysisService.analyze(
                            cgImage: cgImage,
                            orientation: orientation,
                            photoID: photoID
                        )
                    } catch {
                        self.logger.error("Analysis failed for photo \(photoID): \(error.localizedDescription)")
                        analysis = nil  // Don't fail the entire pipeline — PRD Section 10
                    }

                    // Count failures too: they represent finished work.
                    let completed = self.incrementCompletedCount()
                    let fraction = stageAFraction + stageBFraction * (Double(completed) / total)

                    progress(AnalysisProgress(
                        fraction: min(fraction, stageAFraction + stageBFraction),
                        message: "Analyzing photo \(completed) of \(loadedImages.count)",
                        completedPhotoIndex: completed,
                        totalPhotos: loadedImages.count
                    ))

                    return analysis
                }
            }

            for try await analysis in group {
                if let analysis = analysis {
                    analyses.append(analysis)
                }
            }
        }

        // Sort by selection order
        let photoMap = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        analyses.sort { (a, b) in
            (photoMap[a.referencePhotoID]?.selectionOrder ?? 0) < (photoMap[b.referencePhotoID]?.selectionOrder ?? 0)
        }

        guard !analyses.isEmpty else {
            throw AnalysisPipelineError.noPhotosAnalyzedSuccessfully
        }

        // ---- Stage C: Cross-Image Pattern Analysis ----
        progress(AnalysisProgress(
            fraction: stageAFraction + stageBFraction,
            message: "Finding patterns...",
            completedPhotoIndex: nil,
            totalPhotos: photos.count
        ))

        logger.info("Aggregating patterns across \(analyses.count) analyses")

        // ---- Fallback: no usable photo ----
        //
        // Every photo was marked failed, which now includes "no subject
        // detected". Producing a profile from an empty set would show an
        // empty screen with no explanation, so the run stops here with an
        // actionable error instead.
        let usable = analyses.filter { $0.status != .failed }
        guard !usable.isEmpty else {
            logger.error("All \(analyses.count) photo(s) failed analysis — no profile produced")
            throw AnalysisError.noAnalyzablePhotos(total: photos.count)
        }

        let profile = aggregationService.aggregate(analyses: analyses)

        // ---- Stage D: Preference Interpretation ----
        progress(AnalysisProgress(
            fraction: stageAFraction + stageBFraction + stageCDFraction * 0.5,
            message: "Generating your photography profile...",
            completedPhotoIndex: nil,
            totalPhotos: photos.count
        ))

        logger.info("Generating interpretation")
        let interpretation = await interpretationService.interpret(analyses: analyses, profile: profile)

        // ---- Stage E: Evidence Validation ----
        let validatedInsights = validateEvidence(profile: profile, interpretation: interpretation)

        // Rebuild profile with validated insights
        let finalProfile = PhotographicPreferenceProfile(
            id: profile.id,
            photoCount: profile.photoCount,
            successfullyAnalyzedCount: profile.successfullyAnalyzedCount,
            subjectPositionDistribution: profile.subjectPositionDistribution,
            halfBodyPositionDistribution: profile.halfBodyPositionDistribution,
            subjectSizeDistribution: profile.subjectSizeDistribution,
            horizonAngleDistribution: profile.horizonAngleDistribution,
            brightnessDistribution: profile.brightnessDistribution,
            saturationDistribution: profile.saturationDistribution,
            colorTemperatureDistribution: profile.colorTemperatureDistribution,
            headYawDistribution: profile.headYawDistribution,
            headRollDistribution: profile.headRollDistribution,
            bodyOrientationDistribution: profile.bodyOrientationDistribution,
            bodySymmetryDistribution: profile.bodySymmetryDistribution,
            saliencyIntensityDistribution: profile.saliencyIntensityDistribution,
            aestheticScoreDistribution: profile.aestheticScoreDistribution,
            leadingLinesLineCountDistribution: profile.leadingLinesLineCountDistribution,
            leadingLinesAngleDistribution: profile.leadingLinesAngleDistribution,
            leadingLinesConvergenceDistribution: profile.leadingLinesConvergenceDistribution,
            diagonalDominanceRatio: profile.diagonalDominanceRatio,
            ruleOfThirdsPatterns: profile.ruleOfThirdsPatterns,
            sceneCategories: profile.sceneCategories,
            negativeSpacePatterns: profile.negativeSpacePatterns,
            colorHarmonyPatterns: profile.colorHarmonyPatterns,
            dominantColorPalette: profile.dominantColorPalette,
            lightDirectionPatterns: profile.lightDirectionPatterns,
            symmetryDistribution: profile.symmetryDistribution,
            bilateralDistribution: profile.bilateralDistribution,
            symmetryRatio: profile.symmetryRatio,
            symmetryAxisPatterns: profile.symmetryAxisPatterns,
            goldenRatioDistribution: profile.goldenRatioDistribution,
            goldenRatioHitRatio: profile.goldenRatioHitRatio,
            summary: profile.summary,
            insights: validatedInsights,
            analyses: analyses,
            photos: photos,
            mixedPatterns: profile.mixedPatterns,
            limitations: profile.limitations,
            generatedAt: profile.generatedAt
        )

        logger.info("Analysis pipeline complete")
        return finalProfile
    }

    func cancel() {
        isCancelled = true
    }

    // MARK: - Stage E: Evidence Validation

    /// Validates that every insight has supporting measurements from analyzed photos.
    /// Rejects insights with no supporting evidence. (PRD Section 5, Stage E)
    private func validateEvidence(profile: PhotographicPreferenceProfile, interpretation: PreferenceInsight?) -> [PreferenceInsight] {
        var validatedInsights: [PreferenceInsight] = profile.insights

        // Validate interpretation — must have supporting evidence
        if let interpretation = interpretation {
            let hasEvidence = !interpretation.supportingMeasurements.isEmpty || !interpretation.supportingPhotoIDs.isEmpty
            if hasEvidence {
                validatedInsights.append(interpretation)
            }
        }

        return validatedInsights
    }
}

// MARK: - Errors

/// Errors that stop the analysis pipeline before a profile can be produced.
enum AnalysisError: LocalizedError {
    /// No photo yielded a usable measurement. With subject detection now
    /// disqualifying, the common cause is photos without a detectable person.
    case noAnalyzablePhotos(total: Int)

    var errorDescription: String? {
        switch self {
        case .noAnalyzablePhotos(let total):
            if total == 1 {
                return "No subject was detected in your photo. Choose photos that clearly contain a person."
            }
            return "No subject was detected in any of your \(total) photos. Choose photos that clearly contain a person."
        }
    }
}
