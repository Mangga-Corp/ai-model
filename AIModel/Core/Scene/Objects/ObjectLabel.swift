//
//  ObjectLabel.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//


import Foundation

/// Which segmentation labels are countable OBJECTS ("things": car, chair…)
/// as opposed to surfaces ("stuff": sky, wall, road…), and how to name them.
///
/// Uses the 80 COCO "thing" classes DETR was trained on, plus common aliases,
/// so the check does not depend on the label order inside the model.
nonisolated enum ObjectLabel {

    static let things: Set<String> = [
        "person", "bicycle", "car", "motorcycle", "motorbike", "airplane", "aeroplane",
        "bus", "train", "truck", "boat", "traffic light", "fire hydrant", "stop sign",
        "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie",
        "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat",
        "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
        "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake",
        "chair", "couch", "sofa", "potted plant", "pottedplant", "bed", "dining table",
        "diningtable", "toilet", "tv", "tvmonitor", "laptop", "mouse", "remote",
        "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
        "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
    ]

    /// "Dining_Table" → "dining table".
    static func normalized(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func isObject(_ raw: String) -> Bool { things.contains(normalized(raw)) }

    static func isPerson(_ raw: String) -> Bool { normalized(raw) == "person" }

    private static let friendlyNames: [String: String] = [
        "dining table": "Table", "diningtable": "Table",
        "potted plant": "Plant", "pottedplant": "Plant",
        "tv": "TV", "tvmonitor": "TV", "cell phone": "Phone",
        "motorbike": "Motorcycle", "aeroplane": "Airplane", "sofa": "Couch",
        "sports ball": "Ball", "hair drier": "Hair dryer",
    ]

    /// Short name for the UI: "dining table" → "Table", "car" → "Car".
    static func displayName(for raw: String) -> String {
        let name = normalized(raw)
        if let friendly = friendlyNames[name] { return friendly }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
