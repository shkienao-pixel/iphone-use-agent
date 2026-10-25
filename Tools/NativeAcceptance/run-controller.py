#!/usr/bin/env python3
"""Run one cable-paired XCTest operator session. Never provisions model secrets."""
import argparse
from contextlib import contextmanager
import datetime
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid


@contextmanager
def retention_lease(out):
    lease = out / '.build-retention.lock'
    lease.mkdir()
    (lease / 'owner.json').write_text(json.dumps({'pid': os.getpid(), 'purpose': 'native test session'}))
    try:
        yield
    finally:
        (lease / 'owner.json').unlink()
        lease.rmdir()
        maintenance = Path(__file__).resolve().parents[2] / 'scripts/cleanup-build-artifacts.py'
        try:
            subprocess.run(['python3', str(maintenance), '--apply', '--protect', str(out)], timeout=120)
        except (OSError, subprocess.TimeoutExpired) as error:
            print('Build maintenance deferred: ' + str(error), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--sela-bundle', required=True)
    parser.add_argument('--runner-bundle', required=True, help='Base test bundle, without .xctrunner')
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True); out.chmod(0o700)
    with retention_lease(out):
        run_session(args, out)


def run_session(args, out):
    config_path = out / 'controller-session.json'
    if config_path.exists():
        raise SystemExit('Use a new output directory for each controller session.')
    config = {'session': str(uuid.uuid4()), 'sela_session': str(uuid.uuid4()), 'device': args.device,
              'sela_bundle': args.sela_bundle, 'runner_bundle': args.runner_bundle + '.xctrunner',
              'created_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'status': 'building'}
    config_path.write_text(json.dumps(config, indent=2)); config_path.chmod(0o600)
    project = Path(__file__).resolve().parent / 'NativePanelRunner.xcodeproj'
    build = out / 'build'
    command = ['xcodebuild', '-project', str(project), '-scheme', 'NativePanelRunner', '-configuration', 'Debug',
               '-destination', 'platform=iOS,id=' + args.device, '-derivedDataPath', str(build),
               '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration',
               'DEVELOPMENT_TEAM=' + args.team, 'PRODUCT_BUNDLE_IDENTIFIER=' + args.runner_bundle,
               'build-for-testing']
    print(json.dumps({'phase': 'building', 'output': str(out)}), flush=True)
    with (out / 'build.log').open('w') as log:
        status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
    config['build_exit_code'] = status
    if status:
        config['status'] = 'build_failed'; config_path.write_text(json.dumps(config, indent=2))
        raise SystemExit(status)
    targets = list((build / 'Build/Products').glob('*.xctestrun'))
    if len(targets) != 1:
        raise SystemExit('Expected one generated .xctestrun, found ' + str(len(targets)))
    data = plistlib.loads(targets[0].read_bytes())
    environment = {'NATIVE_ACCEPTANCE_SESSION': config['session'], 'SELA_DEBUG_SESSION': config['sela_session'],
                   'SELA_BUNDLE_ID': args.sela_bundle, 'OS_ACTIVITY_MODE': 'disable'}
    updated = 0
    for configuration in data.get('TestConfigurations', []):
        for target in configuration.get('TestTargets', []):
            target.setdefault('EnvironmentVariables', {}).update(environment); updated += 1
    if not updated:
        for name, target in data.items():
            if isinstance(target, dict) and target.get('TestBundlePath'):
                target.setdefault('EnvironmentVariables', {}).update(environment); updated += 1
    if not updated:
        raise SystemExit('No test target environment found.')
    targets[0].write_bytes(plistlib.dumps(data))
    config['status'] = 'running'; config['xctestrun'] = str(targets[0])
    config_path.write_text(json.dumps(config, indent=2))
    print(json.dumps({'phase': 'running', 'runner_bundle': config['runner_bundle']}), flush=True)
    command = ['xcodebuild', 'test-without-building', '-xctestrun', str(targets[0]), '-destination',
               'platform=iOS,id=' + args.device, '-resultBundlePath', str(out / 'operator-session.xcresult'),
               '-parallel-testing-enabled', 'NO']
    with (out / 'operator.log').open('w') as log:
        status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
    config['status'] = 'ended' if status == 0 else 'session_failed'; config['test_exit_code'] = status
    config['ended_at_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    config_path.write_text(json.dumps(config, indent=2)); print(json.dumps({'phase': config['status'], 'exit_code': status}), flush=True)


if __name__ == '__main__':
    main()
