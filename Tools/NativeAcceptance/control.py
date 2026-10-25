#!/usr/bin/env python3
"""Send bounded operator commands over CoreDevice app-container transfer."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def transfer(config, direction, source, destination, bundle):
    return subprocess.run(['xcrun', 'devicectl', 'device', 'copy', direction, '--device', config['device'],
                           '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                           '--source', str(source), '--destination', str(destination)], capture_output=True)


def sela_state(config, out):
    target = out / 'sela-state.json'
    result = transfer(config, 'from', 'Documents/SelaDeviceDebug/state.json', target, config['sela_bundle'])
    if result.returncode:
        raise RuntimeError('Sela diagnostic state unavailable; launch_sela first.')
    state = json.loads(target.read_text())
    if state.get('session') != config['sela_session'] or time.time() - state.get('date', 0) > 20:
        raise RuntimeError('Sela state is stale or belongs to another operator session.')
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True, type=Path)
    parser.add_argument('operation')
    parser.add_argument('--bundle')
    parser.add_argument('--element-type')
    parser.add_argument('--identifier')
    parser.add_argument('--text')
    parser.add_argument('--text-file', type=Path)
    parser.add_argument('--index', type=int)
    parser.add_argument('--x', type=float)
    parser.add_argument('--y', type=float)
    parser.add_argument('--frame-id')
    parser.add_argument('--expected-value')
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args()
    out = args.run.resolve(); config = json.loads((out / 'controller-session.json').read_text())
    if args.operation == 'state':
        state = sela_state(config, out)
        safe = ['active', 'model_ready', 'consent_ready', 'permissions', 'phase', 'step', 'engine_error',
                'notice', 'chat_loading', 'chat_error', 'tool_pending', 'tool_preview', 'current_task_id',
                'tools_only', 'continuous_execution', 'confirm_each_step', 'ble_ready', 'capture_running']
        safe += ['engine_releasing', 'execution_settled', 'health_authorization_pending']
        safe += ['model_authentication', 'chatgpt_plan_authorized', 'chatgpt_access_expires_at', 'chatgpt_model_count', 'chatgpt_last_http_failure']
        safe += ['chatgpt_protocol_diagnostics']
        print(json.dumps({k: state.get(k) for k in safe}, ensure_ascii=False)); return
    # One writer per mailbox. In-flight CoreDevice copies must never be
    # overwritten by another UI command before their exact result arrives.
    debug_operations = ('stop_task', 'check_model', 'check_plan_inference', 'navigate', 'automatic_execution', 'stop_alarm_card_fixture_a09')
    lock = (out / ('.sela-command.lock' if args.operation in debug_operations else '.operator.lock')).open('a+')
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('Another command is still in flight. Await its result and inspect state before continuing.')
    lock.seek(0); lock.truncate()
    lock.write(json.dumps({'pid': os.getpid(), 'operation': args.operation, 'startedAt': time.time()})); lock.flush()
    if args.operation == 'start_task':
        state = sela_state(config, out)
        if state.get('execution_settled') is False or state.get('engine_releasing') or state.get('phase') not in ('idle', 'completed', 'failed', 'stopped', 'preview') or state.get('chat_loading') or state.get('tool_pending'):
            raise RuntimeError('Current task is not settled. Stop/pause/review it before starting another task.')
    if args.operation in debug_operations:
        sela_state(config, out)
        command = {'id': str(uuid.uuid4()), 'session': config['sela_session'], 'operation':
                   {'stop_task': 'stop', 'check_model': 'check_model', 'check_plan_inference': 'check_plan_inference', 'navigate': 'navigate', 'automatic_execution': 'automatic_execution', 'stop_alarm_card_fixture_a09': 'stop_alarm_card_fixture_a09'}[args.operation],
                   'expiresAt': time.time() + 14}
        if args.text: command['value'] = args.text
        path = out / 'sela-command.json'; path.write_text(json.dumps(command))
        status = transfer(config, 'to', path, 'Documents/SelaDeviceDebug/command.json', config['sela_bundle'])
        # The receiver may consume/remove command.json while CoreDevice is still
        # verifying the copy. Check the nonce-bound acknowledgement before
        # declaring failure; never resend a mutation automatically.
        deadline = time.monotonic() + min(args.timeout, 60)
        while time.monotonic() < deadline:
            time.sleep(0.35)
            state = sela_state(config, out)
            if state.get('command') == command['id']:
                print(json.dumps({'operation': args.operation, 'acknowledged': True, 'phase': state.get('phase'),
                                  'step': state.get('step'), 'error': state.get('error')}, ensure_ascii=False)); return
        raise RuntimeError('Diagnostic acknowledgement timed out. Transfer status: ' + str(status.returncode) + '. Inspect state before retrying.')
    # Swift UUID.uuidString is uppercase; use the same spelling for result paths.
    command = {'id': str(uuid.uuid4()).upper(), 'session': config['session'], 'operation': args.operation, 'expiresAt': time.time() + 60}
    for key in ('bundle', 'element_type', 'identifier', 'index', 'x', 'y', 'frame_id', 'expected_value'):
        value = getattr(args, key)
        if value is not None: command[{'element_type': 'elementType', 'frame_id': 'frameID', 'expected_value': 'expectedValue'}.get(key, key)] = value
    text = args.text_file.read_text() if args.text_file else args.text
    if text is not None: command['text'] = text
    path = out / 'operator-command.json'; path.write_text(json.dumps(command, ensure_ascii=False))
    sent = transfer(config, 'to', path, 'Documents/NativeAcceptance/command.json', config['runner_bundle'])
    # Even a failed copy can have reached the operator. Await its exact result
    # rather than risk repeating a tap/start/write after a file-removal race.
    result_path = out / ('result-' + command['id'] + '.json')
    deadline = time.monotonic() + min(args.timeout, 120)
    while time.monotonic() < deadline:
        time.sleep(0.25)
        result = transfer(config, 'from', 'Documents/NativeAcceptance/' + result_path.name, result_path, config['runner_bundle'])
        if result.returncode: continue
        value = json.loads(result_path.read_text())
        if value.get('id') != command['id'] or value.get('session') != config['session']: continue
        for key in ('image', 'tree'):
            if value.get(key):
                name = value[key]
                if Path(name).name != name: raise RuntimeError('Invalid attachment name in result.')
                if transfer(config, 'from', 'Documents/NativeAcceptance/' + name, out / name, config['runner_bundle']).returncode:
                    raise RuntimeError('Attachment transfer failed.')
                value[key] = str(out / name)
        print(json.dumps(value, ensure_ascii=False))
        if not value.get('ok'): raise SystemExit(1)
        return
    raise RuntimeError('Operator command timed out. Inspect current device state before retrying a mutation.')


if __name__ == '__main__':
    main()
