# Screen task queue

Run `bash Tests/ScreenTaskQueue/run.sh` with Xcode command-line tools.
The fixture compiles the complete production VM queue extension without body substitutions,
the full actual AgentEngine (UIKit import adapted to the offline image fixture), and actual
queue/history stores. Model, capture, BLE and UI/application state are synthetic.

The screen queue pins the current task and permits reordering, pausing, terminating and
removing future tasks while it runs. A per-item pause is a persisted hold and blocks later
tasks. Starting one item restores its place only; global start grants queue execution.
Global pause preserves checkpoints/order. Legacy native work is excluded from this queue.
Terminal history repairs stale queue checkpoints before any restoration, and persistence
failures stop automatic advance. Active cancellation still revokes input even if saving fails.

Tests cover real engine progression/order, the input-release transition window, stale controls,
per-item/global pause, restart, native isolation, terminal reconciliation and storage failures.
They are offline checks, not real model intent accuracy, iPhone/BLE acceptance or sustained
execution guarantees while iOS suspends the app.
