import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A captured still stays in memory. The caller decides whether to add it to the current draft.
struct CameraCaptureSheet: View {
    let contextID: String
    let onCapture: (NativeAttachmentInput) -> Void
    let onCancel: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: CameraPermission = .checking
    @State private var finished = false

    var body: some View {
        NavigationStack {
            Group {
                switch permission {
                case .checking:
                    ProgressView("native.camera.preparing")
                case .ready:
                    CameraStillPicker { result in
                        guard !finished else { return }
                        switch result {
                        case .success(let input):
                            finished = true
                            onCapture(input)
                        case .failure(.cancelled): cancel()
                        case .failure(.unavailable): permission = .unavailable
                        case .failure(.invalidImage): permission = .failed
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                case .denied, .restricted, .unavailable, .failed:
                    ContentUnavailableView {
                        Label("native.attachment.camera", systemImage: "camera")
                    } description: {
                        Text(permission.message)
                    } actions: {
                        if permission == .denied {
                            Button("native.capture.openSettings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("native.attachment.camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("native.capture.cancel", role: .cancel) { cancel() }
                }
            }
        }
        .task { await prepare() }
        .onChange(of: contextID) { _, _ in cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        .onDisappear { finished = true }
    }

    private func prepare() async {
        guard !finished, !Task.isCancelled else { return }
        guard scenePhase != .background else { cancel(); return }
        guard CameraStillPicker.isAvailable else { permission = .unavailable; return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if status == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        } else { allowed = status == .authorized }
        guard !Task.isCancelled, !finished else { return }
        if allowed { permission = .ready }
        else { permission = AVCaptureDevice.authorizationStatus(for: .video) == .restricted ? .restricted : .denied }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}

private enum CameraPermission {
    case checking, ready, denied, restricted, unavailable, failed

    var message: LocalizedStringResource {
        switch self {
        case .denied: "native.camera.denied"
        case .restricted: "native.camera.restricted"
        default: "native.error.generic"
        }
    }
}

private enum CameraCaptureFailure: Error {
    case cancelled, unavailable, invalidImage
}

private struct CameraStillPicker: UIViewControllerRepresentable {
    let completed: (Result<NativeAttachmentInput, CameraCaptureFailure>) -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && UIImagePickerController.availableMediaTypes(for: .camera)?.contains(UTType.image.identifier) == true
    }

    func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }

    func makeUIViewController(context: Context) -> UIViewController {
        // Recheck at presentation. Setting an unavailable source type raises an Objective-C exception.
        guard Self.isAvailable, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            Task { @MainActor in completed(.failure(.unavailable)) }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.completed = completed
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        (controller as? UIImagePickerController)?.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var completed: (Result<NativeAttachmentInput, CameraCaptureFailure>) -> Void

        init(completed: @escaping (Result<NativeAttachmentInput, CameraCaptureFailure>) -> Void) {
            self.completed = completed
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completed(.failure(.cancelled))
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage,
                  image.size.width.isFinite, image.size.height.isFinite,
                  image.size.width > 0, image.size.height > 0 else {
                completed(.failure(.invalidImage)); return
            }
            // Bound the output dimensions and re-encode only pixels: no camera location metadata,
            // photo-library write or temporary image file is needed for a draft attachment.
            let scale = min(1, 2048 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let bytes = rendered.jpegData(compressionQuality: 0.85),
                  !bytes.isEmpty, bytes.count <= NativeAttachmentInput.maximumBytes else {
                completed(.failure(.invalidImage)); return
            }
            completed(.success(NativeAttachmentInput(name: "Photo-\(UUID().uuidString).jpg", mimeType: "image/jpeg", bytes: bytes)))
        }
    }
}
