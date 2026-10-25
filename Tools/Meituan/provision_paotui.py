#!/usr/bin/env python3
"""Transfer an already approved, cached Passport credential to paired Sela.

Never prints or accepts a credential. The debug app must explicitly consume the
one-use payload with --import-paotui-config-once. Production uses native login.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--bundle-id', required=True)
    args = parser.parse_args()
    success = False
    try:
        result = subprocess.run(['pt-passport', 'get-token', '--client_id', 'ac76c22d257c4c6d9164719eea64ed4b', '--json'],
                                capture_output=True, timeout=15)
        payload = json.loads(result.stdout)
        token = payload.get('token', '')
        if result.returncode or payload.get('auth_mode') != 1 or not isinstance(token, str) or not token or len(token) > 8192:
            raise ValueError()
        with tempfile.TemporaryDirectory(prefix='sela-paotui-', dir='/private/tmp') as temporary:
            os.chmod(temporary, 0o700)
            path = Path(temporary) / 'paotui-config.once.json'
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, 'w') as stream:
                json.dump({'version': 1, 'token': token}, stream)
            result = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', args.device,
                                     '--source', str(path), '--destination', 'Documents/paotui-config.once.json',
                                     '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle_id],
                                    capture_output=True, timeout=90)
            success = result.returncode == 0
    except Exception:
        success = False
    print(json.dumps({'success': success}))
    return 0 if success else 1


if __name__ == '__main__':
    raise SystemExit(main())
