"""Compile the actual HTTP-response producer with fake network/account boundaries."""
from pathlib import Path
import hashlib
import json
import sys

root, output = map(Path, sys.argv[1:])
source = (root / 'PhoneAgent/Services/VisionClient.swift').read_text()
signature = '    private func load(_ request: URLRequest, parentID: UUID? = nil) async throws -> (Data, URLResponse)'
assert source.count(signature) == 1
start = source.index(signature)
end = source.index('{', start) + 1
depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
member = source[start:end]
wrapper = '''import Foundation
struct LoadBoundaryClient {
    let settings: LoadSettings
    let connection: FixtureConnection? = FixtureConnection()
    let metrics: FixtureMetrics? = nil
    let planProfileID: UUID? = LoadFixture.profileID
'''
output.write_text(wrapper + member.replace('private func load(', 'func load(', 1) + '\n}\n')
output.with_suffix('.json').write_text(json.dumps(dict(
    originalMemberSHA256=hashlib.sha256(member.encode()).hexdigest(),
    bodySubstitutions=[], visibilityChange='private -> internal for host invocation',
    boundaries='Fake session, account/profile and metrics only; actual request preparation, status handling and response producer',
    deviceOrNetworkAcceptance=False), indent=2) + '\n')
