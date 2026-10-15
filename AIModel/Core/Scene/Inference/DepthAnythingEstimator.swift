//
//  DepthAnythingEstimator.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreML
import CoreGraphics
import Vision

/// Depth Anything V2 Small: relative depth for subject/background separation.
actor DepthAnythingEstimator: DepthEstimating {

    static let modelName = "DepthAnythingV2SmallF16P6"

    /// ⚠️ Depth Anything outputs relative INVERSE depth (larger = nearer).
    /// Check on device with a photo whose subject is clearly in front.
    private let largerIsNearer = true
    private var model: MLModel?

    func prepare() async throws {
        guard model == nil else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try await SceneModelLoader.load(Self.modelName, configuration: configuration)
    }

    func estimateDepth(_ image: CGImage) async throws -> DepthMap {
        try await prepare()
        guard let model else { throw SceneModelError.notLoaded("Depth") }

        let input = try SceneModelIO.imageInput(for: model, image: image, crop: .scaleFill)
        let output = try await model.prediction(from: input)

        // The model may declare its output as an image or as a multi-array.
        let grid: (width: Int, height: Int, values: [Float])
        if let buffer = SceneModelIO.firstOutput(of: .image, in: output, model: model)?.imageBufferValue {
            grid = try SceneModelIO.grid(from: buffer)
        } else if let array = SceneModelIO.firstOutput(of: .multiArray, in: output, model: model)?.multiArrayValue {
            grid = try SceneModelIO.grid(from: array)
        } else {
            throw SceneModelError.unexpectedOutput("Depth: no image or multi-array output")
        }

        return DepthMap.normalised(width: grid.width, height: grid.height,
                                   raw: grid.values, largerIsNearer: largerIsNearer)
    }
}