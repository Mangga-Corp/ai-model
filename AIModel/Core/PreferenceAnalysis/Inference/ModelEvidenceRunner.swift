import Foundation
import CoreML
import CoreGraphics
import Vision   // VNImageCropAndScaleOption, used by SceneModelIO

// MARK: - Depth Anything (analysis-side wrapper)

/// Depth Anything V2 Small, wrapped for this feature so the raw output can be
/// validated and kept (the camera's `DepthAnythingEstimator` discards it).
///
/// Verified contract (checked against the shipped package):
///   - input  `image`: RGB 518x392
///   - output `depth`: one-channel Float16 image, 518x392, values in 0...1
///   - convention: LARGER = NEARER. Confirmed on real landscapes: sky ~0.0-0.09,
///     foreground ground ~0.68-0.82, and on portraits the person is nearer than
///     the surroundings. Values are relative inverse depth, not metres.
///
/// The map is min-max normalised per image so the nearest pixel is 1 and the
/// farthest is 0; deltas are therefore only meaningful within one image.
actor DepthEvidenceModel {

    static let modelName = "DepthAnythingV2SmallF16P6"
    /// Verified near/far polarity of the model output (see header).
    static let largerIsNearer = true

    private var model: MLModel?
    private var isCPUOnly = DepthEvidenceModel.startsOnCPU

    /// The iOS Simulator's GPU path returns an all-zero map for this model
    /// (verified), so it starts on the CPU there. Real devices start on `.all`.
    private static var startsOnCPU: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    func prepare() async throws {
        guard model == nil else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = isCPUOnly ? .cpuOnly : .all
        model = try await SceneModelLoader.load(Self.modelName, configuration: configuration)
    }

    /// Runs the model; if the accelerated path yields a degenerate map, retries
    /// once on the CPU before giving up.
    func estimate(_ image: CGImage) async throws -> DepthGrid {
        do {
            return try await run(image)
        } catch SceneModelError.unexpectedOutput(let reason) where !isCPUOnly {
            isCPUOnly = true
            model = nil
            do {
                return try await run(image)
            } catch {
                throw SceneModelError.unexpectedOutput("\(reason); CPU retry also failed")
            }
        }
    }

    private func run(_ image: CGImage) async throws -> DepthGrid {
        try await prepare()
        guard let model else { throw SceneModelError.notLoaded("Depth") }

        // scaleFill: the whole frame is stretched to the model input, so a
        // normalised position in the output equals the same position in the photo.
        let input = try SceneModelIO.imageInput(for: model, image: image, crop: .scaleFill)
        let output = try await model.prediction(from: input)

        let grid: (width: Int, height: Int, values: [Float])
        if let buffer = SceneModelIO.firstOutput(of: .image, in: output, model: model)?.imageBufferValue {
            grid = try SceneModelIO.grid(from: buffer)
        } else if let array = SceneModelIO.firstOutput(of: .multiArray, in: output, model: model)?.multiArrayValue {
            grid = try SceneModelIO.grid(from: array)
        } else {
            throw SceneModelError.unexpectedOutput("Depth: no image or multi-array output")
        }

        guard grid.width > 0, grid.height > 0, grid.values.count == grid.width * grid.height else {
            throw SceneModelError.unexpectedOutput("Depth: empty or inconsistent output")
        }
        guard grid.values.allSatisfy({ $0.isFinite }) else {
            throw SceneModelError.unexpectedOutput("Depth: output contains non-finite values")
        }
        guard let lo = grid.values.min(), let hi = grid.values.max(), hi - lo > 1e-4 else {
            throw SceneModelError.unexpectedOutput("Depth: output has no variation")
        }

        let range = hi - lo
        let nearness = grid.values.map { raw -> Float in
            let n = (raw - lo) / range
            return Self.largerIsNearer ? n : 1 - n
        }
        return DepthGrid(width: grid.width, height: grid.height, nearness: nearness)
    }
}

// MARK: - Model set

/// The Core ML models, created together so they can be released together.
nonisolated final class AnalysisModels: @unchecked Sendable {
    let segmenter = DETRSegmenter()
    let depth = DepthEvidenceModel()
    let classifier = FastViTClassifier()
    let calibration = CameraCalibrationModel()
}

// MARK: - Runner

nonisolated struct ModelEvidenceBundle: Sendable {
    var segmentation: EvidenceOutcome<SegmentationSummary>
    var depth: EvidenceOutcome<DepthSummary>
    var sceneContext: EvidenceOutcome<[ScoredLabel]>
    var cameraCalibration: EvidenceOutcome<CameraCalibrationEstimate>
    var artifacts: PhotoArtifacts
    var records: [SourceRunRecord]
}

