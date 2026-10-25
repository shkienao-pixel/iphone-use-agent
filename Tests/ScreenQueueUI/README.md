# Screen queue UI acceptance

Run only against a dedicated simulator with the built Sela app installed. The
test uses the explicit `screen-queue` preview with synthetic queue records; it
never starts a model or screen task. It verifies real drag/drop, persisted order
and per-item pause, removal, the chat header entry, and preservation of a new
chat draft while the actual global queue sheet opens.

```sh
xcodebuild -project Tests/ScreenQueueUI/ScreenQueueRunner.xcodeproj \
  -scheme ScreenQueueRunner -destination 'platform=iOS Simulator,id=DEDICATED_UUID' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The synthetic queue must initially be empty. The test removes only its three
fixed fixture IDs. Native task execution and FIFO scheduling are verified by
the separate queue controller tests, using synthetic model/platform boundaries.
