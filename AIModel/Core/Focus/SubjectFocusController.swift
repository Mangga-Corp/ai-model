//
//  SubjectFocusController.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//


import Foundation
import CoreGraphics
import AVFoundation

/// Applies focus and exposure commands to the capture device.
///
/// Runs on its own serial queue: `lockForConfiguration()` can block briefly,
/// and it must never stall the main thread or the video queue. The lock is
/// held only for the few property writes, then released.
///
/// Every capability is checked before use. Devices without a focus point of
/// interest (some front cameras, older phones' telephoto lenses) still get the
/// exposure part, and anything unsupported is skipped silently, which leaves
/// the camera on its normal autofocus.
nonisolated final class SubjectFocusController: @unchecked Sendable {

    private let device: AVCaptureDevice
    private let queue = DispatchQueue(label: "com.aimodel.camera.focus")

    init(device: AVCaptureDevice) {
        self.device = device
    }

    /// True when the lens can focus on a chosen point. When false the on-screen
    /// indicator should not claim focus is on the subject.
    var supportsFocusPoint: Bool { device.isFocusPointOfInterestSupported }

    /// Focuses and exposes on a point in DEVICE space (see `FocusPointConverter`).
    ///
    /// Continuous autofocus AT the point, not a one-shot lock: the subject
    /// moves and changes distance, and continuous mode keeps re-measuring at
    /// that spot by itself between our (deliberately rare) point updates.
    func focus(atDevicePoint point: CGPoint) {
        let point = FocusPointConverter.clamped(point)
        queue.async { [self] in
            Self.configure(device) {
                // Face-driven autofocus would pull focus to whichever face it
                // prefers, possibly not our subject. Turned off while tracking.
                if device.automaticallyAdjustsFaceDrivenAutoFocusEnabled {
                    device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
                }
                if device.isFaceDrivenAutoFocusEnabled {
                    device.isFaceDrivenAutoFocusEnabled = false
                }
                // Same for exposure: a face elsewhere in the frame would
                // otherwise set the brightness.
                if device.automaticallyAdjustsFaceDrivenAutoExposureEnabled {
                    device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
                }
                if device.isFaceDrivenAutoExposureEnabled {
                    device.isFaceDrivenAutoExposureEnabled = false
                }

                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .continuousAutoFocus
                }

                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }

                // Smooth focus changes look like video; for stills a fast
                // snap to the subject is better.
                if device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = false
                }

                // We drive the point ourselves, so the camera should not reset
                // it when the scene changes.
                device.isSubjectAreaChangeMonitoringEnabled = false
            }
        }
    }

    /// Returns to the camera's normal behaviour: centre-weighted continuous
    /// autofocus and exposure, with face detection back on automatic.
    func releaseToAuto() {
        queue.async { [self] in
            Self.configure(device) {
                let centre = CGPoint(x: 0.5, y: 0.5)

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = centre
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }

                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = centre
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }

                device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = true
                device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = true
            }
        }
    }

    /// Locks, applies, unlocks. A failed lock (another client holds the
    /// device) skips the change rather than crashing; the next command retries.
    private static func configure(_ device: AVCaptureDevice, _ changes: () -> Void) {
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        changes()
        device.unlockForConfiguration()
    }
}
