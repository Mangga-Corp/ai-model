import Foundation
import CoreGraphics
import Accelerate
import UIKit

/// Protocol defining the lighting-direction analysis interface.
protocol LightingDirectionAnalyzing {
    func analyzeLightDirection(cgImage: CGImage) -> LightDirectionResult
}

/// LightingDirectionService — estimates the dominant light-source direction from
/// the luminance gradient across the frame.
///
/// METHOD (documented, deterministic, honest about limits):
/// 1. Downsample the image to a small grid (default 64×64) of luminance values.
/// 2. Compute the Sobel gradient (Gx, Gy) at each cell using 3×3 kernels.
/// 3. Accumulate the gradient vector. Brightness increases toward the light,
///    so the summed gradient points AWAY from the light; we invert it.
/// 4. Map the resulting vector to one of 8 compass directions.
///
/// ACCURACY CAVEATS (surfaced in the UI, never hidden):
/// - This is an approximation. A genuinely flat-lit scene yields near-zero
///   gradient, which we report as `.center` (even lighting) with low confidence.
/// - Strong vignettes, on-camera flash, or heavy post-processing can bias the
///   result. Confidence reflects gradient magnitude, not correctness.
/// - PRD Rule 4: absence of a directional gradient is reported as "even",
///   NOT as evidence the photograph is badly lit.
final class LightingDirectionService: LightingDirectionAnalyzing {

    /// Grid size for the downsampled luminance plane.
    private let gridSize = 64

    /// Minimum mean gradient magnitude for a direction to be reported at all.
    /// Below this we report `.center` / even lighting.
    private let minimumGradientMagnitude: Double = 0.012

    /// Confidence threshold above which `hasLightDirection` becomes true.
    /// Normalized gradient magnitude is small in practice; this is calibrated
    /// so a clearly side-lit frame clears it while flat lighting does not.
    private let confidenceThreshold: Double = 0.20

    func analyzeLightDirection(cgImage: CGImage) -> LightDirectionResult {
        guard let luminanceGrid = buildLuminanceGrid(from: cgImage) else {
            return LightDirectionResult(direction: nil, confidence: 0, shadowDirection: nil, gradientMagnitude: 0)
        }

        // Compute Sobel gradients
        var sumGx: Double = 0
        var sumGy: Double = 0

        let n = gridSize
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                // 3×3 Sobel neighbourhood
                let tl = luminanceGrid[(y - 1) * n + (x - 1)]
                let tc = luminanceGrid[(y - 1) * n + x]
                let tr = luminanceGrid[(y - 1) * n + (x + 1)]
                let ml = luminanceGrid[y * n + (x - 1)]
                let mr = luminanceGrid[y * n + (x + 1)]
                let bl = luminanceGrid[(y + 1) * n + (x - 1)]
                let bc = luminanceGrid[(y + 1) * n + x]
                let br = luminanceGrid[(y + 1) * n + (x + 1)]

                // Sobel X (horizontal brightness change)
                let gx = (tr + 2 * mr + br) - (tl + 2 * ml + bl)
                // Sobel Y (vertical brightness change, +y = downward in grid)
                let gy = (bl + 2 * bc + br) - (tl + 2 * tc + tr)

                sumGx += Double(gx)
                sumGy += Double(gy)
            }
        }

        let cellCount = Double((n - 2) * (n - 2))
        let meanGx = sumGx / cellCount
        let meanGy = sumGy / cellCount

        let magnitude = sqrt(meanGx * meanGx + meanGy * meanGy)

        guard magnitude >= minimumGradientMagnitude else {
            // Flat or even lighting — PRD Rule 4: report as unavailable, not "bad"
            return LightDirectionResult(
                direction: .center,
                confidence: 0,
                shadowDirection: .center,
                gradientMagnitude: magnitude
            )
        }

        // The gradient points toward BRIGHTER areas, which is where the light
        // comes from — so it already points at the light source. Do NOT invert:
        // inverting would aim the arrow at the shadows instead.
        let lightX = meanGx
        let lightY = meanGy  // grid y is top-down; lightY > 0 means light from bottom

        let direction = classifyDirection(x: lightX, y: lightY)
        let shadow = oppositeDirection(direction)

        // Confidence: normalized gradient magnitude, clamped to 0-1.
        // We scale by 4× because typical scene gradients are small.
        let confidence = min(magnitude * 4.0, 1.0)

        return LightDirectionResult(
            direction: direction,
            confidence: confidence,
            shadowDirection: shadow,
            gradientMagnitude: magnitude
        )
    }

    // MARK: - Private

    /// Builds a 64×64 luminance grid via the shared vImage builder.
    private func buildLuminanceGrid(from cgImage: CGImage) -> [Float]? {
        LuminanceGridBuilder.build(from: cgImage, gridSize: gridSize)
    }

    /// Classifies a gradient vector into one of 8 compass directions.
    /// Uses 45° sectors with the light vector in image space (x right, y down).
    private func classifyDirection(x: Double, y: Double) -> LightDirection {
        let angle = atan2(y, x) * 180 / .pi  // 0 = right, 90 = down, -90 = up
        let a = (angle + 360).truncatingRemainder(dividingBy: 360)

        switch a {
        case 22.5..<67.5:    return .bottomRight
        case 67.5..<112.5:   return .bottom
        case 112.5..<157.5:  return .bottomLeft
        case 157.5..<202.5:  return .left
        case 202.5..<247.5:  return .topLeft
        case 247.5..<292.5:  return .top
        case 292.5..<337.5:  return .topRight
        default:             return .right
        }
    }

    /// Returns the opposite compass direction (where shadows fall).
    private func oppositeDirection(_ direction: LightDirection) -> LightDirection {
        switch direction {
        case .topLeft:     return .bottomRight
        case .top:         return .bottom
        case .topRight:    return .bottomLeft
        case .left:        return .right
        case .center:      return .center
        case .right:       return .left
        case .bottomLeft:  return .topRight
        case .bottom:      return .top
        case .bottomRight: return .topLeft
        }
    }
}

// MARK: - Result Type

struct LightDirectionResult {
    let direction: LightDirection?   // nil if gradient too weak to classify
    let confidence: Double           // 0-1
    let shadowDirection: LightDirection?
    let gradientMagnitude: Double    // Raw mean Sobel magnitude
}
