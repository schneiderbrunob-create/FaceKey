//
//  EnrollmentView.swift
//  FaceKey
//
//  Sheet that walks through the guided capture and saves the result as a new enrolled face.
//

import SwiftUI

struct EnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @LocalState private var controller: EnrollmentController
    @LocalState private var saveError: String?

    init(pipeline: FaceRecognitionPipeline) {
        _controller = LocalState(initialValue: EnrollmentController(pipeline: pipeline))
    }

    private var trimmedName: String {
        controller.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var nameProblem: String? {
        if trimmedName.isEmpty { return "Give this face a name, such as “Me” or “Me with glasses”." }
        if FaceEnrollmentStore.shared.nameIsTaken(trimmedName) { return "That name is already used." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enroll a face").font(.title2).bold()

            TextField("Name", text: Binding(get: { controller.name }, set: { controller.name = $0 }))
                .textFieldStyle(.roundedBorder)

            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.85))
                if controller.isRunning {
                    CameraPreviewView(session: controller.camera.session, faces: controller.detectedFaces)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: controller.isComplete ? "checkmark.circle.fill" : "faceid")
                        .font(.system(size: 56))
                        .foregroundStyle(controller.isComplete ? .green : .white.opacity(0.6))
                }
            }
            .frame(width: 440, height: 300)

            ProgressView(value: controller.progress)

            VStack(alignment: .leading, spacing: 4) {
                if controller.isRunning || controller.isComplete {
                    Text(controller.currentInstruction).font(.headline)
                    Text(controller.hint.isEmpty ? " " : controller.hint).foregroundStyle(.secondary)
                } else {
                    Text("Sit where you normally use this Mac, with light on your face.").font(.headline)
                    Text("Five poses, two captures each. Only numeric face embeddings are kept; the pictures are discarded.")
                        .foregroundStyle(.secondary)
                }
                if let error = controller.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                }
                if controller.isComplete, let nameProblem {
                    Text(nameProblem).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)

            HStack {
                Button("Cancel", role: .cancel) {
                    controller.stop()
                    dismiss()
                }
                Spacer()
                if controller.isRunning {
                    Button("Capture this pose anyway") { controller.captureAnyway() }
                        .help("Use this if the pose check never accepts your position.")
                } else if controller.isComplete {
                    Button("Start over") { controller.start() }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(nameProblem != nil)
                } else {
                    Button("Start") { controller.start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onDisappear { controller.stop() }
    }

    private func save() {
        do {
            try controller.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
