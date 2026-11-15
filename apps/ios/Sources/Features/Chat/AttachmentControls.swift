import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

nonisolated private struct PickedPhoto: Transferable, Sendable {
    let input: NativeAttachmentInput

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            PickedPhoto(input: try NativeAttachmentInput.read(file.file))
        }
    }
}

struct AttachmentPickerButton: View {
    let disabled: Bool
    let importFile: (URL) -> Void
    let importPhoto: (NativeAttachmentInput) -> Void
    let failed: (Error) -> Void
    var capturePhoto: (() -> Void)? = nil
    @State private var showsFiles = false
    @State private var showsPhotos = false
    @State private var photo: PhotosPickerItem?
    @State private var loadingPhoto = false

    var body: some View {
        Menu {
            Button("native.attachment.photos", systemImage: "photo") { showsPhotos = true }
            if let capturePhoto { Button("native.attachment.camera", systemImage: "camera", action: capturePhoto) }
            Button("native.attachment.files", systemImage: "folder") { showsFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 42, height: 42)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .disabled(disabled || loadingPhoto)
        .accessibilityLabel("native.attachment.add")
        .photosPicker(isPresented: $showsPhotos, selection: $photo, matching: .images, preferredItemEncoding: .current)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            do { if let url = try result.get().first { importFile(url) } }
            catch let error as CocoaError where error.code == .userCancelled { }
            catch { failed(error) }
        }
        .task(id: photo) {
            guard let selected = photo else { loadingPhoto = false; return }
            loadingPhoto = true
            defer {
                if photo == selected { loadingPhoto = false; photo = nil }
            }
            do {
                guard let value = try await selected.loadTransferable(type: PickedPhoto.self) else { throw NativeAttachmentFailure.invalidFile }
                try Task.checkCancellation()
                importPhoto(value.input)
            } catch is CancellationError { }
            catch { if !Task.isCancelled, photo == selected { failed(error) } }
        }
    }
}

struct AttachmentDrafts: View {
    let attachments: [HostAttachment]
    let busy: Bool
    let remove: (HostAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments, id: \.id) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: attachment.kind == "image" ? "photo" : "doc")
                    Text(attachment.name).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { remove(attachment) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("native.files.remove \(attachment.name)"))
                        .disabled(busy)
                }
                .font(.callout)
            }
            if busy { ProgressView("native.files.transferring").font(.caption) }
            if !attachments.isEmpty { Text("native.files.limit").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct LiveAttachmentButton: View {
    let attachment: HostAttachment
    let downloading: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: attachment.kind == "image" ? "photo" : "doc")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name).font(.callout.weight(.medium)).lineLimit(2)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if downloading { ProgressView() }
                else { Image(systemName: "arrow.down.circle") }
            }
            .padding(14)
            .foregroundStyle(.primary)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(downloading)
    }
}

/// Quick Look reads only a bounded file that this app downloaded through its authenticated peer.
struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
