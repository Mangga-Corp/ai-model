import Foundation
import CoreGraphics

// MARK: - Provenance

/// A model or framework request that can contribute evidence.
nonisolated enum EvidenceSource: String, Sendable, CaseIterable, Hashable {
    case visionHumanRectangles
    case visionBodyPose
    /// 3D body pose (iOS 17+): joints in metres and the camera's position relative to the body.
    case visionBodyPose3D
    case visionFaceRectangles
    case visionHorizon
    case detrSegmentation
    case depthAnything
    case fastViT
    /// The app's own viewpoint model (camera pitch, roll and focal length).
    case cameraCalibration
    /// Plain image processing (edge detection), not a model.
    case imageLineAnalysis

    var displayName: String {
        switch self {
        case .visionHumanRectangles: return "Vision: human rectangles"
        case .visionBodyPose:        return "Vision: body pose"
        case .visionBodyPose3D:      return "Vision: 3D body pose"
        case .visionFaceRectangles:  return "Vision: face rectangles"
        case .visionHorizon:         return "Vision: horizon"
        case .detrSegmentation:      return "DETR ResNet-50 segmentation"
        case .depthAnything:         return "Depth Anything V2 Small"
        case .fastViT:               return "FastViT-T8 classifier"
        case .cameraCalibration:     return "Camera calibration model"
        case .imageLineAnalysis:     return "Image line analysis (edges)"
        }
    }
}

/// How a piece of evidence relates to the conclusion it supports.
nonisolated enum EvidenceRole: String, Sendable, Hashable {
    /// Directly determines the conclusion.
    case primary
    /// Consistent with the conclusion but not sufficient alone.
    case supporting
    /// Context only; deliberately NOT used to decide.
    case contextual
    /// Reduces trust in, or limits, the conclusion.
    case limiting
}

/// Where a value sits between the raw model output and the final interpretation.
nonisolated enum EvidenceOrigin: String, Sendable, Hashable {
    case rawModelOutput
    case derivedMeasurement
    case interpretation
}

/// One traceable line of evidence behind a characteristic result.
nonisolated struct EvidenceReference: Sendable, Equatable, Identifiable {
    var id: String { "\(source?.rawValue ?? "derived")|\(label)|\(role.rawValue)" }
    let source: EvidenceSource?
    let origin: EvidenceOrigin
    let role: EvidenceRole
    let label: String
    let value: String
}

/// The result of asking one source for evidence. Keeps "ran and found nothing"
/// (negative evidence) distinct from "could not run" (missing evidence).
nonisolated enum EvidenceOutcome<Value: Sendable & Equatable>: Sendable, Equatable {
    case produced(Value)
    /// The source ran successfully and reported no instances.
    case nothingDetected
    /// The source failed; its evidence is missing, not negative.
    case failed(String)
    /// The source was not run (unavailable or unnecessary).
    case skipped(String)

    var value: Value? {
        if case .produced(let v) = self { return v }
        return nil
    }

    var ranSuccessfully: Bool {
        switch self {
        case .produced, .nothingDetected: return true
        case .failed, .skipped: return false
        }
    }

    var problem: String? {
        switch self {
        case .failed(let m), .skipped(let m): return m
        default: return nil
        }
    }
}

/// What happened when a source was invoked, for the technical-details view.
nonisolated struct SourceRunRecord: Sendable, Equatable, Identifiable {
    enum State: String, Sendable { case produced, nothingDetected, failed, skipped }
    var id: String { source.rawValue }
    let source: EvidenceSource
    let state: State
    let durationMilliseconds: Int
    let detail: String
}

// MARK: - Vision evidence

/// A detected person, in image space.
nonisolated struct HumanCandidate: Sendable, Equatable, Identifiable {
    /// Index in Vision's raw output order (stable within one run).
    let id: Int
    /// Box from `DetectHumanRectanglesRequest` with `upperBodyOnly = false`.
    let box: CGRect
    let confidence: Double
    /// Matching `upperBodyOnly = true` detection, when one overlaps this person.
    let upperBodyBox: CGRect?
    let upperBodyConfidence: Double?

    var area: Double { ImageSpace.area(box) }
}

nonisolated enum BodyJoint: String, Sendable, CaseIterable, Hashable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

