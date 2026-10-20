import Foundation
import CoreGraphics
import Vision

/// Everything the Apple Vision requests produced for one image.
nonisolated struct VisionEvidenceBundle: Sendable {
    var humans: EvidenceOutcome<[HumanCandidate]>
    var pose: EvidenceOutcome<[PoseCandidate]>
    var faces: EvidenceOutcome<[FaceCandidate]>
    var imageRoll: EvidenceOutcome<ImageRollEvidence>
    var records: [SourceRunRecord]
    var bodyPose3D: EvidenceOutcome<[BodyPose3DCandidate]> = .skipped("not run")
}

/// Stage B/C for Apple Vision: runs the requests and converts their raw
/// observations into image-space evidence (top-left origin, see `ImageSpace`).
///
/// Requests receive the already-upright analysis image, so no orientation
/// parameter is needed anywhere. Each request fails independently.
nonisolated enum VisionEvidenceRunner {

    static func run(on image: CGImage) async -> VisionEvidenceBundle {
        async let humans = timed(.visionHumanRectangles) { await detectHumans(in: image) }
        async let pose = timed(.visionBodyPose) { await detectPose(in: image) }
        async let faces = timed(.visionFaceRectangles) { await detectFaces(in: image) }
        async let roll = timed(.visionHorizon) { await detectImageRoll(in: image) }
        async let pose3D = timed(.visionBodyPose3D) { BodyPose3DRunner.detect(in: image) }

        let (h, hr) = await humans
        let (p, pr) = await pose
        let (f, fr) = await faces
        let (r, rr) = await roll
        let (p3, p3r) = await pose3D
        return VisionEvidenceBundle(humans: h, pose: p, faces: f, imageRoll: r,
                                    records: [hr, pr, fr, rr, p3r], bodyPose3D: p3)
    }

    // MARK: Humans

    private static func detectHumans(in image: CGImage) async -> (EvidenceOutcome<[HumanCandidate]>, String) {
        let fullRequest: DetectHumanRectanglesRequest = {
            var request = DetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            return request
        }()
        let upperRequest: DetectHumanRectanglesRequest = {
            var request = DetectHumanRectanglesRequest()
            request.upperBodyOnly = true
            return request
        }()

        do {
            async let fullObservations = fullRequest.perform(on: image)
            async let upperObservations = upperRequest.perform(on: image)
            let full = try await fullObservations
            // An upper-body failure must not discard valid full-body detections.
            let upper = (try? await upperObservations) ?? []

            let uppers = upper.map { (box: visionRect($0.boundingBox), confidence: Double($0.confidence)) }
            var used = Set<Int>()
            var candidates: [HumanCandidate] = []

            for (index, observation) in full.enumerated() {
                let box = visionRect(observation.boundingBox)
                var best: (index: Int, containment: Double)?
                for (j, u) in uppers.enumerated() where !used.contains(j) {
                    let containment = ImageSpace.containment(of: u.box, in: box)
                    if containment >= 0.7, containment > (best?.containment ?? 0) { best = (j, containment) }
                }
                if let best { used.insert(best.index) }
                candidates.append(HumanCandidate(
                    id: index, box: box, confidence: Double(observation.confidence),
                    upperBodyBox: best.map { uppers[$0.index].box },
                    upperBodyConfidence: best.map { uppers[$0.index].confidence }))
            }

            if candidates.isEmpty { return (.nothingDetected, "no people detected") }
            return (.produced(candidates), "\(candidates.count) person box(es)")
        } catch {
            return (.failed(error.localizedDescription), "request failed")
        }
    }

    // MARK: Body pose

    private static func detectPose(in image: CGImage) async -> (EvidenceOutcome<[PoseCandidate]>, String) {
        do {
            let observations = try await DetectHumanBodyPoseRequest().perform(on: image)
            let poses = observations.map { observation -> PoseCandidate in
                let landmarks = observation.allJoints().map { name, joint in
                    BodyLandmark(joint: bodyJoint(name),
                                 point: ImageSpace.point(fromVisionX: Double(joint.location.x),
                                                         y: Double(joint.location.y)),
                                 confidence: Double(joint.confidence))
                }.sorted { $0.joint.rawValue < $1.joint.rawValue }
                return PoseCandidate(landmarks: landmarks, observationConfidence: Double(observation.confidence))
            }
            if poses.isEmpty { return (.nothingDetected, "no body pose detected") }
            return (.produced(poses), "\(poses.count) pose(s)")
        } catch {
            return (.failed(error.localizedDescription), "request failed")
        }
    }

    // MARK: Faces

    private static func detectFaces(in image: CGImage) async -> (EvidenceOutcome<[FaceCandidate]>, String) {
        do {
            let observations = try await DetectFaceRectanglesRequest().perform(on: image)
            let faces = observations.map { o in
                FaceCandidate(box: visionRect(o.boundingBox),
                              confidence: Double(o.confidence),
                              rollDegrees: o.roll.converted(to: .degrees).value,
                              yawDegrees: o.yaw.converted(to: .degrees).value,
                              pitchDegrees: o.pitch.converted(to: .degrees).value)
            }
            if faces.isEmpty { return (.nothingDetected, "no faces detected") }
            return (.produced(faces), "\(faces.count) face(s)")
        } catch {
            return (.failed(error.localizedDescription), "request failed")
        }
    }

    // MARK: Image roll

    private static func detectImageRoll(in image: CGImage) async -> (EvidenceOutcome<ImageRollEvidence>, String) {
        do {
            guard let observation = try await DetectHorizonRequest().perform(on: image) else {
                return (.nothingDetected, "no horizon detected")
            }
            let degrees = observation.angle.converted(to: .degrees).value
            return (.produced(ImageRollEvidence(angleDegrees: degrees, confidence: Double(observation.confidence))),
                    String(format: "roll %.1f deg", degrees))
        } catch {
            return (.failed(error.localizedDescription), "request failed")
        }
    }

    // MARK: Helpers

    private static func visionRect(_ r: NormalizedRect) -> CGRect {
        ImageSpace.clamped(ImageSpace.rect(fromVisionX: Double(r.origin.x), y: Double(r.origin.y),
                                           width: Double(r.width), height: Double(r.height)))
    }

    private static func bodyJoint(_ name: HumanBodyPoseObservation.JointName) -> BodyJoint {
        switch name {
        case .nose: return .nose
        case .leftEye: return .leftEye
        case .rightEye: return .rightEye
        case .leftEar: return .leftEar
        case .rightEar: return .rightEar
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .root: return .root
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        @unknown default: return .root
        }
    }

    private static func timed<V>(
        _ source: EvidenceSource,
        _ body: () async -> (EvidenceOutcome<V>, String)
    ) async -> (EvidenceOutcome<V>, SourceRunRecord) {
        let start = ContinuousClock.now
        let (outcome, detail) = await body()
        let state: SourceRunRecord.State
        switch outcome {
        case .produced: state = .produced
        case .nothingDetected: state = .nothingDetected
        case .failed: state = .failed
        case .skipped: state = .skipped
        }
        return (outcome, SourceRunRecord(source: source, state: state,
                                         durationMilliseconds: start.elapsedMilliseconds,
                                         detail: outcome.problem ?? detail))
    }
}

extension ContinuousClock.Instant {
    nonisolated var elapsedMilliseconds: Int {
        let d = self.duration(to: .now)
        return Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}
