# Precise session boundary replay

Host-only: no Xcode build, device, network or real model API. Compile whole production conversation/store plus verbatim extracted complete production context, route/action callbacks, action handler, pending helper, stop and pause methods. Peripheral, model, queue, engine and credential containers are offline doubles.

```sh
bash Tests/ConversationSessionIsolationPrecise/run.sh
```

The source root must include the production files and Tests/AssistantConversation/Environment.swift. For root-only native result additions, add their actual compile dependency and corresponding fixture-only type support; do not replace production methods. The shell runner uses a temporary directory and preserves it on failure. Set PHONE_TEST_SOURCE_ROOT to replay another integrated source; the Python entry also supports --source-root and writes evidence beside its runner.

Coverage is 17 targeted assertions: pending origin/ID/preparation lease, foreign rejection, stale lease, same-session multi-target ambiguity with explicit-focus/ID compatibility, compressed pending row preservation, and actual asynchronous A stop -> B loading isolation with drafts and messages plus UI zero-argument stop behavior. This is offline evidence; it does not establish device or live-model acceptance.
