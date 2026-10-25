import Foundation
import Combine
import SwiftUI
import PhotosUI

@MainActor
final class ComposerAttachmentStore: ObservableObject {
    func reportImportError(_ message: String) { error = message }
    @Published private(set) var items: [ComposerAttachment] = []
    @Published private(set) var importing = false
    @Published private(set) var error = ""
    private var request: Task<Void, Never>?
    private var generation = UUID()

    func importFiles(_ urls: [URL]) {
        guard beginImport(count: urls.count) else { return }
        let token = generation
        request = Task { [weak self] in
            var failures: [String] = []
            for url in urls {
                guard !Task.isCancelled, let self, token == self.generation else { return }
                do {
                    let attachment = try await ComposerAttachmentImport.read(url)
                    try Task.checkCancellation()
                    guard token == self.generation else { return }
                    try ComposerAttachmentPolicy.validate(self.items + [attachment])
                    self.items.append(attachment)
                } catch is CancellationError { return }
                catch {
                    guard token == self.generation, !Task.isCancelled else { return }
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            self?.finishImport(token: token, failures: failures)
        }
    }

    func importPhotos(_ selected: [PhotosPickerItem]) {
        guard beginImport(count: selected.count) else { return }
        let token = generation
        request = Task { [weak self] in
            var failures: [String] = []
            for (index, item) in selected.enumerated() {
                guard !Task.isCancelled, let self, token == self.generation else { return }
                let name = "照片 \(index + 1)"
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw AttachmentIssue("无法读取所选照片，请重新选择")
                    }
                    try Task.checkCancellation()
                    let attachment: ComposerAttachment
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        attachment = try await ComposerAttachmentImport.readVideo(data, name: "视频 \(index + 1).mov")
                    } else { attachment = try await ComposerAttachmentImport.readImage(data, name: name) }
                    try Task.checkCancellation()
                    guard token == self.generation else { return }
                    try ComposerAttachmentPolicy.validate(self.items + [attachment])
                    self.items.append(attachment)
                } catch is CancellationError { return }
                catch {
                    guard token == self.generation, !Task.isCancelled else { return }
                    failures.append("\(name)：\(error.localizedDescription)")
                }
            }
            self?.finishImport(token: token, failures: failures)
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        error = ""
    }

    func clear() {
        cancelImport()
        items = []; error = ""
    }

    func replace(_ replacements: [ComposerAttachment]) {
        cancelImport()
        do {
            try ComposerAttachmentPolicy.validate(replacements)
            items = replacements; error = ""
        } catch { self.error = error.localizedDescription }
    }

    func cancelImport() {
        generation = UUID()
        request?.cancel(); request = nil; importing = false
    }

    private func beginImport(count: Int) -> Bool {
        cancelImport()
        error = ""
        guard count > 0 else { return false }
        let remaining = ComposerAttachmentPolicy.maximumCount - items.count
        guard count <= remaining else {
            error = remaining > 0 ? "还能添加 \(remaining) 个附件，请减少选择数量" : "一次最多添加 4 个附件，请先移除一个"
            return false
        }
        importing = true
        return true
    }

    private func finishImport(token: UUID, failures: [String]) {
        guard token == generation else { return }
        error = failures.joined(separator: "\n")
        importing = false; request = nil
    }
}
