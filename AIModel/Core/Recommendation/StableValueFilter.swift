//
//  StableValueFilter.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

/// Shows a value only after it has been seen `requiredRepeats` times in a row.
/// Same idea as `CompositionGuidanceEngine`'s stability window, made generic.
nonisolated struct StableValueFilter<Value: Equatable & Sendable>: Sendable {
    var requiredRepeats = 3
    private var candidate: Value?
    private var count = 0
    private(set) var current: Value?

    mutating func update(_ value: Value?) -> Value? {
        if value == candidate { count += 1 } else { candidate = value; count = 1 }
        if count >= requiredRepeats { current = value }
        return current
    }

    mutating func reset() { candidate = nil; count = 0; current = nil }
}