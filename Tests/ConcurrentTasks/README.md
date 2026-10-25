# Concurrent native tasks

Run `bash Tests/ConcurrentTasks/run.sh` on macOS with Xcode command-line tools.

This compiles the actual background coordinator, resource gate, permission/screen policy,
and full AgentEngine (only `UIKit` is replaced by `CoreGraphics` for the offline image fixture).
The approval test extracts the exact production ToolApproval structure, decide method and
approval/cancellation block without changing their bodies.

Coverage includes three simultaneous workers and a queued fourth, per-task pause/stop/resume,
stale-session rejection, independent origins/receipts, actual engine tool dispatch overlap,
selected native recovery, persisted lane provenance with no restored execution authority,
resource conflict exclusion, cancellation cleanup, approval-owner cancellation, rejecting a
late click from an old approval, and no shared BLE releases or pointer invalidation.
The permission fixture exercises the real no-screen policy with synthetic OS grant states.

The model and native service responses, permission states, capture, and BLE are synthetic.
These checks do not measure model intent accuracy, iOS background runtime guarantees,
physical-device behavior, or real calendar/contact/travel service correctness.
