#!/usr/bin/env python3
"""Compile the unchanged coordinator with in-memory host boundaries on macOS."""
from pathlib import Path
import hashlib
import json
import sys


def main():
    root, output = (Path(value).resolve() for value in sys.argv[1:])
    source_path = root / "PhoneAgent/Services/ExternalConnectionService.swift"
    source = source_path.read_text()
    signature = "@MainActor\nfinal class ExternalConnectionsCoordinator:"
    assert source.count(signature) == 1
    start = source.index(signature)
    end = source.index("\nenum MeituanConnectionStore {", start)
    coordinator = source[start:end]
    assert "private init()" in coordinator
    # The initializer's DEBUG-only device import is excluded by the host build.
    # Production methods, fields, access levels and initializer stay verbatim.
    factory = """
extension ExternalConnectionsCoordinator {
    static func freshOfflineInstance() -> ExternalConnectionsCoordinator {
        ExternalConnectionsCoordinator()
    }
}
"""
    output.mkdir(parents=True, exist_ok=True)
    (output / "Coordinator.swift").write_text("import Foundation\nimport Combine\n\n" + coordinator + factory)
    (output / "original-service.swift.txt").write_bytes(source_path.read_bytes())
    (output / "extraction.json").write_text(json.dumps({
        "originalSourceSHA256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "coordinatorSHA256": hashlib.sha256(coordinator.encode()).hexdigest(),
        "productionSubstitutions": [],
        "testOnlyAddition": "Same-file factory exposes the unchanged private initializer to the host test.",
        "limits": "Real coordinator; in-memory defaults/credentials and gated local transport. No DEBUG device import, Keychain, network, account or iPhone acceptance.",
    }, indent=2) + "\n")
    print("BridgeIdentity: complete current coordinator extracted without substitutions")


if __name__ == "__main__":
    main()
