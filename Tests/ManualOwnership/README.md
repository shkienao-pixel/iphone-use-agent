# Current-source extracted-method manual ownership checks

This target extracts the complete current VM manualAction, pauseTask, stop and
cancelVoicePreparation, plus the entire current BLE releaseController property
and release method, without modifying their bytes. It compiles the current
Shared/InputReleaseController.swift. No historical production copies or fixed
production SHA allowlist are embedded in this test.

Before extraction/compilation, InputIdentity.py captures the whole current VM,
BLE and controller files plus the complete recursive target file set (including
extractor, environment/data, main, identity helper and runner). Shell EXIT
recomputes bytes and membership against the captured manifest and separately
captured digest; additions/removals or a changed input reject the run. Legitimate
future source changes can be tested normally by a new invocation. Each run saves
fresh whole production snapshots and extracted method text as evidence.

The surrounding type is explicitly ExtractedManualOwnerScaffold. Engine, queue,
preparation/audio/camera, calibration flag and lower send/ACK are declared doubles.
The actual controller's fresh Task and exact VM guards/ownership/cleanup ordering
are exercised; this is not complete VM/SwiftUI/voice/queue/CoreBluetooth/ATT/HID
integration. A synthetic acknowledgement is not evidence of HID release.

The controls cover ignored and cooperative cancellation, pause versus stop
continuation semantics, busy ownership until both block and release settle,
second manual rejection, all original admission guards, success/error completion,
original connection capture, an existing writer held for 1.15 real seconds and
reconnect before/during cleanup. The 1.15s sleep is a minimum delay; no realtime
scheduler upper bound or mobile performance claim is implied.

Each case always cancels children, opens its gates and drains only synthetic I/O,
then uses 5-second monotonic polling of actual child-return monitors before
joining. Gate wait has a separate 5-second deadman despite ignoring cancellation.
No task group waits for a noncooperative child. Main, Environment and the 20-second
process runner with 3-second TERM/KILL fallback preserve the proven revision2
ownership scaffold; all error logs and timeout metadata survive failure.

Run `bash Tests/ManualOwnership/run.sh [fresh-results-directory]`. Evidence paths
are printed and preserved on success/failure; only disposable module cache is
removed. A read-only output candidate can use PHONE_TEST_SOURCE_ROOT to select
the explicit project root until this target is installed. The global check runner
must invoke this target only once. No network, phone, API key or user Documents
operation is performed.
