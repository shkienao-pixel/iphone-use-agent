#!/usr/bin/env python3
"""Explicitly copy a one-use Ctrip credential payload to a paired debug app.

The authorization code is read through a captured Keychain-helper pipe. It is
never accepted in arguments, placed in an environment variable, or printed.
The app must separately launch with --import-ctrip-config-once to consume it.
Importing this module performs no Keychain or device operation.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


HELPER = Path(__file__).resolve().parent / ".build" / "keychain-helper"


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # argparse normally echoes unrecognized arguments. A mistaken secret
        # argument must not be repeated to the terminal or a captured tool log.
        print('{"success":false}')
        raise SystemExit(2)


def provision(device: str, bundle_id: str) -> bool:
    """Return only a safe transfer status; do not surface subprocess output."""
    temporary_directory: str | None = None
    source: Path | None = None
    success = False
    cleanup_complete = True
    try:
        captured = subprocess.run(
            [str(HELPER), "get"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=30, check=False,
        )
        if captured.returncode != 0:
            raise ValueError()
        key_bytes = captured.stdout
        if not (8 <= len(key_bytes) <= 4096) or any(value < 33 or value > 126 for value in key_bytes):
            raise ValueError()
        key = key_bytes.decode("ascii")
        # The temporary location is outside the project. Tighten its permissions
        # before creating the only plaintext payload; always delete it afterward.
        temporary_directory = tempfile.mkdtemp(prefix="phoneagent-ctrip-", dir="/private/tmp")
        os.chmod(temporary_directory, 0o700)
        source = Path(temporary_directory) / "ctrip-config.once.json"
        payload = json.dumps({"version": 1, "apiKey": key}, ensure_ascii=True, separators=(",", ":")).encode("ascii")
        descriptor = os.open(source, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        copied = subprocess.run(
            ["xcrun", "devicectl", "device", "copy", "to", "--quiet",
             "--device", device, "--source", str(source),
             "--destination", "Documents/ctrip-config.once.json",
             "--domain-type", "appDataContainer", "--domain-identifier", bundle_id],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=120, check=False,
        )
        success = copied.returncode == 0
    except Exception:
        # No exception text: decoder or subprocess failures can contain input.
        success = False
    finally:
        # Never retain the temporary payload, even if copy or Keychain failed.
        if source is not None:
            try:
                source.unlink(missing_ok=True)
            except OSError:
                cleanup_complete = False
        if temporary_directory is not None:
            try:
                os.rmdir(temporary_directory)
            except OSError:
                cleanup_complete = False
    return success and cleanup_complete


def main() -> int:
    parser = SafeArgumentParser(description="将本机钥匙串的携程授权码一次性传入已配对的调试 App；不自动启动或启用携程。")
    parser.add_argument("--device", required=True, help="已配对的设备标识")
    parser.add_argument("--bundle-id", required=True, help="调试 App 的 Bundle ID")
    args = parser.parse_args()
    success = provision(args.device, args.bundle_id)
    print(json.dumps({"success": success}, separators=(",", ":")))
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