nonisolated struct BodyLandmark: Sendable, Equatable {
    let joint: BodyJoint
    /// Image space.
    let point: CGPoint
    let confidence: Double
}

nonisolated struct PoseCandidate: Sendable, Equatable {
    let landmarks: [BodyLandmark]
    let observationConfidence: Double

    /// Vision reports joints it could not see at confidence 0 with meaningless
    /// coordinates, so a landmark only counts when it clears this threshold.
    static let reliableThreshold = 0.30

    func landmark(_ joint: BodyJoint) -> BodyLandmark? {
        landmarks.first { $0.joint == joint }
    }

    func reliable(_ joint: BodyJoint, threshold: Double = PoseCandidate.reliableThreshold) -> BodyLandmark? {
        guard let l = landmark(joint), l.confidence >= threshold else { return nil }
        return l
    }

    func reliableLandmarks(threshold: Double = PoseCandidate.reliableThreshold) -> [BodyLandmark] {
        landmarks.filter { $0.confidence >= threshold }
    }
}

/// One person's 3D body pose. Positions are in metres, relative to the body's root joint
/// (between the hips), with +y pointing up the body. The camera position comes from the same
/// observation, so camera and body are in one frame. Vision estimates the scale from an
/// assumed body height unless the device measured depth (`isHeightMeasured`).
nonisolated struct BodyPose3DCandidate: Sendable, Equatable {
    /// The head centre in image space (top-left origin): matches this pose to a person box.
    let headInImage: CGPoint?
    /// Head centre, metres from the root.
    let headX: Double
    let headY: Double
    let headZ: Double
    /// Heights (y, metres from the root) of the shoulders, hips, knees and ankles, averaged
    /// left and right; nil when Vision did not report the joint.
    let shoulderY: Double?
    let hipY: Double?
    let kneeY: Double?
    let ankleY: Double?
    /// Camera position, metres from the root.
    let cameraX: Double
    let cameraY: Double
    let cameraZ: Double
    let bodyHeight: Double
    let isHeightMeasured: Bool
    let confidence: Double
}

/// A detected face. Angles are the HEAD's orientation relative to the camera as
/// reported by Vision. They are not a camera-elevation measurement.
nonisolated struct FaceCandidate: Sendable, Equatable {
    let box: CGRect
    let confidence: Double
    let rollDegrees: Double
    let yawDegrees: Double
    let pitchDegrees: Double
}

/// Vision's horizon angle. It describes image roll, not camera elevation.
nonisolated struct ImageRollEvidence: Sendable, Equatable {
    let angleDegrees: Double
    let confidence: Double
}

/// What the viewpoint model estimated about the camera that took the photo.
/// Conventions match `DeviceAttitude` and `make_panorama_crops.py`.
nonisolated struct CameraCalibrationEstimate: Sendable, Equatable {
    /// Positive = camera tilted UP.
    let pitchUpDegrees: Double
    /// Positive = clockwise as the photographer sees it (right side down).
    let rollDegrees: Double
    /// Focal length in units of the photo's HEIGHT (same units as `LensModel`).
    let focalLength: Double
    /// One standard deviation of each estimate, as the model itself reports it.
    let pitchSigmaDegrees: Double
    let rollSigmaDegrees: Double
    /// Standard deviation of log(focal length).
    let focalLogSigma: Double
}

nonisolated struct ScoredLabel: Sendable, Equatable {
    let label: String
    let score: Double
}

/// A straight, near-vertical edge found in the photo (image space, see `ImageSpace`).
/// Pure geometry: nothing says yet whether it belongs to a building, a door
/// frame or a tree. Interpretation happens later, with segmentation.
nonisolated struct ImageLineSegment: Sendable, Equatable {
    /// Upper endpoint.
    let start: CGPoint
    /// Lower endpoint.
    let end: CGPoint
    /// Length in image-HEIGHT units, so it is comparable across aspect ratios.
    let length: Double
    /// Mean edge strength, 0...1.
    let strength: Double
}

// MARK: - Model evidence

/// Compact facts about the DETR output. The pixel grid itself lives in
/// `PhotoArtifacts`, not in the result.
nonisolated struct SegmentationSummary: Sendable, Equatable {
    let gridWidth: Int
    let gridHeight: Int
    /// Share of pixels labelled `person` (all people merged: the model is
    /// semantic, not instance-level).
    let personFraction: Double
    let personClassPresentInLabelTable: Bool
    let topClasses: [ScoredLabel]
}

