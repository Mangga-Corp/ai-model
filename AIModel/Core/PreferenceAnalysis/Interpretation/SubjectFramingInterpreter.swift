import Foundation
import CoreGraphics

/// Characteristic 2: how the main human subject is framed.
///
/// DECISION METHOD (applied in order):
///
/// 1. No main subject
///    - Person detector failed            -> unknown (unavailable)
///    - Detector ran, found nobody        -> `other` if segmentation also sees no
///      person (moderate), `other` if segmentation is unavailable (low),
///      unknown if segmentation DOES see a person (sources conflict)
///    - Only tiny/uncertain detections    -> unknown (insufficient)
///
/// 2. Main subject with usable body-pose landmarks (>= 3 landmarks at
///    confidence >= 0.30, mostly inside the subject's box). The deepest body
///    region with reliable landmarks gives the visible extent
///    (head / shoulders / hips / knees / ankles).
///    - Extent reaches the ankles                -> full body
///    - Extent stops above the ankles AND the subject's box runs to the bottom
///      of the frame (positive evidence of cropping)
///        - head only                            -> other (close-up)
///        - shoulders, hips or knees             -> half body
///    - Extent stops above the ankles but the box ends INSIDE the frame
///                                               -> unknown. Missing legs alone
///      is not evidence of half-body framing: they may be occluded or missed.
///
/// 3. Main subject without usable pose (box-only evidence, low quality)
///    - box touches the bottom edge and the upper-body box is >= 80% of the
///      full box's height                        -> half body
///    - otherwise                                -> unknown
nonisolated enum SubjectFramingInterpreter {

    static let reliableThreshold = PoseCandidate.reliableThreshold
    /// Upper-body / full-body height ratio at or above which a cropped box is
    /// mostly torso-and-up.
    static let upperBodyRatioForHalfBody = 0.80

    static func interpret(selection: SubjectSelection, evidence: PhotoEvidence) -> SubjectFramingResult {
        guard let primary = selection.primary else {
            return noSubject(selection: selection, evidence: evidence)
        }

        let box = ImageSpace.clamped(primary.box)
        let edges = ImageSpace.touchedEdges(of: box)
        let croppedAtBottom = edges.contains(.bottom)
        let boxEvidence = EvidenceReference(
            source: .visionHumanRectangles, origin: .rawModelOutput, role: .primary, label: "Person box",
            value: String(format: "x %.3f, y %.3f, w %.3f, h %.3f; touches: %@", box.minX, box.minY, box.width, box.height,
                          edges.isEmpty ? "no edge" : edges.map(\.rawValue).sorted().joined(separator: ", ")))

        // Pose-based path.
        if let pose = evidence.pose.value.flatMap({ SubjectAssociation.pose(for: box, among: $0) }) {
            let regions = BodyRegions(pose: pose)
            let extent = regions.extent
            let reliableCount = pose.reliableLandmarks().count
            let poseEvidence = EvidenceReference(
                source: .visionBodyPose, origin: .rawModelOutput, role: .primary, label: "Reliable landmarks",
                value: "\(reliableCount) of \(BodyJoint.allCases.count) at confidence >= \(String(format: "%.2f", reliableThreshold)); " + regions.summary)
            let extentEvidence = EvidenceReference(
                source: nil, origin: .derivedMeasurement, role: .primary, label: "Visible body extent",
                value: describe(extent))

            if extent >= .toAnkles {
                return fullBody(pose: pose, regions: regions, edges: edges, box: box, reliableCount: reliableCount,
                                evidence: [boxEvidence, poseEvidence, extentEvidence])
            }
            if extent >= .headAndShoulders || extent == .headOnly {
                return cropped(extent: extent, croppedAtBottom: croppedAtBottom, edges: edges,
                               reliableCount: reliableCount, pose: pose,
                               evidence: [boxEvidence, poseEvidence, extentEvidence])
            }
            // Too little pose evidence to use: fall through to box-only.
        }

        return boxOnly(primary: primary, box: box, edges: edges, croppedAtBottom: croppedAtBottom,
                       poseProblem: evidence.pose.problem, boxEvidence: boxEvidence, poseOutcome: evidence.pose)
    }

    // MARK: Full body

    private static func fullBody(pose: PoseCandidate, regions: BodyRegions, edges: Set<FrameEdge>,
                                 box: CGRect, reliableCount: Int, evidence: [EvidenceReference]) -> SubjectFramingResult {
        let ankles = [BodyJoint.leftAnkle, .rightAnkle].compactMap { pose.reliable($0) }
        var quality: EvidenceQuality = ankles.count == 2 ? .high : .moderate
        var limitations: [String] = []

        if edges.contains(.bottom) || ankles.contains(where: { $0.point.y >= 0.985 }) {
            quality = min(quality, .moderate)
            limitations.append("The ankles are at the very bottom of the frame, so the feet may be cut off.")
        }
        if edges.contains(.top) {
            quality = quality.lowered()
            limitations.append("The subject's box touches the top edge, so the head may be cut off.")
        }
        if pose.observationConfidence < 0.5 {
            quality = quality.lowered()
            limitations.append("Body-pose confidence is low.")
        }
        limitations.append("Full body means the head-to-ankle extent is inside the frame; feet are not separately detected.")

        let explanation = ankles.count == 2
            ? "Landmarks from the head down to both ankles were found inside the frame, so the whole figure is visible."
            : "Landmarks from the head down to one ankle were found inside the frame, so the figure appears fully visible."

        return SubjectFramingResult(
            category: .fullBody, visibleExtent: regions.extent, croppedEdges: edges,
            reliableLandmarkCount: reliableCount,
            assessment: Assessment(status: .determined, quality: quality, explanation: explanation,
                                   evidence: evidence + [interpretation("Full body")], limitations: limitations))
    }

    // MARK: Cropped / partial

    private static func cropped(extent: VisibleBodyExtent, croppedAtBottom: Bool, edges: Set<FrameEdge>,
                                reliableCount: Int, pose: PoseCandidate,
                                evidence: [EvidenceReference]) -> SubjectFramingResult {
        let extentName = describe(extent)

        // The body stops above the ankles but the frame does not cut it:
        // missing legs alone are NOT evidence of half-body framing.
        guard croppedAtBottom else {
            return SubjectFramingResult(
                category: .unknown, visibleExtent: extent, croppedEdges: edges, reliableLandmarkCount: reliableCount,
                assessment: .insufficient(
                    "Landmarks reach only \(extentName), but the subject is not cut off by the bottom of the frame. The lower body may be hidden behind something or simply not detected, so the framing is not classified.",
                    evidence: evidence + [interpretation("Unknown: lower body absent without evidence of cropping")],
                    limitations: ["Absence of ankle landmarks alone is not treated as half-body framing."]))
        }

        if extent == .headOnly {
            return SubjectFramingResult(
                category: .other, visibleExtent: extent, croppedEdges: edges, reliableLandmarkCount: reliableCount,
                assessment: Assessment(
                    status: .determined, quality: .moderate,
                    explanation: "Only the head is reliably visible and the frame cuts the body below it, a close-up rather than a full- or half-body framing.",
                    evidence: evidence + [interpretation("Other: head close-up")],
                    limitations: ["Close-ups are grouped under Other in the initial categories."]))
        }

        var quality: EvidenceQuality
        var limitations: [String] = []
        switch extent {
        case .headAndShoulders, .toHips:
            quality = reliableCount >= 5 ? .high : .moderate
        default: // .toKnees
            quality = .low
            limitations.append("Knee-up framing sits between half and full body; it is grouped as half body in the initial categories.")
        }
        if pose.observationConfidence < 0.5 {
            quality = quality.lowered()
            limitations.append("Body-pose confidence is low.")
        }

        return SubjectFramingResult(
            category: .halfBody, visibleExtent: extent, croppedEdges: edges, reliableLandmarkCount: reliableCount,
            assessment: Assessment(
                status: .determined, quality: quality,
                explanation: "Landmarks are reliable down to \(extentName) and not below, and the subject's box runs to the bottom of the frame, so the frame crops the body at that point.",
                evidence: evidence + [interpretation("Half body: cropped at the frame bottom")],
                limitations: limitations))
    }

    // MARK: Box-only fallback

    private static func boxOnly(primary: HumanCandidate, box: CGRect, edges: Set<FrameEdge>,
                                croppedAtBottom: Bool, poseProblem: String?, boxEvidence: EvidenceReference,
                                poseOutcome: EvidenceOutcome<[PoseCandidate]>) -> SubjectFramingResult {
        let why: String
        switch poseOutcome {
        case .failed, .skipped: why = "Body-pose detection was unavailable."
        case .nothingDetected: why = "Body-pose detection found no one."
        case .produced: why = "Pose landmarks did not match the main subject reliably."
        }
        var limitations = [why, "Box-only evidence is weaker than landmark evidence."]

        if croppedAtBottom, let upper = primary.upperBodyBox, box.height > 0 {
            let ratio = Double(upper.height / box.height)
            let ratioEvidence = EvidenceReference(
                source: .visionHumanRectangles, origin: .derivedMeasurement, role: .supporting,
                label: "Upper-body / full-body height", value: String(format: "%.2f", ratio))
            if ratio >= upperBodyRatioForHalfBody {
                return SubjectFramingResult(
                    category: .halfBody, visibleExtent: nil, croppedEdges: edges, reliableLandmarkCount: 0,
                    assessment: Assessment(
                        status: .determined, quality: .low,
                        explanation: "The subject's box runs to the bottom of the frame and the head-and-torso box makes up \(Int((ratio * 100).rounded()))% of its height, suggesting a waist-up framing.",
                        evidence: [boxEvidence, ratioEvidence, interpretation("Half body (box evidence only)")],
                        limitations: limitations))
            }
        }

        limitations.append("The boxes alone do not show how much of the body is visible.")
        return SubjectFramingResult(
            category: .unknown, visibleExtent: nil, croppedEdges: edges, reliableLandmarkCount: 0,
            assessment: .insufficient(
                "A person was found, but there is not enough landmark or box evidence to tell how much of the body is in the frame.",
                evidence: [boxEvidence, interpretation("Unknown: insufficient evidence")], limitations: limitations))
    }

    // MARK: No main subject

    private static func noSubject(selection: SubjectSelection, evidence: PhotoEvidence) -> SubjectFramingResult {
        func result(_ category: FramingCategory, _ assessment: Assessment) -> SubjectFramingResult {
            SubjectFramingResult(category: category, visibleExtent: nil, croppedEdges: [],
                                 reliableLandmarkCount: 0, assessment: assessment)
        }

        switch evidence.humans {
        case .failed(let message), .skipped(let message):
            return result(.unknown, .unavailable(
                "Person detection did not run, so the framing could not be assessed.",
                evidence: [EvidenceReference(source: .visionHumanRectangles, origin: .rawModelOutput, role: .limiting,
                                             label: "Person detection", value: message)]))

        case .produced(let all):
            return result(.unknown, .insufficient(
                "\(all.count) detection(s) were too small or uncertain to treat as the main subject.",
                evidence: [EvidenceReference(source: .visionHumanRectangles, origin: .rawModelOutput, role: .limiting,
                                             label: "Ineligible detections", value: "\(all.count)")],
                limitations: ["Eligibility: " + SubjectSelectionInfo.policy]))

        case .nothingDetected:
            let detectorEvidence = EvidenceReference(
                source: .visionHumanRectangles, origin: .rawModelOutput, role: .primary,
                label: "Person detection", value: "ran successfully, found no people")
            guard let segmentation = evidence.segmentation.value, segmentation.personClassPresentInLabelTable else {
                return result(.other, Assessment(
                    status: .determined, quality: .low,
                    explanation: "No person was detected, so human framing does not apply. Only the person detector ran, so this is a low-trust result.",
                    evidence: [detectorEvidence], limitations: ["Segmentation was unavailable to cross-check."]))
            }
            let share = segmentation.personFraction
            let segEvidence = EvidenceReference(
                source: .detrSegmentation, origin: .derivedMeasurement,
                role: share >= 0.01 ? .limiting : .supporting,
                label: "Person pixels", value: String(format: "%.2f%% of the frame", share * 100))
            if share >= 0.01 {
                return result(.unknown, .insufficient(
                    String(format: "The person detector found nobody, but segmentation labels %.1f%% of the frame as person. The sources disagree, so the framing is not classified.", share * 100),
                    evidence: [detectorEvidence, segEvidence]))
            }
            return result(.other, Assessment(
                status: .determined, quality: share < 0.005 ? .moderate : .low,
                explanation: String(format: "The person detector found nobody and segmentation labels only %.1f%% of the frame as person, so there is no human subject to frame. Human framing does not apply to this photo.", share * 100),
                evidence: [detectorEvidence, segEvidence, interpretation("Other / not applicable")],
                limitations: ["A very small or heavily occluded person can still be present; this photo is treated as having no human subject."]))
        }
    }

    // MARK: Helpers

    private static func interpretation(_ value: String) -> EvidenceReference {
        EvidenceReference(source: nil, origin: .interpretation, role: .primary, label: "Framing", value: value)
    }

    private static func describe(_ extent: VisibleBodyExtent) -> String {
        switch extent {
        case .none: return "no body region"
        case .headOnly: return "the head"
        case .headAndShoulders: return "the head and shoulders"
        case .toHips: return "the hips"
        case .toKnees: return "the knees"
        case .toAnkles: return "the ankles"
        }
    }

    /// Which body regions have reliable landmarks.
    struct BodyRegions {
        let head: Bool, shoulders: Bool, hips: Bool, knees: Bool, ankles: Bool

        init(pose: PoseCandidate) {
            func any(_ joints: [BodyJoint]) -> Bool { joints.contains { pose.reliable($0) != nil } }
            head = any([.nose, .leftEye, .rightEye, .leftEar, .rightEar])
            shoulders = any([.leftShoulder, .rightShoulder, .neck])
            hips = any([.leftHip, .rightHip, .root])
            knees = any([.leftKnee, .rightKnee])
            ankles = any([.leftAnkle, .rightAnkle])
        }

        var extent: VisibleBodyExtent {
            let upper = head || shoulders
            if upper && ankles { return .toAnkles }
            if upper && knees { return .toKnees }
            if upper && hips { return .toHips }
            if shoulders { return .headAndShoulders }
            if head { return .headOnly }
            return .none
        }

        var summary: String {
            func mark(_ name: String, _ on: Bool) -> String { "\(name) \(on ? "yes" : "no")" }
            return [mark("head", head), mark("shoulders", shoulders), mark("hips", hips),
                    mark("knees", knees), mark("ankles", ankles)].joined(separator: ", ")
        }
    }
}
