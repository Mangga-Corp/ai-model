import Foundation
import CoreML
import CoreGraphics
import Vision

/// The app's own viewpoint model (`CameraCalibration.mlpackage`, trained with
/// `ai-model-training/`): from one photo it estimates the camera's pitch, roll and
/// focal length, each with an uncertainty.
///
/// Contract (from `export_coreml.py`):
///   - input  `image`: RGB 320x320, the photo LETTERBOXED onto black (proportions
///     kept, centred), pixels 0...255. Normalisation happens inside the model.
///   - output `calibration`: six numbers
///     [pitch_deg (up +), roll_deg (clockwise +), focal_square,
///      pitch_sigma_deg, roll_sigma_deg, focal_log_sigma]
///     `focal_square` is the focal length in units of the 320 px square; divide it
///     by the photo's height on the square (as a fraction of 320) for the photo's own.
///
/// The model is optional: when the package is not in the app, the source is
/// reported as skipped and every other provider works as before. A newer
/// (fine-tuned) export with the same contract replaces the file without code changes.
actor CameraCalibrationModel {

    static let modelName = "CameraCalibration"
    static let inputSize = 320

    private var model: MLModel?

    func prepare() async throws {
        guard model == nil else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try await SceneModelLoader.load(Self.modelName, configuration: configuration)
    }

    func estimate(_ image: CGImage) async throws -> CameraCalibrationEstimate {
        try await prepare()
        guard let model else { throw SceneModelError.notLoaded("Camera calibration") }

        let box = Self.letterbox(width: image.width, height: image.height, size: Self.inputSize)
        guard let square = Self.draw(image, in: box.rect, size: Self.inputSize) else {
            throw SceneModelError.unexpectedOutput("Camera calibration: could not letterbox the photo")
        }
        // The square already has the model's size, so scaleFill changes nothing.
        let input = try SceneModelIO.imageInput(for: model, image: square, crop: .scaleFill)
        let output = try await model.prediction(from: input)
        guard let array = SceneModelIO.firstOutput(of: .multiArray, in: output, model: model)?.multiArrayValue else {
            throw SceneModelError.unexpectedOutput("Camera calibration: no multi-array output")
        }
        return try Self.estimate(from: Self.values(of: array), heightOnSquare: box.heightRatio)
    }

    // MARK: Pure helpers (tested)

    /// Where the photo sits on the square, exactly as `calib.letterbox` in training.
    /// `heightRatio` is the photo's height on the square divided by the square's size.
    nonisolated static func letterbox(width: Int, height: Int, size: Int)
        -> (rect: CGRect, heightRatio: Double) {
        let scale = Double(size) / Double(max(width, height, 1))
        let w = max(1, Int((Double(width) * scale).rounded()))
        let h = max(1, Int((Double(height) * scale).rounded()))
        let rect = CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)
        return (rect, Double(h) / Double(size))
    }

    /// Converts the raw output into the photo's own units and checks it is usable.
    nonisolated static func estimate(from v: [Double], heightOnSquare: Double) throws -> CameraCalibrationEstimate {
        guard v.count >= 6, v.allSatisfy(\.isFinite), heightOnSquare > 0 else {
            throw SceneModelError.unexpectedOutput("Camera calibration: expected 6 finite numbers, got \(v.count)")
        }
        let focal = v[2] / heightOnSquare
        guard abs(v[0]) <= 90, abs(v[1]) <= 180, focal > 0.05, focal < 20,
              v[3] > 0, v[4] > 0, v[5] > 0 else {
            throw SceneModelError.unexpectedOutput(String(format: "Camera calibration: implausible output %@",
                                                         v.map { String(format: "%.3f", $0) }.joined(separator: ", ")))
        }
        return CameraCalibrationEstimate(pitchUpDegrees: v[0], rollDegrees: v[1], focalLength: focal,
                                         pitchSigmaDegrees: v[3], rollSigmaDegrees: v[4], focalLogSigma: v[5])
    }

    // MARK: Plumbing

    private nonisolated static func draw(_ image: CGImage, in rect: CGRect, size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .high
        // The rect is centred, so the bottom-left origin of CGContext does not move it.
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// The six numbers, whatever the array's shape ([6] or [1, 6]) and element type.
    private nonisolated static func values(of array: MLMultiArray) throws -> [Double] {
        let shape = array.shape.map(\.intValue)
        guard let last = shape.last, last >= 6, shape.dropLast().allSatisfy({ $0 == 1 }) else {
            throw SceneModelError.unexpectedOutput("Camera calibration: output shape \(shape)")
        }
        let lead = Array(repeating: NSNumber(value: 0), count: shape.count - 1)
        return (0..<6).map { array[lead + [NSNumber(value: $0)]].doubleValue }
    }
}
