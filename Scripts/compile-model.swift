// Compiles a Core ML .mlpackage into the .mlmodelc folder the app loads at runtime.
// Stands in for Xcode's coremlcompiler, which the Command Line Tools do not ship.
// Usage: swift compile-model.swift <input.mlpackage> <output.mlmodelc>

import CoreML
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: compile-model.swift <input.mlpackage> <output.mlmodelc>\n".utf8))
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])

let compiled = try await MLModel.compileModel(at: source)
try? FileManager.default.removeItem(at: destination)
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.copyItem(at: compiled, to: destination)
print("Compiled model written to \(destination.path)")