/// Stage B/C for the Core ML models. Each model runs concurrently and fails
/// independently: a missing depth model never invalidates the segmentation.
nonisolated enum ModelEvidenceRunner {

    static func run(on image: CGImage, models: AnalysisModels) async -> ModelEvidenceBundle {
        async let segmentation = runSegmentation(image, models)
        async let depth = runDepth(image, models)
        async let context = runClassifier(image, models)
        async let calibration = runCalibration(image, models)

        let seg = await segmentation
        let dep = await depth
        let ctx = await context
        let cal = await calibration

        return ModelEvidenceBundle(
            segmentation: seg.outcome, depth: dep.outcome, sceneContext: ctx.outcome,
            cameraCalibration: cal.outcome,
            artifacts: PhotoArtifacts(segmentation: seg.grid, depth: dep.grid),
            records: [seg.record, dep.record, ctx.record, cal.record])
    }

    // MARK: DETR

    private static func runSegmentation(_ image: CGImage, _ models: AnalysisModels) async
        -> (outcome: EvidenceOutcome<SegmentationSummary>, grid: SegmentationGrid?, record: SourceRunRecord) {
        let start = ContinuousClock.now
        do {
            let map = try await models.segmenter.segment(image)
            let indices = map.classIndices.map { UInt8(clamping: $0) }
            let grid = SegmentationGrid(width: map.width, height: map.height,
                                        classIndices: indices, labels: map.labels)
            let summary = summarize(grid)
            let record = SourceRunRecord(
                source: .detrSegmentation, state: .produced,
                durationMilliseconds: start.elapsedMilliseconds,
                detail: "\(grid.width)x\(grid.height) class map, person \(percent(summary.personFraction))")
            return (.produced(summary), grid, record)
        } catch {
            let message = describe(error)
            return (.failed(message), nil,
                    SourceRunRecord(source: .detrSegmentation, state: .failed,
                                    durationMilliseconds: start.elapsedMilliseconds, detail: message))
        }
    }

    static func summarize(_ grid: SegmentationGrid) -> SegmentationSummary {
        var histogram = [Int: Int]()
        for value in grid.classIndices { histogram[Int(value), default: 0] += 1 }
        let total = Double(max(1, grid.classIndices.count))
        let person = grid.personClassIndex
        let personFraction = person.map { Double(histogram[$0] ?? 0) / total } ?? 0
        let top = histogram
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5)
            .map { ScoredLabel(label: grid.labels.indices.contains($0.key) ? grid.labels[$0.key] : "class \($0.key)",
                               score: Double($0.value) / total) }
        return SegmentationSummary(gridWidth: grid.width, gridHeight: grid.height,
                                   personFraction: personFraction,
                                   personClassPresentInLabelTable: person != nil,
                                   topClasses: Array(top))
    }

    // MARK: Depth

    private static func runDepth(_ image: CGImage, _ models: AnalysisModels) async
        -> (outcome: EvidenceOutcome<DepthSummary>, grid: DepthGrid?, record: SourceRunRecord) {
        let start = ContinuousClock.now
        do {
            let grid = try await models.depth.estimate(image)
            let n = Double(grid.nearness.count)
            let mean = grid.nearness.reduce(0) { $0 + Double($1) } / n
            let variance = grid.nearness.reduce(0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
            let summary = DepthSummary(gridWidth: grid.width, gridHeight: grid.height,
                                       meanNearness: mean, contrast: variance.squareRoot())
            let record = SourceRunRecord(
                source: .depthAnything, state: .produced,
                durationMilliseconds: start.elapsedMilliseconds,
                detail: "\(grid.width)x\(grid.height) relative depth, contrast \(String(format: "%.2f", summary.contrast))")
            return (.produced(summary), grid, record)
        } catch {
            let message = describe(error)
            return (.failed(message), nil,
                    SourceRunRecord(source: .depthAnything, state: .failed,
                                    durationMilliseconds: start.elapsedMilliseconds, detail: message))
        }
    }

    // MARK: FastViT

    private static func runClassifier(_ image: CGImage, _ models: AnalysisModels) async
        -> (outcome: EvidenceOutcome<[ScoredLabel]>, record: SourceRunRecord) {
        let start = ContinuousClock.now
        do {
            let hints = try await models.classifier.classify(image, top: 5)
            guard !hints.isEmpty else {
                return (.nothingDetected,
                        SourceRunRecord(source: .fastViT, state: .nothingDetected,
                                        durationMilliseconds: start.elapsedMilliseconds, detail: "no labels"))
            }
            let labels = hints.map { ScoredLabel(label: $0.label, score: $0.confidence) }
            return (.produced(labels),
                    SourceRunRecord(source: .fastViT, state: .produced,
                                    durationMilliseconds: start.elapsedMilliseconds,
                                    detail: "top: \(labels[0].label)"))
        } catch {
            let message = describe(error)
            return (.failed(message),
                    SourceRunRecord(source: .fastViT, state: .failed,
                                    durationMilliseconds: start.elapsedMilliseconds, detail: message))
        }
    }

    // MARK: Camera calibration

    private static func runCalibration(_ image: CGImage, _ models: AnalysisModels) async
        -> (outcome: EvidenceOutcome<CameraCalibrationEstimate>, record: SourceRunRecord) {
        let start = ContinuousClock.now
        do {
            let e = try await models.calibration.estimate(image)
            return (.produced(e),
                    SourceRunRecord(source: .cameraCalibration, state: .produced,
                                    durationMilliseconds: start.elapsedMilliseconds,
                                    detail: String(format: "pitch %+.1f° ± %.1f, roll %+.1f° ± %.1f, focal %.2f",
                                                   e.pitchUpDegrees, e.pitchSigmaDegrees,
                                                   e.rollDegrees, e.rollSigmaDegrees, e.focalLength)))
        } catch SceneModelError.missingModel(_) {
            // Optional model: without it the other providers work as before.
            let message = "CameraCalibration.mlpackage is not in the app."
            return (.skipped(message),
                    SourceRunRecord(source: .cameraCalibration, state: .skipped,
                                    durationMilliseconds: start.elapsedMilliseconds, detail: message))
        } catch {
            let message = describe(error)
            return (.failed(message),
                    SourceRunRecord(source: .cameraCalibration, state: .failed,
                                    durationMilliseconds: start.elapsedMilliseconds, detail: message))
        }
    }

    // MARK: Helpers

    static func describe(_ error: Error) -> String {
        if let e = error as? SceneModelError {
            switch e {
            case .missingModel(let n): return "Model file \(n) is not in the app bundle."
            case .notLoaded(let n): return "\(n) model failed to load."
            case .missingLabels(let n): return "\(n) model has no label table."
            case .unexpectedOutput(let m): return "Unexpected model output: \(m)"
            }
        }
        return error.localizedDescription
    }

    private static func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
}
