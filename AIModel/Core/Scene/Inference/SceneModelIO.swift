//
//  SceneModelIO.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreML
import CoreVideo
import CoreGraphics
import Vision

/// Shared Core ML input/output plumbing for the scene models.
///
/// Inputs and outputs are discovered from the model description instead of
/// hard-coded feature names, so a model whose output is called "depth" or
/// "predictedDepth" works the same. Only the adapters in this folder use it.
nonisolated enum SceneModelIO {

    /// Wraps a CGImage as the model's (single) image input, scaled to the size
    /// the model declares.
    static func imageInput(for model: MLModel,
                           image: CGImage,
                           crop: VNImageCropAndScaleOption) throws -> MLFeatureProvider {
        guard let input = model.modelDescription.inputDescriptionsByName
                .first(where: { $0.value.type == .image }),
              let constraint = input.value.imageConstraint
        else { throw SceneModelError.unexpectedOutput("Model has no image input") }

        let value = try MLFeatureValue(
            cgImage: image,
            constraint: constraint,
            options: [.cropAndScale: NSNumber(value: crop.rawValue)]
        )
        return try MLDictionaryFeatureProvider(dictionary: [input.key: value])
    }

    /// The first output of the given type, by the model's declared output order.
    static func firstOutput(of type: MLFeatureType,
                            in output: MLFeatureProvider,
                            model: MLModel) -> MLFeatureValue? {
        for name in model.modelDescription.outputDescriptionsByName.keys.sorted() {
            if let value = output.featureValue(for: name), value.type == type { return value }
        }
        return nil
    }

    /// Reads the last two dimensions of a multi-array as a row-major Float grid.
    ///
    /// Honours the array's strides: Neural Engine outputs are often padded, so
    /// assuming a tightly packed buffer would read garbage. Leading dimensions
    /// (batch, channel) are expected to be 1.
    static func grid(from array: MLMultiArray) throws -> (width: Int, height: Int, values: [Float]) {
        let shape = array.shape.map { $0.intValue }
        let strides = array.strides.map { $0.intValue }
        guard shape.count >= 2 else {
            throw SceneModelError.unexpectedOutput("Multi-array shape \(shape)")
        }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        let rowStride = strides[strides.count - 2]
        let columnStride = strides[strides.count - 1]

        var values = [Float](repeating: 0, count: width * height)
        let base = array.dataPointer

        func fill<T>(_ type: T.Type, _ convert: (T) -> Float) {
            let pointer = base.assumingMemoryBound(to: T.self)
            for y in 0..<height {
                for x in 0..<width {
                    values[y * width + x] = convert(pointer[y * rowStride + x * columnStride])
                }
            }
        }

        switch array.dataType {
        case .int32:   fill(Int32.self) { Float($0) }
        case .float32: fill(Float.self) { $0 }
        case .float16: fill(Float16.self) { Float($0) }
        case .double:  fill(Double.self) { Float($0) }
        default:
            throw SceneModelError.unexpectedOutput("Multi-array data type \(array.dataType.rawValue)")
        }
        return (width, height, values)
    }

    /// Reads a one-channel Float16 or Float32 pixel buffer as a row-major Float grid.
    static func grid(from buffer: CVPixelBuffer) throws -> (width: Int, height: Int, values: [Float]) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SceneModelError.unexpectedOutput("Pixel buffer has no base address")
        }

        var values = [Float](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) }
            }
        case let other:
            throw SceneModelError.unexpectedOutput("Pixel format \(other)")
        }
        return (width, height, values)
    }
}