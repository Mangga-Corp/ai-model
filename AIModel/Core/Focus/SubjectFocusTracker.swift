//
//  SubjectFocusTracker.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//


import Foundation
import CoreGraphics

/// Decides WHEN and WHERE the camera should focus on the detected subject.
///
/// Pure logic, no AVFoundation: a subject box and a timestamp in, an optional
/// command out. Kept apart from the device code so the hysteresis is unit
/// testable on the simulator.
///
/// Why hysteresis: the detection box jitters by a few percent every frame.
/// Sending each jitter to the lens makes autofocus "hunt" (the picture pulses
/// in and out of focus). So the point is smoothed, and a new focus command is
/// sent only when the subject has really moved or changed distance, and never
/// more often than `minimumRefocusInterval`.
nonisolated struct SubjectFocusTracker: Sendable {

    enum Command: Equatable, Sendable {
        /// Focus and expose at this point (normalised view space, top-left).
        case focus(at: CGPoint)
        /// The subject is gone: go back to normal whole-frame autofocus.
        case releaseToAuto
    }

    /// How much of each new point is blended into the smoothed one (0...1).
    /// Lower is steadier but slower to follow.
    var smoothing: Double = 0.35

    /// Distance (in normalised units) the smoothed point must move from the
    /// last focused point before refocusing.
    var refocusDistance: Double = 0.06

    /// Relative change in box area (subject walking closer or away) that
    /// triggers a refocus even if the point barely moved. 0.25 = 25%.
    var refocusSizeChange: Double = 0.25

    /// Minimum seconds between two focus commands.
    var minimumRefocusInterval: TimeInterval = 0.5

    /// How long the subject may be missing before focus is released. Detection
    /// drops single frames now and then; releasing on each would hunt too.
    var lostSubjectGrace: TimeInterval = 1.0

    /// Where focus currently sits, for the on-screen indicator. Nil while not
    /// tracking a subject.
    private(set) var focusedPoint: CGPoint?

    /// True while focus is locked onto a subject.
    var isTracking: Bool { focusedPoint != nil }

    private var smoothedPoint: CGPoint?
    private var focusedArea: Double?
    private var lastCommandTime: TimeInterval?
    private var lastSeenTime: TimeInterval?

    /// Feeds one detection result.
    ///
    /// - Parameters:
    ///   - subjectBox: The detected box in normalised view space, or nil when
    ///     no subject was found on this frame.
    ///   - time: A monotonic timestamp in seconds.
    /// - Returns: A command to send to the camera, or nil to leave it as is.
    mutating func update(subjectBox: CGRect?, at time: TimeInterval) -> Command? {
        guard let box = subjectBox, box.width > 0, box.height > 0 else {
            return handleMissingSubject(at: time)
        }
        lastSeenTime = time

        let raw = Self.focusPoint(in: box)
        let smoothed: CGPoint
        if let previous = smoothedPoint {
            smoothed = CGPoint(
                x: previous.x + (raw.x - previous.x) * smoothing,
                y: previous.y + (raw.y - previous.y) * smoothing
            )
        } else {
            smoothed = raw
        }
        smoothedPoint = smoothed

        let area = Double(box.width * box.height)

        guard let focused = focusedPoint, let focusedArea else {
            // First sighting: focus straight away, like a tap.
            return commitFocus(at: smoothed, area: area, time: time)
        }

        if let lastCommandTime, time - lastCommandTime < minimumRefocusInterval {
            return nil
        }

        let moved = hypot(Double(smoothed.x - focused.x), Double(smoothed.y - focused.y))
        let sizeChange = focusedArea > 0 ? abs(area / focusedArea - 1) : 0

        guard moved >= refocusDistance || sizeChange >= refocusSizeChange else { return nil }
        return commitFocus(at: smoothed, area: area, time: time)
    }

    /// Forgets everything, e.g. when the camera stops.
    mutating func reset() {
        focusedPoint = nil
        smoothedPoint = nil
        focusedArea = nil
        lastCommandTime = nil
        lastSeenTime = nil
    }

    /// The point inside the subject box to focus on.
    ///
    /// The box is head-and-shoulders (`upperBodyOnly`), and the face sits in
    /// its upper part. Focusing there keeps the eyes sharpest, which is what
    /// makes a portrait read as "in focus"; the box centre would land on the
    /// chest.
    static func focusPoint(in box: CGRect) -> CGPoint {
        FocusPointConverter.clamped(
            CGPoint(x: box.midX, y: box.minY + box.height * 0.3)
        )
    }

    // MARK: - Private

    private mutating func commitFocus(at point: CGPoint, area: Double, time: TimeInterval) -> Command {
        focusedPoint = point
        focusedArea = area
        lastCommandTime = time
        return .focus(at: point)
    }

    private mutating func handleMissingSubject(at time: TimeInterval) -> Command? {
        guard isTracking else { return nil }
        if let lastSeenTime, time - lastSeenTime < lostSubjectGrace { return nil }
        reset()
        return .releaseToAuto
    }
}
