//
//  EnhanceTuner.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 19/10/26.
//


import Foundation

// MARK: - Enhance Tuner

/// Turns a photo's measured statistics into enhance strengths, so each photo
/// gets only as much correction as it needs: a dim, flat, grey shot gets a
/// strong lift, an already bright and punchy one is barely touched.
///
/// Every rule maps one measurement onto one step through `ramp`, a clamped
/// linear ramp between two thresholds. The thresholds come from measuring the
/// reference raw/enhanced pair and typical indoor captures; they are named
/// below so they can be retuned without touching the logic.
nonisolated enum EnhanceTuner {

    static func settings(for stats: PhotoStatistics) -> PhotoEnhancer.Settings {
        let dark = ramp(stats.meanLuminance, from: 0.42, to: 0.20)
        let bright = ramp(stats.meanLuminance, from: 0.62, to: 0.82)
        let flat = ramp(stats.contrast, from: 0.22, to: 0.10)
        let dull = ramp(stats.saturation, from: 0.30, to: 0.10)
        let noisy = ramp(stats.noise, from: 0.006, to: 0.026)
        let faceSize = ramp(stats.largestFaceWidth, from: 0.05, to: 0.35)
        let warmCast = ramp(stats.colorCast, from: 0.02, to: 0.12)
        let coolCast = ramp(stats.colorCast, from: 0.0, to: -0.10)

        var settings = PhotoEnhancer.Settings()

        // How much of the enhance is mixed in overall: badly exposed, flat or
        // grey photos need the full effect; good ones only a light touch.
        let need = min(1, 0.5 * max(dark, bright) + 0.4 * flat + 0.3 * dull)
        settings.strength = Float(0.6 + 0.3 * need)

        // Colour: lift grey photos, leave already-saturated ones alone.
        settings.vibrance = Float(0.05 + 0.3 * dull)

        // Warmth: cool/LED casts get warmed, warm (tungsten) ones are left as is.
        settings.warmthKelvin = Float(350 * (1 - warmCast) + 250 * coolCast)

        // Clarity: more on flat photos. Less on noisy ones (it amplifies
        // grain) and on close-up faces (it amplifies skin texture).
        settings.clarity = Float((0.25 + 0.3 * flat) * (1 - 0.5 * noisy) * (1 - 0.4 * faceSize))

        // Sharpening amplifies noise, so it backs off as noise rises.
        settings.sharpness = Float(0.1 + 0.35 * (1 - noisy))

        // Skin smoothing only where there is a face, stronger as the face gets
        // bigger (texture is visible) and when the photo is grainy.
        settings.skinSmoothing = stats.hasFace ? Float(min(0.7, 0.3 + 0.3 * faceSize + 0.15 * noisy)) : 0

        // Vignette draws the eye to a subject; lighter on bright scenes and
        // when there is no face to draw it to.
        settings.vignette = Float((stats.hasFace ? 0.35 : 0.2) * (1 - 0.5 * bright))

        return settings
    }

    /// 0 at `from`, 1 at `to`, linear in between and clamped outside. Works in
    /// either direction (`to` may be below `from`).
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard from != to else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }
}
