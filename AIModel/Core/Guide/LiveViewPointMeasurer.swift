//
//  LiveViewPointMeasurer.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//

import Foundation
import CoreGraphics

/// Where the live camera is relative to the subject, measured from sensors and
/// geometry. No learned model is involved.
nonisolated struct LiveViewpoint: Equatable, Sendable {
    /// Camera pitch, degrees, positive = tilted UP (Core Motion).
    let pitch: Double
    /// Picture roll, degrees, positive = clockwise; nil when unreliable.
    let roll: Double?
    let dutchAngle: DutchAngleCategory

    /// Camera elevation relative to the subject's eyes, degrees (positive =
    /// camera above the eyes). Nil without a subject.
    let elevation: Double?
    let angle: CameraAngleCategory
    /// Where the camera's own height crosses the frame (image space, 0 = top).
    let horizonY: Double
    let heightLevel: CameraHeightLevel
    /// True when the eye line was estimated from the upper-body box rather than
    /// measured from eye joints.
    let eyeIsEstimated: Bool
}

/// Turns the phone's attitude, the lens's field of view and the subject's joints
/// into a `LiveViewpoint`.
///
/// GEOMETRY (pinhole camera, principal point at the frame centre):
///  - `f`, the focal length in frame-height units, comes from the active
///    format's horizontal field of view (measured along the sensor's long side)
///    and the zoom factor. Unlike reference photos, the live lens is KNOWN.
///  - Elevation to the eyes = pitch-down + atan((eyeY − 0.5) / f), the same
///    formula the reference-photo analysis uses (`CameraGeometry.elevation`).
///    It does not change when the phone is only rotated in place: tilting moves
///    the eyes in the frame by exactly the tilt. Only moving the phone changes it.
///  - The camera's own height projects onto y = 0.5 + f · tan(pitch-up); the
///    body part at that row is the part the camera is level with.
///
/// LIMITS, stated plainly: the subject is assumed upright and roughly level with
/// the photographer's ground; roll is ignored for the height row (small rolls
/// move it little near the centre); without eye joints the eye line is estimated
/// from the upper-body box and flagged.
nonisolated enum LiveViewpointMeasurer {

    /// Eye line within an upper-body (head-and-shoulders) box, as a share of the
    /// box height from its top. Only used when no eye joint is visible.
    static let estimatedEyeShareOfUpperBody = 0.18

    /// Focal length in frame-height units.
    ///
    /// - Parameters:
    ///   - horizontalFOVDegrees: `AVCaptureDevice.Format.videoFieldOfView` (long side).
    ///   - zoomFactor: `AVCaptureDevice.videoZoomFactor`.
    ///   - frameSize: the upright frame's pixel size.
    static func focalLength(horizontalFOVDegrees fov: Double, zoomFactor: Double,
                            frameSize: CGSize) -> Double? {
        let w = Double(frameSize.width), h = Double(frameSize.height)
        guard fov > 1, fov < 179, zoomFactor > 0, w > 0, h > 0 else { return nil }
        let longSide = max(w, h)
        let fLong = 0.5 / tan(fov * .pi / 360)   // in long-side units
        return fLong * zoomFactor * longSide / h
    }

    static func measure(attitude: DeviceAttitude,
                        focalLength f: Double,
                        joints: SubjectJointHeights?,
                        upperBodyBox: CGRect?) -> LiveViewpoint {
        let roll = attitude.isRollReliable ? attitude.roll : nil
        let horizonY = 0.5 + f * tan(attitude.pitch * .pi / 180)

        var eyeY = joints?.eyeY
        var estimated = false
        if eyeY == nil, let box = upperBodyBox {
            eyeY = Double(box.minY) + Double(box.height) * estimatedEyeShareOfUpperBody
            estimated = true
        }

        let elevation = eyeY.map { CameraGeometry.elevation(pitchDownDegrees: -attitude.pitch, eyeY: $0, f: f) }
        var heights = joints ?? SubjectJointHeights()
        if heights.eyeY == nil { heights.eyeY = eyeY }

        return LiveViewpoint(
            pitch: attitude.pitch,
            roll: roll,
            dutchAngle: DutchAngleRule.category(rollDegrees: roll),
            elevation: elevation,
            angle: elevation.map(CameraAngleRule.category(ofElevation:)) ?? .unknown,
            horizonY: horizonY,
            heightLevel: CameraHeightLevelRule.level(horizonY: horizonY, joints: heights),
            eyeIsEstimated: estimated)
    }
}