nonisolated struct DepthSummary: Sendable, Equatable {
    let gridWidth: Int
    let gridHeight: Int
    let meanNearness: Double
    /// Standard deviation of the normalised map: ~0 means a flat, uninformative map.
    let contrast: Double
    static let convention = "Relative depth, normalised 0...1 per image; larger = nearer. Not metric distance."
}

// MARK: - Raw grids (kept outside results)

/// DETR per-pixel class indices. Row-major, image-space orientation.
nonisolated struct SegmentationGrid: Sendable {
    let width: Int
    let height: Int
    let classIndices: [UInt8]
    let labels: [String]

    var personClassIndex: Int? { labels.firstIndex(of: "person") }

    func classIndex(atX x: Int, y: Int) -> Int {
        Int(classIndices[min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))])
    }

    func classIndex(atNormalized p: CGPoint) -> Int {
        classIndex(atX: Int(p.x * CGFloat(width)), y: Int(p.y * CGFloat(height)))
    }

    func label(atNormalized p: CGPoint) -> String? {
        let i = classIndex(atNormalized: p)
        return labels.indices.contains(i) ? labels[i] : nil
    }

    func isPerson(atNormalized p: CGPoint) -> Bool {
        guard let person = personClassIndex else { return false }
        return classIndex(atNormalized: p) == person
    }
}

/// Depth Anything output. Row-major, image-space orientation, 0...1, larger = nearer.
nonisolated struct DepthGrid: Sendable {
    let width: Int
    let height: Int
    let nearness: [Float]

    func value(atNormalized p: CGPoint) -> Float {
        let x = min(width - 1, max(0, Int(p.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(p.y * CGFloat(height))))
        return nearness[y * width + x]
    }
}

/// Heavy per-photo outputs retained only for overlays and reproducibility.
nonisolated struct PhotoArtifacts: Sendable {
    var segmentation: SegmentationGrid?
    var depth: DepthGrid?
}

// MARK: - Evidence bundle

/// Everything the sources produced for one photo, before interpretation.
nonisolated struct PhotoEvidence: Sendable, Equatable {
    var humans: EvidenceOutcome<[HumanCandidate]>
    var pose: EvidenceOutcome<[PoseCandidate]>
    var faces: EvidenceOutcome<[FaceCandidate]>
    var imageRoll: EvidenceOutcome<ImageRollEvidence>
    var segmentation: EvidenceOutcome<SegmentationSummary>
    var depth: EvidenceOutcome<DepthSummary>
    var sceneContext: EvidenceOutcome<[ScoredLabel]>
    var runs: [SourceRunRecord]
    /// Near-vertical edge segments, the raw input for scene-geometry evidence.
    var verticalLines: EvidenceOutcome<[ImageLineSegment]> = .skipped("not run")
    /// 3D body poses with the camera's position relative to each body.
    var bodyPose3D: EvidenceOutcome<[BodyPose3DCandidate]> = .skipped("not run")
    /// The viewpoint model's estimate. Skipped (not a problem) when the model is not in the app.
    var cameraCalibration: EvidenceOutcome<CameraCalibrationEstimate> = .skipped("not run")

    /// Problems worth surfacing, one line per failed or skipped source.
    var problems: [String] {
        var out: [String] = []
        func add<V>(_ source: EvidenceSource, _ outcome: EvidenceOutcome<V>) {
            if let p = outcome.problem { out.append("\(source.displayName): \(p)") }
        }
        add(.visionHumanRectangles, humans)
        add(.visionBodyPose, pose)
        add(.visionFaceRectangles, faces)
        add(.visionHorizon, imageRoll)
        add(.detrSegmentation, segmentation)
        add(.depthAnything, depth)
        add(.fastViT, sceneContext)
        // `skipped` is the "not run" default used by tests; only a real failure is a problem.
        if case .failed(let message) = verticalLines { out.append("\(EvidenceSource.imageLineAnalysis.displayName): \(message)") }
        if case .failed(let message) = bodyPose3D { out.append("\(EvidenceSource.visionBodyPose3D.displayName): \(message)") }
        if case .failed(let message) = cameraCalibration { out.append("\(EvidenceSource.cameraCalibration.displayName): \(message)") }
        return out
    }
}
