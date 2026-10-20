//
//  ViewpointCaptureRecorder.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//

import Foundation
import UIKit

/// The sensor readings behind one capture: a labelled example for training a
/// viewpoint model later. Every label here was MEASURED (Core Motion, the known
/// lens, Vision joints), which is exactly what reference photos lack.
nonisolated struct ViewpointCaptureRecord: Codable, Sendable, Equatable {
    var schemaVersion = 1
    let capturedAt: Date
    let frameWidth: Int
    let frameHeight: Int
    /// Active format field of view along the sensor's long side, degrees.
    let horizontalFOVDegrees: Double?
    let zoomFactor: Double
    /// Focal length in frame-height units, as used for the angles below.
    let focalLength: Double?
    /// Degrees, positive = tilted up.
    let pitch: Double
    /// Degrees, positive = clockwise; nil when the phone pointed straight up or down.
    let roll: Double?
    /// Camera elevation relative to the subject's eyes, degrees (camera above positive).
    let elevation: Double?
    let angle: String
    let heightLevel: String
    let dutchAngle: String
    let eyeIsEstimated: Bool
    /// Frame space (0 = top) heights of the subject's joints.
    let eyeY: Double?
    let shoulderY: Double?
    let hipY: Double?
    let kneeY: Double?
    let ankleY: Double?
    /// Upper-body box, frame space: x, y, width, height.
    let subjectBox: [Double]?
}

/// Saves capture records (JSON) and their photos (JPEG) in the app's own
/// Documents/ViewpointCaptures folder. Nothing leaves the device. Only runs
/// when the user turned "Save capture data" on.
nonisolated enum ViewpointCaptureRecorder {

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ViewpointCaptures", isDirectory: true)
    }

    /// Writes off the calling thread; failures are ignored (this is optional data).
    static func save(_ record: ViewpointCaptureRecord, image: UIImage?) {
        let jpeg = image?.jpegData(compressionQuality: 0.9)
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = UUID().uuidString
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(record).write(to: folder.appendingPathComponent(name + ".json"))
                if let jpeg { try jpeg.write(to: folder.appendingPathComponent(name + ".jpg")) }
            } catch {
                // Optional training data: a failed write must never disturb capture.
            }
        }
    }

    static func makeRecord(viewpoint: LiveViewpoint, joints: SubjectJointHeights?, subjectBox: CGRect?,
                           frameSize: CGSize, horizontalFOV: Double?, zoomFactor: Double,
                           focalLength: Double?) -> ViewpointCaptureRecord {
        ViewpointCaptureRecord(
            capturedAt: Date(),
            frameWidth: Int(frameSize.width), frameHeight: Int(frameSize.height),
            horizontalFOVDegrees: horizontalFOV, zoomFactor: zoomFactor, focalLength: focalLength,
            pitch: viewpoint.pitch, roll: viewpoint.roll, elevation: viewpoint.elevation,
            angle: viewpoint.angle.rawValue, heightLevel: viewpoint.heightLevel.rawValue,
            dutchAngle: viewpoint.dutchAngle.rawValue, eyeIsEstimated: viewpoint.eyeIsEstimated,
            eyeY: joints?.eyeY, shoulderY: joints?.shoulderY, hipY: joints?.hipY,
            kneeY: joints?.kneeY, ankleY: joints?.ankleY,
            subjectBox: subjectBox.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] })
    }
}
