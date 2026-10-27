# Typed running-errand read results

Run `Tests/PaotuiQuery/run.sh`. It compiles the production data models and query
projection directly, with their actual shared dependencies. No network, device,
credentials or order submission is used.

Fixtures cover complete and partial address/POI/quote/status envelopes, escaped
Unicode and long strings, multiple output budgets, exact atomic references,
explicit unknown purchase costs, known no-purchase send costs, defensive invalid
fees/services, and both rendered and retained projection privacy. An impossible
metadata budget must throw rather than return invalid JSON or exceed the limit.
