import Foundation
import CoreGraphics

/// Stage D/E for one photo: turns collected evidence into the four
/// characteristic results and a per-photo status.
nonisolated enum PhotoResultBuilder {

    static func build(prepared: PreparedPhoto,
                      record: ImagePreparationRecord?,
                      evidence: PhotoEvidence,
                      artifacts: PhotoArtifacts) -> PhotoResult {

        let humans = evidence.humans.value ?? []
        let selection = SubjectSelector.select(from: humans)
        let imageSize = record?.preparedSize

        let angle = CameraAngleInterpreter.interpret(selection: selection, evidence: evidence,
                                                     artifacts: artifacts, imageSize: imageSize)
        let framing = SubjectFramingInterpreter.interpret(selection: selection, evidence: evidence)
        let positioning = SubjectPositioningMeasurer.measure(selection: selection, evidence: evidence)
        let depth = EnvironmentalDepthInterpreter.interpret(selection: selection, evidence: evidence,
                                                            artifacts: artifacts)

        let problems = evidence.problems
        let ranAnything = evidence.runs.contains { $0.state == .produced || $0.state == .nothingDetected }
        let anyUnavailable = [angle.assessment, framing.assessment, positioning.assessment, depth.assessment]
            .contains { $0.status == .unavailable }

        let status: PhotoResultStatus
        if !ranAnything { status = .failed }
        else if problems.isEmpty && !anyUnavailable { status = .complete }
        else { status = .partial }

        return PhotoResult(
            id: prepared.id, selectionOrder: prepared.selectionOrder, localIdentifier: prepared.localIdentifier,
            preparation: record, status: status, evidence: evidence,
            cameraAngle: angle, subjectFraming: framing, subjectPositioning: positioning,
            environmentalDepth: depth, errors: problems, limitations: [])
    }

    /// Result for a photo that could not be read: every characteristic is
    /// unavailable, never defaulted.
    static func unreadable(_ prepared: PreparedPhoto, reason: String) -> PhotoResult {
        let assessment = Assessment.unavailable("This photo could not be analysed: \(reason)")
        return PhotoResult(
            id: prepared.id, selectionOrder: prepared.selectionOrder, localIdentifier: prepared.localIdentifier,
            preparation: nil, status: .failed, evidence: nil,
            cameraAngle: CameraAngleResult(category: .unknown, horizonCue: nil, headPitchDegrees: nil,
                                           headYawDegrees: nil, imageRollDegrees: nil, assessment: assessment),
            subjectFraming: SubjectFramingResult(category: .unknown, visibleExtent: nil, croppedEdges: [],
                                                 reliableLandmarkCount: 0, assessment: assessment),
            subjectPositioning: SubjectPositioningResult(
                subjectBox: nil, upperBodyBox: nil, center: nil, normalizedWidth: nil, normalizedHeight: nil,
                normalizedArea: nil, horizontal: nil, vertical: nil, detectionConfidence: nil,
                isMeasurementValid: false, touchedEdges: [],
                selection: SubjectSelectionInfo(detectedCount: 0, eligibleCount: 0, primaryCandidateID: nil, isAmbiguous: false),
                secondarySubjects: [], assessment: assessment),
            environmentalDepth: EnvironmentalDepthResult(structure: .unknown, metrics: nil, sceneBands: nil, assessment: assessment),
            errors: [reason], limitations: [])
    }
}
