"""Compose existing offline boundaries around actual Runtime, MouseExecutor and BLE methods."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

root, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, str(root / 'Tests/ContextLease/ExtractProduction.py'), 'extract', str(root), str(out / 'context')], check=True)
(out / 'input').mkdir()
subprocess.run([sys.executable, str(root / 'Tests/InputRelease/ExtractProduction.py'), str(out / 'input')], check=True)


def member(text, signature):
    assert text.count(signature) == 1, signature
    start = text.index(signature)
    cursor = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[cursor] == '{') - (text[cursor] == '}')
        cursor += 1
    return text[start:cursor]


env = (out / 'context/Environment.swift').read_text()
for signature in ['@MainActor final class OfflineBLE {', '@MainActor final class MouseExecutor {']:
    env = env.replace(member(env, signature), '')
env = env.replace('import Foundation', 'import Foundation\nimport CoreBluetooth', 1)
env = env.replace('enum SettingsStore {', 'enum SettingsStore { static func calibration() -> PointerCalibration? { nil };')
ble = (out / 'input/Environment.swift').read_text()
# Keep the transport's original command/ACK/release members, with only native
# CoreBluetooth endpoints replaced by the established synthetic peripheral.
env += '\n' + ble[ble.index('typealias CBPeripheral ='):ble.index('@MainActor final class ManualOwner {')]
(out / 'Environment.swift').write_text(env)
paths = set(json.loads((out / 'context/source-inputs.json').read_text()))
paths.update(json.loads((out / 'input/input-hashes.json').read_text())['files'])
paths.update(['Tests/SemanticDispatch/ExtractProduction.py', 'Tests/SemanticDispatch/main.swift', 'Tests/SemanticDispatch/run.sh', 'Tests/InputRelease/Environment.swift'])
(out / 'source-inputs.json').write_text(json.dumps({p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sorted(paths)}, indent=2) + '\n')
