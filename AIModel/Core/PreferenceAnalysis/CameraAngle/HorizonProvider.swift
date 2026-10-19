import Foundation
import CoreGraphics

/// Provider: a visible horizon versus the subject's eye line. DECISIVE when valid.
///
/// Physics: a point at the same height as the camera always projects onto the
/// horizon line, whatever the camera's tilt. So the horizon's position
/// relative to the eyes tells whether the eyes are above, level with or below
/// the camera. Converting that offset into an angle needs the (unknown) focal
/// length, which `LensModel` carries as an interval.
///
/// The offset between horizon and eyes is also unaffected, to first order, by
/// vertical cropping, which makes this the most robust provider.
///
/// Absence of a horizon is the ordinary case (rooms, streets, woods). It makes
/// this provider `notApplicable`; it does not make the whole result unknown.
nonisolated enum HorizonProvider {

    static func observe(anchor: SubjectAnchor?,
                        segmentation: SegmentationGrid?,
                        segmentationProblem: String?,
                        imageRollDegrees: Double?,
                        aspect: Double,
                        imageSize: CGSize?) -> (observation: CameraAngleObservation, cue: HorizonEyeCue?) {

        guard let segmentation else {
            return (.unavailable(.horizonLine, .decisive,
                                 .invalid("Segmentation was unavailable" + (segmentationProblem.map { ": \($0)" } ?? ".")),
                                 summary: "No horizon search was possible because segmentation did not run."), nil)
        }
        guard let horizon = HorizonLineFitter.fit(segmentation) else {
            return (.unavailable(.horizonLine, .decisive,
                                 .notApplicable("No straight line where the sky meets open water or flat ground is visible."),
                                 summary: "No horizon is visible in this photo."), nil)
        }
        guard let anchor else {
            return (.unavailable(.horizonLine, .decisive,
                                 .invalid("The subject's eye line could not be located."),
                                 summary: "A horizon was found, but there is no eye line to compare it with."), nil)
        }

        let eyeY = Double(anchor.eyePoint.y)
        let horizonY = horizon.y(atX: Double(anchor.eyePoint.x))

        let elevation = LensModel.interval(aspect: aspect) { f in
            [CameraGeometry.elevation(pitchDownDegrees: CameraGeometry.pitchDown(horizonY: horizonY, f: f), eyeY: eyeY, f: f)]
        }
        let pitch = LensModel.interval(aspect: aspect) { f in [CameraGeometry.pitchDown(horizonY: horizonY, f: f)] }

        // Quality from explicit checks.
        var quality: EvidenceQuality = .high
        var limitations: [String] = []
        if !horizon.isOpenWater {
            quality = quality.lowered()
            limitations.append("The horizon is flat ground meeting the sky, which only approximates the true horizon.")
        }
        if horizon.residualRMS > 0.008 || horizon.columnCoverage < 0.5 {
            quality = quality.lowered()
            limitations.append("The fitted horizon covers limited width or is not perfectly straight.")
        }
        if anchor.isEstimated {
            quality = quality.lowered()
            limitations.append("The eye line was estimated from the face rectangle.")
        }
        if let conf = anchor.faceConfidence, conf < 0.5 {
            quality = quality.lowered()
            limitations.append("Face detection confidence is low.")
        }
        if let roll = imageRollDegrees, let size = imageSize, size.width > 0, size.height > 0 {
            let fitted = CameraGeometry.degrees(atan(horizon.slope * Double(size.height / size.width)))
            if abs(abs(roll) - abs(fitted)) > 6 {
                quality = quality.lowered()
                limitations.append(String(format: "Vision's image roll (%.1f°) disagrees with the fitted horizon (%.1f°).", roll, fitted))
            }
        }

        let offset = eyeY - horizonY
        let offsetInHeads = anchor.headHeight.map { offset / $0 }
        let cue = HorizonEyeCue(horizon: horizon, eyePoint: anchor.eyePoint, eyeSource: anchor.eyeSource,
                                headHeight: anchor.headHeight, offsetInImageHeights: offset,
                                offsetInHeadHeights: offsetInHeads)

        // Observation only; the verdict belongs to the fusion.
        let summary: String
        if offset > 0.03 { summary = "The horizon runs above the subject's eyes in the image." }
        else if offset < -0.03 { summary = "The horizon runs below the subject's eyes in the image." }
        else { summary = "The horizon passes close to the subject's eye line." }

        var measurements = [
            ObservationMeasurement(label: "Horizon surface", value: horizon.lowerRegionLabel),
            ObservationMeasurement(label: "Eyes relative to horizon", value: String(format: "%+.0f%% of image height", offset * 100)),
            ObservationMeasurement(label: "Horizon fit", value: String(format: "residual %.4f over %.0f%% of the width", horizon.residualRMS, horizon.columnCoverage * 100))
        ]
        if let offsetInHeads { measurements.insert(.init(label: "Eyes relative to horizon (head-heights)", value: String(format: "%+.1f", offsetInHeads)), at: 1) }

        return (CameraAngleObservation(
            provider: .horizonLine, role: .decisive, validity: .valid, elevation: elevation, pitchDown: pitch,
            tiltHint: nil, quality: quality, summary: summary, measurements: measurements, limitations: limitations), cue)
    }
}
