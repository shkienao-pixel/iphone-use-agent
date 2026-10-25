#!/usr/bin/env python3
"""Independent malformed, incomplete and pruned saved-evidence fixtures; no device/model calls."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('health_audit', ROOT / 'Tools/NativeAcceptance/audit_health_evidence.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(task, step=1, day=1, body=None):
    if body is None:
        body = {'source': 'HealthKit', 'coverage': 'visible_data_only', 'type': 'steps',
                'start': f'2024-01-{day:02d}T00:00:00+08:00', 'end': f'2024-01-{day+1:02d}T00:00:00+08:00',
                'notice': '仅可见数据🙂', 'steps': None, 'has_visible_data': False}
    text = json.dumps(body, ensure_ascii=False)
    receipt_id = str(uuid.uuid4()).upper()
    identity = {'source': 'HealthKit completed read metadata', 'receipt_id': receipt_id,
                **{k: body[k] for k in ('type', 'start', 'end', 'coverage')},
                'result_sha256': hashlib.sha256(text.encode()).hexdigest(), 'result_utf8_bytes': len(text.encode())}
    entry = {'id': str(uuid.uuid4()).upper(), 'title': '工具回执', 'step': step, 'date': step * 10.0, 'detail': text}
    receipt = {'id': receipt_id, 'state': 'completed', 'healthReadIdentity': identity, 'result': json.dumps(identity)}
    return entry, {task + ':health-read:' + receipt_id: receipt}


def snapshot(task, entries):
    return {'records': [{'id': task, 'logs': entries}]}


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.task = str(uuid.uuid4()).upper()
        self.entry, self.receipts = fixture(self.task)

    def audit(self, receipts=None, entries=None, **kwargs):
        return module.audit(self.task, [snapshot(self.task, entries or [self.entry])],
                            self.receipts if receipts is None else receipts, **kwargs)

    def test_full_utf8_hash_and_null_are_checked_without_device_claim(self):
        result = self.audit()
        self.assertEqual(result['actualCompletedReadsAudited'], 1)
        self.assertFalse(result['deviceProvenanceEstablishedByThisOfflineScript'])
        self.assertFalse(result['physicalInputOrCardUIAcceptance'])

    def test_boolean_is_not_a_step_integer(self):
        body = json.loads(self.entry['detail']); body.update(steps=True, has_visible_data=True)
        entry, receipts = fixture(self.task, body=body)
        with self.assertRaises(ValueError): self.audit(receipts, [entry])

    def test_empty_result_cannot_be_converted_to_zero(self):
        body = json.loads(self.entry['detail']); body['steps'] = 0
        entry, receipts = fixture(self.task, body=body)
        with self.assertRaises(ValueError): self.audit(receipts, [entry])

    def test_sleep_and_workout_null_counts_and_flags_remain_typed(self):
        common = json.loads(self.entry['detail'])
        common.pop('steps'); common.pop('has_visible_data')
        sleep = {**common, 'type': 'sleep', 'asleep_seconds': None, 'visible_sample_count': 0,
                 'truncated': False, 'overlapping_intervals_merged': True}
        workout = {**common, 'type': 'workouts', 'matches': [], 'returned_count': 0, 'truncated': False}
        for body in [sleep, workout]:
            entry, rows = fixture(self.task, body=body)
            self.assertEqual(self.audit(rows, [entry])['actualCompletedReadsAudited'], 1)
        malformed = [dict(sleep, asleep_seconds=False), dict(sleep, asleep_seconds=float('nan')),
                     dict(sleep, visible_sample_count=True), dict(sleep, truncated=1),
                     dict(workout, returned_count=False), dict(workout, returned_count=1)]
        for body in malformed:
            entry, rows = fixture(self.task, body=body)
            with self.assertRaises(ValueError): self.audit(rows, [entry])

    def test_full_hash_and_utf8_length_not_character_length(self):
        for field, value in [('result_sha256', '0' * 64), ('result_utf8_bytes', len(self.entry['detail']))]:
            receipts = copy.deepcopy(self.receipts); receipt = next(iter(receipts.values()))
            receipt['healthReadIdentity'][field] = value; receipt['result'] = json.dumps(receipt['healthReadIdentity'])
            with self.assertRaises(ValueError): self.audit(receipts)

    def test_independent_fresh_reads_can_return_identical_values(self):
        body = json.loads(self.entry['detail']); other, receipts = fixture(self.task, step=2, body=body)
        result = self.audit({**self.receipts, **receipts}, [self.entry, other])
        self.assertEqual(result['actualCompletedReadsAudited'], 2)

    def test_declared_nonrepeated_ranges_reject_a_repeated_read(self):
        body = json.loads(self.entry['detail']); other, receipts = fixture(self.task, step=2, body=body)
        plan = {'ranges': [{'start': body['start'], 'end': body['end']},
                           {'start': '2024-01-02T00:00:00+08:00', 'end': '2024-01-03T00:00:00+08:00'}], 'scopes': ['steps']}
        with self.assertRaises(ValueError): self.audit({**self.receipts, **receipts}, [self.entry, other], expected=plan)

    def test_other_task_receipts_do_not_inflate_current_counts(self):
        other = str(uuid.uuid4()).upper(); _, rows = fixture(other)
        self.assertEqual(self.audit({**self.receipts, **rows})['actualCompletedReadsAudited'], 1)

    def test_pruned_snapshots_are_unioned_without_recreating_logs(self):
        other, rows = fixture(self.task, step=2, day=2)
        result = module.audit(self.task, [snapshot(self.task, [self.entry]), snapshot(self.task, [other])], {**self.receipts, **rows})
        self.assertEqual(result['actualCompletedReadsAudited'], 2)
        changed = copy.deepcopy(self.entry); changed['detail'] += ' '
        with self.assertRaises(ValueError): module.audit(self.task, [snapshot(self.task, [self.entry]), snapshot(self.task, [changed])], self.receipts)

    def test_capture_boundary_or_missing_metadata_needs_new_readonly_capture(self):
        other, rows = fixture(self.task, step=2, day=2)
        with self.assertRaises(ValueError): self.audit({**self.receipts, **rows})
        with self.assertRaises(ValueError): self.audit({}, [self.entry])

    def test_previous_pending_receipt_is_retained(self):
        before = {'unrelated': {'id': 'not-used', 'state': 'pending'}}
        rows = {**self.receipts, 'unrelated': {'id': 'not-used', 'state': 'completed'}}
        with self.assertRaises(ValueError): self.audit(rows, before_receipts=before)

    def test_stopped_prefix_is_not_a_completed_report(self):
        body = json.loads(self.entry['detail']); plan = {'ranges': [{'start': body['start'], 'end': body['end']}], 'scopes': ['steps']}
        self.assertFalse(self.audit(expected=plan, final_record={'outcome': 'stopped', 'summary': '已停止'})['terminalCounterReportMatched'])
        summary = {'completed_ranges': 1, 'completed_reads': '1', 'failed_reads': 0, 'unknown_reads': 0, 'not_executed_reads': 0, 'notice': 'fixture'}
        self.assertFalse(self.audit(expected=plan, final_record={'outcome': 'completed', 'summary': json.dumps(summary)})['terminalCounterReportMatched'])
        summary['completed_reads'] = 1
        self.assertTrue(self.audit(expected=plan, final_record={'outcome': 'completed', 'summary': json.dumps(summary)})['terminalCounterReportMatched'])


if __name__ == '__main__':
    unittest.main()
