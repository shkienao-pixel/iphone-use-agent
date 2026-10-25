#!/usr/bin/env python3
"""Replace only the two HTTP loaders; keep prompt construction and decoding real."""
from pathlib import Path
import hashlib
import json
import sys


def replace_loader(source, signature, replacement):
    assert source.count(signature) == 1, signature
    start = source.index(signature)
    cursor = start + len(signature)
    depth = 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[:start] + signature + "\n        " + replacement + "\n    }" + source[cursor:]


def main():
    root, output = (Path(value).resolve() for value in sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    replacements = {
        "PhoneAgent/Services/VisionClient.swift": (
            "    private func load(_ request: URLRequest, parentID: UUID? = nil) async throws -> (Data, URLResponse) {",
            "return try await RoutingWireProbe.load(request)"),
        "PhoneAgent/Services/ConnectedConversationClient.swift": (
            "    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {",
            "return try await RoutingWireProbe.loadConnected(request)"),
    }
    hashes = {}
    for name, (signature, replacement) in replacements.items():
        original = (root / name).read_bytes()
        (output / Path(name).name).write_text(replace_loader(original.decode(), signature, replacement))
        (output / (Path(name).name + ".original.txt")).write_bytes(original)
        hashes[name] = hashlib.sha256(original).hexdigest()
    (output / "extraction.json").write_text(json.dumps({
        "sourceSHA256": hashes, "replacementScope": "Only HTTP load method bodies",
        "limits": "Actual router, request construction, privacy checks and decoders; local collector replaces network. No real model, credential, tool, phone or response-quality acceptance.",
    }, indent=2) + "\n")
    print("ConversationRouting: actual clients with only HTTP loaders replaced")


if __name__ == "__main__":
    main()
