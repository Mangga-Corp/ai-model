import Foundation
import CoreGraphics

/// Characteristic 1: the camera's vertical viewing angle relative to the subject.
///
/// This type only ORCHESTRATES. It gathers the subject, runs independent
/// evidence providers, hands their observations to `CameraAngleFusion`, and
/// packages the result. Raw observations are kept apart from the final category.
///
/// AUDIT: WHAT THE EXISTING PIPELINE CAN AND CANNOT DETERMINE
///
///  Provider                       Role          What it can establish
///  -----------------------------  ------------  ---------------------------------------------
///  Horizon (DETR sky/sea/ground)  decisive      Camera height vs the eyes, where a straight
///                                               horizon is visible. Robust to cropping.
///  Vertical structure (edges +    decisive      Camera TILT from converging verticals; with
///  DETR structure classes)                      the eyes' position gives the angle. Needs
///                                               building/room structure. The eye position
///                                               term allows for an undetectable crop.
///  Subject geometry (pose/face)   context       Eye line and posture. Required by the above.
///  Head orientation (Vision face) context       Where the face points. NOT camera position.
///  Relative depth (Depth Anything) cross-check  Weak hint of camera tilt from head-vs-body
///                                               depth. Can contradict, never decide.
///  Vision horizon (image roll)    context       Image tilt. NOT camera elevation.
///  FastViT labels                 not used      Generic ImageNet labels say nothing about angle.
///
///  Cannot be determined from this pipeline: camera angle in plain-background
///  portraits, close-ups, or any photo without a horizon AND without vertical
///  structure; the exact angle in degrees; angles for long-lens photos. These
///  return unknown. A dedicated viewpoint model would be needed to go further.
///
/// Absence of any single provider (including the horizon) is never a reason
/// for unknown by itself.
nonisolated enum CameraAngleInterpreter {

    static func interpret(selection: SubjectSelection,
                          evidence: PhotoEvidence,
                          artifacts: PhotoArtifacts,
                          imageSize: CGSize?) -> CameraAngleResult {

        let roll = evidence.imageRoll.value?.angleDegrees

        func result(_ category: CameraAngleCategory, _ assessment: Assessment) -> CameraAngleResult {
            CameraAngleResult(category: category, horizonCue: nil, headPitchDegrees: nil, headYawDegrees: nil,
                              imageRollDegrees: roll, assessment: assessment)
        }

        // A camera angle is relative to a subject: no subject, no angle.
        guard let primary = selection.primary else {
            switch evidence.humans {
            case .failed(let m), .skipped(let m):
                return result(.unknown, .unavailable(
                    "Person detection did not run, so the camera angle relative to a subject could not be assessed.",
                    evidence: [EvidenceReference(source: .visionHumanRectangles, origin: .rawModelOutput,
                                                 role: .limiting, label: "Person detection", value: m)]))
            case .nothingDetected:
                return result(.unknown, .notApplicable(
                    "No person was detected, so there is no subject to measure the camera angle against."))
            case .produced:
                return result(.unknown, .insufficient(
                    "People were detected but too small or uncertain to use as the subject."))
            }
        }

        let face = evidence.faces.value.flatMap { SubjectAssociation.face(for: primary.box, among: $0) }
        let pose = evidence.pose.value.flatMap { SubjectAssociation.pose(for: primary.box, among: $0) }
        let aspect = LensModel.aspect(of: imageSize)

        // Independent providers. None sees another's output.
        let subject = SubjectGeometryProvider.observe(pose: pose, face: face)
        let horizon = HorizonProvider.observe(
            anchor: subject.anchor, segmentation: artifacts.segmentation,
            segmentationProblem: evidence.segmentation.problem, imageRollDegrees: roll,
            aspect: aspect, imageSize: imageSize)
        let scene = SceneVerticalsProvider.observe(
            lines: evidence.verticalLines, segmentation: artifacts.segmentation,
            segmentationProblem: evidence.segmentation.problem, anchor: subject.anchor,
            aspect: aspect, cropAllowance: LensModel.verticalCropAllowance(aspect: aspect))
        let head = HeadOrientationProvider.observe(face: face)
        let depth = DepthTiltProvider.observe(primary: primary, segmentation: artifacts.segmentation, depth: artifacts.depth)

        let observations = [horizon.observation, scene.observation, subject.observation, head, depth]
        let fused = CameraAngleFusion.fuse(observations, anchor: subject.anchor)

        var references = observations.map { reference(for: $0, used: fused.decision.contributing.contains($0.provider)) }
        if let roll {
            references.append(EvidenceReference(
                source: .visionHorizon, origin: .rawModelOutput, role: .contextual,
                label: "Image roll (not camera elevation)", value: String(format: "%.1f° (not used to decide)", roll)))
        }
        references.append(EvidenceReference(
            source: nil, origin: .interpretation, role: .primary, label: "Camera angle",
            value: fused.category == .unknown
                ? "unknown (still possible: \(fused.decision.possibleCategories.map(\.rawValue).sorted().joined(separator: ", ")))"
                : fused.category.rawValue))

        // Only a horizon that actually contributed is presented as evidence.
        let usedHorizon = fused.decision.contributing.contains(.horizonLine)
        let usedScene = fused.decision.contributing.contains(.sceneVerticals)

        return CameraAngleResult(
            category: fused.category,
            horizonCue: usedHorizon ? horizon.cue : nil,
            headPitchDegrees: face?.pitchDegrees,
            headYawDegrees: face?.yawDegrees,
            imageRollDegrees: roll,
            assessment: Assessment(status: fused.status, quality: fused.quality, explanation: fused.explanation,
                                   evidence: references, limitations: fused.limitations),
            observations: observations,
            decision: fused.decision,
            sceneLines: usedScene ? scene.inliers : [])
    }

    // MARK: Evidence references

    private static func reference(for o: CameraAngleObservation, used: Bool) -> EvidenceReference {
        let source: EvidenceSource?
        switch o.provider {
        case .horizonLine: source = .detrSegmentation
        case .sceneVerticals: source = .imageLineAnalysis
        case .subjectGeometry: source = .visionBodyPose
        case .headOrientation: source = .visionFaceRectangles
        case .depthTilt: source = .depthAnything
        }
        let role: EvidenceRole
        if !o.validity.isValid { role = .limiting }
        else if used { role = .primary }
        else if o.role == .corroborating { role = .supporting }
        else { role = .contextual }

        let label: String
        switch o.provider {
        case .horizonLine: label = "Horizon line"
        case .sceneVerticals: label = "Background vertical lines"
        case .subjectGeometry: label = "Subject eye line and posture"
        case .headOrientation: label = "Head orientation (not camera position)"
        case .depthTilt: label = "Relative depth, head vs lower body"
        }
        let detail = o.validity.isValid
            ? ([o.summary] + o.measurements.map { "\($0.label): \($0.value)" }).joined(separator: " | ")
            : "Not used: \(o.validity.reason ?? "unavailable")"
        return EvidenceReference(source: source, origin: .derivedMeasurement, role: role, label: label, value: detail)
    }
}
