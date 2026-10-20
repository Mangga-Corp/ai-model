//
//  ViewpointSettingsView.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//

import SwiftUI

/// `UserDefaults` keys for the viewpoint settings, shared by the camera screen
/// (which applies them) and the settings sheet (which edits them).
enum ViewpointSettingsKeys {
    static let angleEnabled = "viewpoint.angleEnabled"
    static let angle = "viewpoint.angle"
    static let height = "viewpoint.height"
    static let tiltEnabled = "viewpoint.tiltEnabled"
    static let pitch = "viewpoint.pitch"
    static let horizon = "viewpoint.horizon"
    static let recordCaptureData = "viewpoint.recordCaptureData"
}

/// The two viewpoint switches and their targets. Off = the camera works exactly
/// as it did before (subject position guidance only).
struct ViewpointSettingsView: View {

    @AppStorage(ViewpointSettingsKeys.angleEnabled) private var angleEnabled = false
    @AppStorage(ViewpointSettingsKeys.angle) private var angle: AngleTarget = .matchProfile
    @AppStorage(ViewpointSettingsKeys.height) private var height: HeightTarget = .any
    @AppStorage(ViewpointSettingsKeys.tiltEnabled) private var tiltEnabled = false
    @AppStorage(ViewpointSettingsKeys.pitch) private var pitch: PitchTarget = .matchProfile
    @AppStorage(ViewpointSettingsKeys.horizon) private var horizon: HorizonTarget = .straight
    @AppStorage(ViewpointSettingsKeys.recordCaptureData) private var recordCaptureData = false

    /// What the reference photos support, so "Match my photos" can say what it will aim for.
    let preferences: LiveViewpointPreferences?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Guide camera angle", isOn: $angleEnabled)
                    if angleEnabled {
                        Picker("Angle", selection: $angle) {
                            ForEach(AngleTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Camera height", selection: $height) {
                            ForEach(HeightTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                } header: {
                    Text("Camera angle")
                } footer: {
                    Text(angleFooter)
                }

                Section {
                    Toggle("Guide phone tilt", isOn: $tiltEnabled)
                    if tiltEnabled {
                        Picker("Tilt", selection: $pitch) {
                            ForEach(PitchTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Horizon", selection: $horizon) {
                            ForEach(HorizonTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                } header: {
                    Text("Phone tilt")
                } footer: {
                    Text(tiltFooter)
                }

                Section {
                    Toggle("Save capture data", isOn: $recordCaptureData)
                } footer: {
                    Text("Keeps each photo with its measured tilt, lens and angle on this device, to train a better angle model later. Nothing is uploaded.")
                }
            }
            .navigationTitle("Angle & tilt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var angleFooter: String {
        var text = "Bird's eye and high angle look down on the subject, low angle and worm's eye look up. Fixed by moving the phone, not tilting it."
        if angleEnabled, angle == .matchProfile || height == .matchProfile {
            text += " " + habitLine(angle: preferences?.angle, height: preferences?.heightLevel)
        }
        return text
    }

    private var tiltFooter: String {
        var text = "Tilt is how far the phone looks up or down. Horizon is its sideways tip; a Dutch angle tips it on purpose."
        if tiltEnabled, pitch == .matchProfile, let support = preferences?.pitchUp {
            switch support {
            case .supported(let range):
                text += String(format: " Your photos: about %.0f° to %.0f° (negative = looking down).", range.lowerBound, range.upperBound)
            case .unavailable(let reason):
                text += " Your photos: " + reason.explanation
            }
        }
        return text
    }

    private func habitLine(angle: PreferenceSupport<CameraAngleCategory>?,
                           height: PreferenceSupport<CameraHeightLevel>?) -> String {
        var parts: [String] = []
        if let angle {
            switch angle {
            case .supported(let c): parts.append("usually \(c.label.lowercased())")
            case .unavailable(let r): parts.append(r.explanation)
            }
        } else {
            parts.append(PreferenceUnavailableReason.noPreferenceData.explanation)
        }
        if let value = height?.value { parts.append("camera usually at \(value.label.lowercased())") }
        return "Your photos: " + parts.joined(separator: "; ")
    }
}
