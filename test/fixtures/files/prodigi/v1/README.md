# Prodigi v1 fixtures -- hand-authored placeholders

These files are hand-authored from Prodigi's *documented* API v4 field names,
not captured from a real sandbox response. They exist only to exercise the
boundary/transport/mode-policy layer built in this phase. They are **not**
validated field-for-field against a real allowlist and must not be treated as
proof of Prodigi's actual response shape -- see `.planning/prodigi-captures/`
(produced by `bin/rails prodigi:capture` once a real sandbox credential is
available) for that evidence, and the later `contracts.rb`/`normalizer.rb`
phase that is derived from it.
