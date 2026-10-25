# Conversation task ownership

Run `bash Tests/ConversationTaskOwnership/run.sh`; `PHONE_TEST_SOURCE_ROOT` selects a saved production baseline.

The actual conversation service and transactional store run unchanged. Complete controller focus, context, record callback, start, automatic preparation, consent, cancel, stop and pause methods are extracted without statement substitutions. Engine, readiness, settings UI, capture, BLE and audio are explicit synthetic boundaries. A small entry adapter passes the original baseline message/goal tuple or the new reserved task/chat/message submission; it is outside production methods and recorded in extraction metadata.

Coverage includes real send/new/open/store lifecycle, delayed task creation, same-text different-UUID records, per-chat focus including explicit task-page selection, clearing and later-message ordering, links outside the recent routing window, process restart without execution authority, preparation and consent cancellation, old cleanup after replacement, current draft and live answer preservation, cleared/conflicting messages, and historical-link storage failure. The actual engine's reserved record/metrics identity is checked separately in `Tests/ProductState`.

No real network/model, account, microphone, persisted user queue or phone actions occur. These are controller-method/service/store checks, not complete VM initialization, SwiftUI, actual readiness/hardware, model quality or phone acceptance. Failed runs retain executable, production source copies, metadata, fixture files and raw results in the printed temporary directory.
