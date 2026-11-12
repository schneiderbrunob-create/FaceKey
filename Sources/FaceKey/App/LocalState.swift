//
//  LocalState.swift
//  FaceKey
//
//  In the macOS 27 SDK `@State` resolves to a macro whose compiler plugin ships only with Xcode, so a build with
//  just the Command Line Tools cannot expand it. This alias names the underlying property-wrapper struct directly,
//  which behaves the same and needs no plugin. With Xcode installed, `@State` could be used again.
//

import SwiftUI

typealias LocalState<Value> = SwiftUI.State<Value>
