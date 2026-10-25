# Context read-only confirmation lease

Run `bash Tests/ContextLease/run.sh [results-directory]`. The optional directory
preserves generated extraction evidence, source hashes and all scenario results
(use a fresh directory for each run);
the default temporary directory is removed after the check. No device or API is
used. Each run verifies its current source-input hashes again on exit.

The target compiles current production Runtime/helper/raster code, extracts the
complete current Engine.observeAction, actual ScreenFrame declaration and native
CaptureService idle frame constructor. It adapts the existing ProductState host
environment locally; no other suite's files are changed. Host acquisition,
producer, BLE/Mouse and model remain explicit synthetic boundaries. It does not
replay the whole Engine lifecycle or prove actual ScreenCaptureKit idle delivery.

Real waits test confirmation reachability, not Vision/device speed. Controls keep
the original Engine frame unchanged, with no input, retry, workflow title ROI,
real model or network. Faults verify both the actual mutation and refusal; no
CancellationError is translated. Raw recognition cache reuse does not authorize
a confirmation. The default strict context is the current-source comparison for
the admitted context JSON; no historical or candidate Runtime is embedded.

The original OUTPUT-only 456-check historical baseline and its full before/after
sources remain preserved outside this permanent target. Current checks add 61
explicit mutation-execution assertions to close the independent peer's oracle
gap without altering those historical results. Full app compilation remains a
separate parent check for real VM provider wiring.
