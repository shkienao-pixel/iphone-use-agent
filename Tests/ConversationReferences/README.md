# Bounded historical references

Run `bash Tests/ConversationReferences/run.sh`; `PHONE_TEST_SOURCE_ROOT` selects a saved production baseline for before/after replay.

The complete saved `unifiedTaskContext` method is extracted without substitutions. Task containers are explicitly synthetic. Ctrip response decoding/flight parsing, transactional conversation storage, routing input, semantic router and both model request clients run their actual production code; only the HTTP loader bodies use the existing local wire collector.

Cases cover valid multi-query flight history that previously exceeded 64,000 reference characters, complete 4,000-character queries and latest questions, flight numbers inside very long titles, ending date/passenger constraints, JSON escapes, CRLF, Chinese, joined emoji, enormous combining graphemes, offer ordering, task relevance and lossless storage of original cards. Serialized request checks include bounded historical bytes and exactly one local HTTP boundary call.

Reference excerpts retain both ends and explicitly mark omitted text. Character and byte budgets apply only to historical request data. Original cards, task records, saved messages and the latest human question remain intact. This does not measure model routing quality, real provider compatibility, phone UI, account access or task completion. No network requests, real credentials, microphone, real queue or phone actions occur. Failed attempts preserve executable/source/hash/result evidence in the printed temporary directory.
