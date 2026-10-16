//
//  FocusPointConverter.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//


import Foundation
import CoreGraphics
import AVFoundation

/// Converts a point from the app's normalised view space into the coordinate
/// space `AVCaptureDevice.focusPointOfInterest` and
/// `exposurePointOfInterest` expect.
///
/// The two spaces differ in orientation:
/// - **View space** (what `subjectBox` uses): 0...1, origin top-left, in the
///   frame AS DELIVERED by the video connection, i.e. already rotated to the
///   connection's `videoOrientation`.
/// - **Device space**: 0...1, origin top-left of the RAW sensor image, which
///   is always landscape with the home button / USB port on the right
///   (`.landscapeRight`), whatever way the phone is held.
///
/// Working from the frame instead of the preview layer means the preview's
/// `resizeAspectFill` crop never enters the maths: the subject box and the
/// focus point both live in the same frame.
nonisolated enum FocusPointConverter {

    /// - Parameters:
    ///   - viewPoint: Normalised point in the oriented frame, origin top-left.
    ///   - orientation: The video connection's `videoOrientation` when the
    ///     frame was captured.
    ///   - isMirrored: True for a mirrored (front camera) connection. The back
    ///     camera is never mirrored.
    static func devicePoint(fromViewPoint viewPoint: CGPoint,
                            orientation: AVCaptureVideoOrientation,
                            isMirrored: Bool = false) -> CGPoint {
        // Undo mirroring first: mirroring happens after rotation, horizontally
        // in the oriented frame.
        let x = isMirrored ? 1 - viewPoint.x : viewPoint.x
        let y = viewPoint.y

        let converted: CGPoint
        switch orientation {
        case .landscapeRight:
            // Same as the sensor.
            converted = CGPoint(x: x, y: y)
        case .portrait:
            // The oriented frame is the sensor turned 90°: the top of the
            // portrait frame is the sensor's left edge.
            converted = CGPoint(x: y, y: 1 - x)
        case .portraitUpsideDown:
            converted = CGPoint(x: 1 - y, y: x)
        case .landscapeLeft:
            // Sensor turned 180°.
            converted = CGPoint(x: 1 - x, y: 1 - y)
        @unknown default:
            converted = CGPoint(x: y, y: 1 - x)
        }

        return clamped(converted)
    }

    /// Keeps a point inside 0...1 — AVFoundation throws an Objective-C
    /// exception (a crash, not an error) for points outside the unit square.
    static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}
