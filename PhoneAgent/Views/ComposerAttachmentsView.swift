import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVKit

extension View {
    func composerAttachmentPicker(store: ComposerAttachmentStore, showPhotos: Binding<Bool>, showFiles: Binding<Bool>, selectionID: UUID? = nil) -> some View {
        modifier(ComposerAttachmentPicker(store: store, showPhotos: showPhotos, showFiles: showFiles, selectionID: selectionID))
    }
}

private struct ComposerAttachmentPicker: ViewModifier {
    @ObservedObject var store: ComposerAttachmentStore
    @Binding var showPhotos: Bool
    @Binding var showFiles: Bool
    let selectionID: UUID?

    func body(content: Content) -> some View {
        content.background {
            ComposerAttachmentPickerHost(store: store, showPhotos: $showPhotos, showFiles: $showFiles, selectionID: selectionID)
                .id(selectionID)
        }
    }
}

/// A separate identity keeps callbacks from an old system picker attached to
/// its old draft, even if a new conversation opens a picker before it returns.
private struct ComposerAttachmentPickerHost: View {
    @ObservedObject var store: ComposerAttachmentStore
    @Binding var showPhotos: Bool
    @Binding var showFiles: Bool
    let selectionID: UUID?
    @State private var photos: [PhotosPickerItem] = []
    @State private var photoTarget: UUID?
    @State private var fileTarget: UUID?
    @State private var photosArmed = false
    @State private var filesArmed = false
    @State private var visible = false

    private var fileTypes: [UTType] {
        [.image, .movie, .pdf, .plainText] + ["docx", "pptx", "xlsx", "md", "csv", "tsv", "json"].compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: ComposerAttachmentPolicy.maximumCount, matching: .any(of: [.images, .videos]))
            .fileImporter(isPresented: $showFiles, allowedContentTypes: fileTypes, allowsMultipleSelection: true) { result in
                guard visible, filesArmed, fileTarget == selectionID else { return }
                filesArmed = false
                switch result {
                case .success(let urls): store.importFiles(urls)
                case .failure(let error):
                    // Dismissing the system picker is not an import failure.
                    let error = error as NSError
                    if error.domain != NSCocoaErrorDomain || error.code != NSUserCancelledError {
                        store.reportImportError("无法打开所选文件，请重新选择。" + error.localizedDescription)
                    }
                }
            }
            .onAppear {
                visible = true
                if showPhotos { photos = []; photoTarget = selectionID; photosArmed = true }
                if showFiles { fileTarget = selectionID; filesArmed = true }
            }
            .onChange(of: showPhotos) { _, presented in
                if presented { photos = []; photoTarget = selectionID; photosArmed = true }
            }
            .onChange(of: showFiles) { _, presented in
                if presented { fileTarget = selectionID; filesArmed = true }
            }
            .onChange(of: photos) { _, selected in
                guard !selected.isEmpty, visible, photosArmed, photoTarget == selectionID else { return }
                photosArmed = false
                store.importPhotos(selected)
                photos = []
            }
            .onChange(of: selectionID) { _, _ in invalidateSelection() }
            .onDisappear { visible = false; invalidateSelection() }
    }

    private func invalidateSelection() {
        photosArmed = false; filesArmed = false
        showPhotos = false; showFiles = false; photos = []
        photoTarget = nil; fileTarget = nil
        store.cancelImport()
    }
}

/// Read-only attachments saved with a message or task. Every chip opens a
/// local preview; it never changes the current composer draft.
struct ComposerAttachmentList: View {
    let attachments: [ComposerAttachment]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in ComposerAttachmentChip(item: item) }
            }.padding(.vertical, 2)
        }
    }
}

struct ComposerAttachmentTray: View {
    @ObservedObject var store: ComposerAttachmentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.items) { item in
                            ComposerAttachmentChip(item: item, onRemove: { store.remove(item.id) })
                        }
                    }.padding(.vertical, 2)
                }
                Text("点发送后，附件才会发给当前助手。")
                    .font(.caption2).foregroundStyle(.secondary)
                if store.items.contains(where: { $0.kind != .image }) {
                    Text("文件读取基础文字；Office 支持 docx、pptx、xlsx。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if store.importing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在本机读取附件…").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("取消") { store.cancelImport() }.font(.caption).frame(minWidth: 44, minHeight: 44)
                }
            }
            if !store.error.isEmpty {
                Text(store.error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityLabel("附件未添加：" + store.error)
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct ComposerAttachmentChip: View {
    let item: ComposerAttachment
    var onRemove: (() -> Void)? = nil
    @State private var previewing = false

    var body: some View {
        HStack(spacing: 0) {
            Button { previewing = true } label: {
                HStack(spacing: 9) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.caption.weight(.medium)).lineLimit(1)
                        Text(item.kind.label + " · " + ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: 144, alignment: .leading)
                }.padding(.leading, 10).padding(.trailing, onRemove == nil ? 12 : 0).frame(minHeight: 54)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预览附件：" + item.name + "，" + item.kind.label)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 44, height: 54)
                }.buttonStyle(.plain).accessibilityLabel("移除附件：" + item.name)
            }
        }
        .foregroundStyle(.primary)
        .background(AgentPalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgentPalette.ink.opacity(0.07), lineWidth: 1))
        .sheet(isPresented: $previewing) { ComposerAttachmentPreview(item: item) }
        .onDisappear { previewing = false }
    }

    @ViewBuilder private var thumbnail: some View {
        if let data = item.imageJPEG, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
        } else {
            Image(systemName: item.kind.icon).font(.system(size: 20))
                .frame(width: 36, height: 36).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

private struct ComposerAttachmentPreview: View {
    let item: ComposerAttachment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let data = item.videoData {
                        SelaVideoPreview(data: data)
                    }
                    if let data = item.imageJPEG, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                            .accessibilityLabel(item.name)
                    }
                    if !item.text.isEmpty {
                        if item.kind == .image { Text("图片识别文字").font(.caption).foregroundStyle(.secondary) }
                        Text(item.text).font(.body).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if item.kind != .image && item.kind != .video {
                        Text("这是本机读取的基础文字，不包含原文件排版和嵌入图片。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
            .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(.primary)
    }
}

private struct SelaVideoPreview: View {
    let data: Data
    @State private var player: AVPlayer?
    @State private var url: URL?
    var body: some View {
        VideoPlayer(player: player).frame(height: 260)
            .onAppear {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                do { try data.write(to: file, options: [.atomic, .completeFileProtection]); url = file; player = AVPlayer(url: file) }
                catch { }
            }
            .onDisappear { player?.pause(); player = nil; if let url { try? FileManager.default.removeItem(at: url) } }
    }
}
