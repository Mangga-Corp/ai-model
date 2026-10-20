import Foundation
import CoreGraphics

/// Stage B + C for one photo: runs every source concurrently and returns the
/// evidence bundle plus the heavy grids. Nothing here interprets the evidence.
nonisolated enum EvidenceCollector {

    static func collect(from image: CGImage, models: AnalysisModels) async -> (PhotoEvidence, PhotoArtifacts) {
        async let vision = VisionEvidenceRunner.run(on: image)
        async let model = ModelEvidenceRunner.run(on: image, models: models)
        async let lines = VerticalLineExtractor.run(on: image)

        let v = await vision
        let m = await model
        let (verticalLines, lineRecord) = await lines

        let evidence = PhotoEvidence(
            humans: v.humans, pose: v.pose, faces: v.faces, imageRoll: v.imageRoll,
            segmentation: m.segmentation, depth: m.depth, sceneContext: m.sceneContext,
            runs: v.records + m.records + [lineRecord],
            verticalLines: verticalLines,
            bodyPose3D: v.bodyPose3D,
            cameraCalibration: m.cameraCalibration)
        return (evidence, m.artifacts)
    }
}
