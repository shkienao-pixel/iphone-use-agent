"""Compile exact production native-presentation methods against offline UI state.

No UIKit or native presentation runs. Coordinator, driver, store, model types and
these method bodies are production code; only stored state/foreground is a fake.
"""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
output = Path(sys.argv[2])

def braced(start):
    first = source.index("{", start)
    depth = 0
    for index in range(first, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError("Unbalanced production method")

def method(signature):
    assert source.count(signature) == 1, signature
    return braced(source.index(signature))

presentation = method("struct NativeFileSharePresentation:")
methods = [
    method("    private func presentAutomaticShare("),
    method("    func finishNativeShare("),
    method("    func nativeSharePresented("),
]
# Keep the automatic workflow's existing scope cleanup exact, too.
cleanup_signature = "defer {if let presentation=sharePresentation,"
assert source.count(cleanup_signature) == 1
cleanup = braced(source.index(cleanup_signature))[len("defer "):]
output.write_text("""import Foundation
@MainActor final class UIApplication {
    enum State { case active }
    static let shared = UIApplication()
    var applicationState: State { .active }
    private init() {}
}
""" + presentation + """
@MainActor final class WorkspacePresentationFixture {
    var sharePresentation: NativeFileSharePresentation?
    var shareContinuation: CheckedContinuation<FileTransferNativeShareResult, Never>?
    var automaticPresentation: CheckedContinuation<WeChatNativeShareBinding, Error>?
    var automaticPresentationID: UUID?
    var shareHosts: Set<UUID> = [UUID()]
    func present(_ payload: FileTransferPayload) async throws -> WeChatNativeShareBinding {
        try await presentAutomaticShare(payload)
    }
    func endAutomaticWorkflow() """ + cleanup + "\n" + "\n\n".join(methods) + "\n}\n")
