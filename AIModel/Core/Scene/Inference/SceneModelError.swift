//
//  SceneModelError.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

nonisolated enum SceneModelError: Error, Equatable {
    case missingModel(String)
    case notLoaded(String)
    case missingLabels(String)
    case unexpectedOutput(String)
}