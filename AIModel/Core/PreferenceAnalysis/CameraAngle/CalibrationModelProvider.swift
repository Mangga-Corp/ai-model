//
//  CalibrationModelProvider.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//


import Foundation
import CoreGraphics

/// Provider: the app's own viewpoint model (`CameraCalibration.mlpackage`). DECISIVE when valid.
///
/// The model reads the camera's tilt (pitch) and lens (focal length) from the whole
/// picture: horizon, background lines, perspective of floors and tables. The angle to
/// the subject then follows from the same geometry as every other provider:
///
///      elevation (camera above eyes) = - pitch up + atan((eyeY - 0.5) / f)
///
/// Unlike the horizon and vertical-line providers it does not need one specific cue
/// to be visible, so it can also judge indoor photos and plain backgrounds, as far as
/// its training lets it.
///
/// UNCERTAINTY POLICY
///  - The model reports its own uncertainty (sigma) for pitch and focal length. The
///    likely interval spans 2 sigma, the extended interval 3 sigma, so a model that is
///    unsure cannot decide a category; above `maximumPitchSigma` it is not used at all.
///  - A focal length from the photo's EXIF is preferred over the model's estimate.
///  - The eye offset carries the same crop allowance as the vertical-line provider.
///  - Quality is capped at MODERATE: it is a learned estimate, and its accuracy on
///    this app's photos is only known from the validation numbers of its training.
nonisolated enum CalibrationModelProvider {

    /// Above this pitch uncertainty the model's answer is not used.
    static let maximumPitchSigma = 10.0
    /// Roll is reported for the Dutch angle only when the model is at least this sure.
    static let maximumRollSigma = 5.0
    static let levelToleranceDegrees = 3.0

    nonisolated struct Output: Sendable, Equatable {
        let observation: CameraAngleObservation
        /// The camera's roll, when the model is sure enough of it to describe a Dutch angle.
        let rollDegrees: Double?
    }

    static func observe(calibration: EvidenceOutcome<CameraCalibrationEstimate>,
                        anchor: SubjectAnchor?,
                        aspect: Double,
                        cropAllowance: Double,
                        lens: LensAssumption = .unknown) -> Output {
        func none(_ validity: ProviderValidity, _ summary: String, roll: Double? = nil) -> Output {
            Output(observation: .unavailable(.viewpointModel, .decisive, validity, summary: summary), rollDegrees: roll)
        }

        let e: CameraCalibrationEstimate
        switch calibration {
        case .produced(let value): e = value
        case .nothingDetected:
            return none(.notApplicable("The viewpoint model returned nothing."), "The viewpoint model gave no estimate.")
        case .skipped(let m):
            return none(.notApplicable(m), "The viewpoint model is not installed.")
        case .failed(let m):
            return none(.invalid("The viewpoint model did not run: \(m)"), "The viewpoint model was not available.")
        }

        let roll = e.rollSigmaDegrees <= maximumRollSigma ? e.rollDegrees : nil
        guard e.pitchSigmaDegrees <= maximumPitchSigma else {
            return none(.invalid(String(format: "The viewpoint model is unsure of the camera tilt (± %.0f°).", e.pitchSigmaDegrees)),
                        "The viewpoint model could not read the camera tilt from this photo.", roll: roll)
        }
        guard let anchor else {
            return none(.invalid("The subject's eye line could not be located."),
                        "The viewpoint model estimated the camera tilt, but there is no eye line to compare it with.", roll: roll)
        }

        // Focal lengths to try: the photo's own lens when known, otherwise the model's, with its error bars.
        func focals(_ k: Double) -> [Double] {
            if lens.isKnown {
                let mms = k <= 2 ? lens.likelyMM : lens.extendedMM
                return [LensModel.focalLength(equivalentMM: lens.nominalMM, aspect: aspect)]
                    + mms.map { LensModel.focalLength(equivalentMM: $0, aspect: aspect) }
            }
            return [e.focalLength, e.focalLength * exp(-k * e.focalLogSigma), e.focalLength * exp(k * e.focalLogSigma)]
        }
        let eyeY = Double(anchor.eyePoint.y)

        /// Elevations for every combination of pitch, focal length and crop at k sigma.
        func elevations(_ k: Double) -> [Double] {
            var values: [Double] = []
            for pitch in [e.pitchUpDegrees, e.pitchUpDegrees - k * e.pitchSigmaDegrees, e.pitchUpDegrees + k * e.pitchSigmaDegrees] {
                for f in focals(k) {
                    for shift in [0, -cropAllowance, cropAllowance] {
                        values.append(CameraGeometry.elevation(pitchDownDegrees: -pitch, eyeY: eyeY + shift, f: f))
                    }
                }
            }
            return values
        }
        let likely = elevations(2), extended = elevations(3)
        let elevation = AngleInterval(nominal: likely[0],
                                      likelyLow: likely.min()!, likelyHigh: likely.max()!,
                                      extendedLow: extended.min()!, extendedHigh: extended.max()!)
        let pitchDown = AngleInterval(nominal: -e.pitchUpDegrees,
                                      likelyLow: -e.pitchUpDegrees - 2 * e.pitchSigmaDegrees,
                                      likelyHigh: -e.pitchUpDegrees + 2 * e.pitchSigmaDegrees,
                                      extendedLow: -e.pitchUpDegrees - 3 * e.pitchSigmaDegrees,
                                      extendedHigh: -e.pitchUpDegrees + 3 * e.pitchSigmaDegrees)

        var quality: EvidenceQuality = e.pitchSigmaDegrees <= 4 ? .moderate : .low
        var limitations = ["The viewpoint model is a learned estimate; it can be wrong on scenes unlike its training photos."]
        if !lens.isKnown {
            limitations.append("The lens was estimated by the model because the photo has no lens metadata.")
        }
        if anchor.isEstimated {
            quality = quality.lowered()
            limitations.append("The eye line was estimated from the face rectangle.")
        }
        if elevation.likelyHigh - elevation.likelyLow > 16 {
            quality = quality.lowered()
            limitations.append("The model's uncertainty leaves a wide range of possible angles.")
        }

        let tilt: CameraTilt = e.pitchUpDegrees > levelToleranceDegrees ? .up
            : (e.pitchUpDegrees < -levelToleranceDegrees ? .down : .level)
        let tiltClause: String
        switch tilt {
        case .up: tiltClause = "The viewpoint model sees the camera tilted up"
        case .down: tiltClause = "The viewpoint model sees the camera tilted down"
        case .level: tiltClause = "The viewpoint model sees the camera held close to level"
        }
        let offset = eyeY - 0.5
        let eyesClause = offset < -0.04 ? "the subject's eyes sit above the image center"
            : (offset > 0.04 ? "the subject's eyes sit below the image center" : "the subject's eyes sit near the image center")

        let usedFocal = focals(2)[0]
        let mm = usedFocal / (1 + aspect * aspect).squareRoot() * LensModel.fullFrameDiagonal
        let measurements = [
            ObservationMeasurement(label: "Camera tilt", value: String(format: "%+.0f° ± %.0f° (up +)", e.pitchUpDegrees, e.pitchSigmaDegrees)),
            ObservationMeasurement(label: "Camera roll", value: String(format: "%+.0f° ± %.0f°", e.rollDegrees, e.rollSigmaDegrees)),
            ObservationMeasurement(label: "Lens", value: String(format: "about %.0f mm equivalent (%@)", mm,
                                                                lens.isKnown ? "photo metadata" : "model estimate")),
            ObservationMeasurement(label: "Elevation to the eyes", value: String(format: "%+.0f° (%+.0f° to %+.0f°)",
                                                                                 elevation.nominal, elevation.likelyLow, elevation.likelyHigh)),
        ]

        let observation = CameraAngleObservation(
            provider: .viewpointModel, role: .decisive, validity: .valid,
            elevation: elevation, pitchDown: pitchDown, tiltHint: tilt, quality: quality,
            summary: "\(tiltClause), and \(eyesClause).", measurements: measurements, limitations: limitations)
        return Output(observation: observation, rollDegrees: roll)
    }
}
