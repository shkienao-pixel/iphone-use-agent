#!/usr/bin/env python3
"""Audit saved Health evidence locally. Does not establish capture provenance or UI acceptance."""
import argparse
import collections
import datetime
import hashlib
import json
import math
from pathlib import Path
import uuid

SCOPES = {'steps', 'sleep', 'workouts'}
IDENTITY_FIELDS = {'source', 'receipt_id', 'type', 'start', 'end', 'coverage', 'result_sha256', 'result_utf8_bytes'}


def load(path):
    if path.stat().st_size > 32_000_000:
        raise ValueError('Evidence file exceeds the local audit size bound')
    return json.loads(path.read_text())


def instant(value):
    if not isinstance(value, str):
        raise ValueError('Expected an ISO timestamp')
    parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.utcoffset() is None:
        raise ValueError('Timestamp has no timezone')
    return parsed


def integer(value):
    return type(value) is int


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_result(body):
    if body.get('source') != 'HealthKit' or body.get('coverage') != 'visible_data_only':
        raise ValueError('Unexpected native source or coverage')
    start, end = instant(body['start']), instant(body['end'])
    if not start < end or (end - start).total_seconds() > 31 * 86400:
        raise ValueError('Invalid native read bounds')
    if not isinstance(body.get('notice'), str) or not body['notice']:
        raise ValueError('Missing source limitation')
    scope = body['type']
    if scope == 'steps':
        value = body['steps']
        if type(body['has_visible_data']) is not bool or not (value is None or integer(value) and value >= 0):
            raise ValueError('Invalid step value type')
        if body['has_visible_data'] != (value is not None):
            raise ValueError('Visible-data flag contradicts the step value')
    elif scope == 'sleep':
        value = body['asleep_seconds']
        if not (value is None or number(value) and value >= 0):
            raise ValueError('Invalid sleep duration')
        if not integer(body['visible_sample_count']) or not 0 <= body['visible_sample_count'] <= 1000:
            raise ValueError('Invalid visible sleep sample count')
        if type(body['truncated']) is not bool or body['overlapping_intervals_merged'] is not True:
            raise ValueError('Invalid sleep coverage flags')
    elif scope == 'workouts':
        rows = body['matches']
        if not isinstance(rows, list) or not integer(body['returned_count']) or body['returned_count'] != len(rows) or len(rows) > 20:
            raise ValueError('Invalid workout rows or count')
        if type(body['truncated']) is not bool:
            raise ValueError('Invalid workout truncation flag')
        for row in rows:
            if not integer(row['activity_type']) or row['activity_type'] < 0 or not instant(row['start']) < instant(row['end']):
                raise ValueError('Invalid workout type or timestamps')
            if not number(row['duration_seconds']) or row['duration_seconds'] < 0:
                raise ValueError('Invalid workout duration')
    else:
        raise ValueError('Unsupported Health scope')
    return start, end, scope


