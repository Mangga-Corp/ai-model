//
//  BodyPose3DRunner.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//


import Foundation
import CoreGraphics
import Vision
import simd

/// Runs Vision's 3D human body pose (iOS 17+) and keeps what the camera-angle
/// analysis needs: joint heights and the camera's position, both in metres in
/// the body's own frame.
///
/// Uses the `VN` request API, which exposes `cameraOriginMatrix` (the camera's
/// pose relative to the root joint) on every observation.
nonisolated enum BodyPose3DRunner {

    static func detect(in image: CGImage) -> (EvidenceOutcome<[BodyPose3DCandidate]>, String) {
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (.failed(error.localizedDescription), "request failed")
        }
        let candidates = (request.results ?? []).compactMap(candidate)
        if candidates.isEmpty { return (.nothingDetected, "no 3D body pose detected") }
        return (.produced(candidates), "\(candidates.count) 3D pose(s)")
    }

    private static func candidate(_ o: VNHumanBodyPose3DObservation) -> BodyPose3DCandidate? {
        func position(_ joint: VNHumanBodyPose3DObservation.JointName) -> SIMD3<Double>? {
            guard let point = try? o.recognizedPoint(joint) else { return nil }
            let t = point.position.columns.3
            return SIMD3(Double(t.x), Double(t.y), Double(t.z))
        }
        func pairY(_ a: VNHumanBodyPose3DObservation.JointName, _ b: VNHumanBodyPose3DObservation.JointName) -> Double? {
            let ys = [position(a), position(b)].compactMap { $0?.y }
            return ys.isEmpty ? nil : ys.reduce(0, +) / Double(ys.count)
        }

        guard let head = position(.centerHead) else { return nil }
        let camera = o.cameraOriginMatrix.columns.3
        let headPoint = try? o.pointInImage(.centerHead)

        return BodyPose3DCandidate(
            headInImage: headPoint.map { ImageSpace.point(fromVisionX: Double($0.x), y: Double($0.y)) },
            headX: head.x, headY: head.y, headZ: head.z,
            shoulderY: pairY(.leftShoulder, .rightShoulder) ?? position(.centerShoulder)?.y,
            hipY: pairY(.leftHip, .rightHip) ?? position(.root)?.y,
            kneeY: pairY(.leftKnee, .rightKnee),
            ankleY: pairY(.leftAnkle, .rightAnkle),
            cameraX: Double(camera.x), cameraY: Double(camera.y), cameraZ: Double(camera.z),
            bodyHeight: Double(o.bodyHeight),
            isHeightMeasured: o.heightEstimation == .measured,
            confidence: Double(o.confidence))
    }
}
