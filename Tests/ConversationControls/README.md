# Conversation control ownership

Run `bash Tests/ConversationControls/run.sh`. `PHONE_TEST_SOURCE_ROOT` selects a saved source baseline for before/after comparisons.

The test extracts complete production VM routing, context, dispatch and resume methods, plus the actual interaction observers. It does not replace statements inside those methods. The surrounding engine, queue, audio, consent and router are explicitly synthetic. Independent route continuations freeze task state before returning a valid route. Release-wait cases run the original asynchronous resume loop against bounded local fixtures.

Coverage includes changed tasks and same-ID execution changes, A→B→A, idle-to-active transitions, preparation/voice/queue/manual/calibration/consent changes, dispatch and deferred-resume gaps, unknown/inactive targets, JSON ownership loss and ordinary unchanged task progress. Positive cases retain same-task controls, explicit resumable queued targets, no-record preparation pause/stop, chat/flight/new-task routing and existing resume readiness restrictions.

No network/model requests, persisted real queues, microphones, real credentials, account access, phone inputs or installations occur. This is extracted-method evidence, not complete VM/UI/voice/queue or phone acceptance. Failed attempts retain their executable, source copies, extraction hashes and result JSON in the printed temporary directory.