def audit(task_id, snapshots, receipts, expected=None, before_receipts=None, final_record=None):
    """Strict consistency audit; a torn live copy must be captured again, never repaired."""
    if str(uuid.UUID(task_id)).upper() != task_id:
        raise ValueError('Expected canonical task identity')
    logs = {}
    for snapshot in snapshots:
        record = next((r for r in snapshot['records'] if r['id'] == task_id), None)
        if record:
            for entry in record['logs']:
                if entry['id'] in logs and logs[entry['id']] != entry:
                    raise ValueError('A captured original log was changed')
                logs[entry['id']] = entry
    raw = sorted((e for e in logs.values() if e['title'] == '工具回执'), key=lambda e: (e['step'], e['date']))
    steps = [e['step'] for e in raw]
    if len(steps) != len(set(steps)):
        raise ValueError('Two native results occupy the same action step')
    by_hash, ranges, counts = {}, collections.defaultdict(set), collections.Counter()
    bounds = []
    for entry in raw:
        text = entry['detail']
        if len(text.encode()) > 48_000:
            raise ValueError('Native Health result exceeds its completion identity bound')
        body = json.loads(text)
        start, end, scope = validate_result(body)
        digest = hashlib.sha256(text.encode()).hexdigest()
        by_hash.setdefault(digest, []).append((entry, body))
        bounds.append((start, end, scope))
        ranges[(start, end)].add(scope)
        counts[scope] += 1
    if expected is not None:
        plan = [(instant(span['start']), instant(span['end']), scope) for span in expected['ranges'] for scope in expected['scopes']]
        if bounds != plan[:len(bounds)] or len(bounds) > len(plan):
            raise ValueError('Actual native bounds/order differ from the declared plan')
    matched = {}
    for key, receipt in receipts.items():
        if not key.startswith(task_id + ':health-read:'):
            continue
        identity = receipt.get('healthReadIdentity')
        if not isinstance(identity, dict) or set(identity) != IDENTITY_FIELDS:
            raise ValueError('Invalid read identity fields')
        if receipt['state'] != 'completed' or key != task_id + ':health-read:' + receipt['id']:
            raise ValueError('Incomplete or mismatched read identity')
        if identity['source'] != 'HealthKit completed read metadata' or identity['receipt_id'] != receipt['id'] or json.loads(receipt['result']) != identity:
            raise ValueError('Metadata result is not bound to its receipt identity')
        digest = identity['result_sha256']
        if digest not in by_hash:
            raise ValueError('Metadata lacks a unique captured full native result; inspect the capture boundary')
        entry, body = by_hash[digest][0]
        if type(identity['result_utf8_bytes']) is not int or identity['result_utf8_bytes'] != len(entry['detail'].encode()):
            raise ValueError('Full native UTF8 length differs')
        if any(identity[k] != body[k] for k in ('type', 'start', 'end', 'coverage')):
            raise ValueError('Metadata type/bounds/coverage differ from the actual result')
        matched.setdefault(digest, []).append(identity)
    if {k: len(v) for k, v in matched.items()} != {k: len(v) for k, v in by_hash.items()}:
        raise ValueError('A captured actual result lacks completed durable metadata')
    if before_receipts is not None and any(receipts.get(k) != v for k, v in before_receipts.items()):
        raise ValueError('An earlier receipt changed or was removed')
    report_matched = False
    if final_record is not None and final_record['outcome'] == 'completed' and expected is not None:
        try:
            summary = json.loads(final_record['summary'])
            if not isinstance(summary, dict):
                summary = {}
        except (ValueError, TypeError):
            summary = {}
        wanted = {'completed_ranges': len(expected['ranges']), 'completed_reads': len(bounds), 'failed_reads': 0, 'unknown_reads': 0, 'not_executed_reads': 0}
        report_matched = len(bounds) == len(expected['ranges']) * len(expected['scopes']) and all(type(summary.get(k)) is int and summary[k] == value for k, value in wanted.items()) and isinstance(summary.get('notice'), str) and bool(summary['notice'])
    return {'actualCompletedReadsAudited': len(raw), 'hasActualCompletedResultEvidence': bool(raw),
            'actualCompleteThreeScopeRanges': sum(scopes == SCOPES for scopes in ranges.values()),
            'actualCompletedReadsByScope': dict(counts), 'allFullResultSHA256UTF8AndJSONTypesMatched': True,
            'earlierReceiptsRetained': before_receipts is not None, 'declaredBoundsOrderVerified': expected is not None,
            'terminalCounterReportMatched': report_matched, 'savedEvidenceConsistencyPassed': True,
            'deviceProvenanceEstablishedByThisOfflineScript': False, 'physicalInputOrCardUIAcceptance': False,
            'privateHealthValuesAndQueryDatesOmitted': True}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case-directory', required=True, type=Path)
    p.add_argument('--task', required=True)
    p.add_argument('--manifest', type=Path)
    p.add_argument('--terminal-evidence', type=Path)
    p.add_argument('--output', required=True, type=Path)
    args = p.parse_args()
    case = args.case_directory.resolve()
    if args.terminal_evidence:
        terminal = args.terminal_evidence.resolve()
    else:
        latest = load(case / 'latest-observation.json')
        terminal = (case.parent / latest['observation']).resolve()
    if case not in terminal.parents:
        raise ValueError('Evidence snapshot must remain inside its case directory')
    live = terminal.parent == case / 'observations'
    snapshots = [load(path) for path in sorted((case / 'observations').glob('*/tasks.json'))
                 if not live or path.parent.name <= terminal.name]
    tasks = load(terminal / 'tasks.json')
    snapshots.append(tasks)
    record = next(r for r in tasks['records'] if r['id'] == args.task)
    before = case / 'before-evidence/receipts.json'
    result = audit(args.task, snapshots, load(terminal / 'receipts.json'), load(args.manifest) if args.manifest else None,
                   load(before) if before.exists() else None, record)
    result['taskOutcome'] = record['outcome']
    # Do not overwrite an earlier result, especially a failed/partial attempt.
    with args.output.open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
