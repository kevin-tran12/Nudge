# Shopping and decision-engine instructions

These instructions supplement the repository root `AGENTS.md`.

- Use one general decision engine with category profiles/configuration; do not create a separate engine per category.
- Preserve the TRD flow from problem and structured requirements through decision-value clarification, retrieval, deterministic eligibility, soft ranking, evidence, and explanation.
- Ask only clarification questions likely to materially affect eligibility or ranking. Do not ask for every missing attribute.
- Requirements are first-class, visible, editable, removable, addable, and supersedable state.
- Historical preferences never silently become hard requirements.
- Hard eligibility outcomes are `PASS`, `FAIL`, or `UNKNOWN`. `UNKNOWN` on a hard requirement is not a verified match.
- Recommendations require evidence. Preserve the distinction between supplier observation, normalized fact, and inferred enrichment. Missing facts are not negative facts.
- Preserve supplier-native, canonical normalized, and localized display values/units.
- Changes to requirement/evidence models, eligibility semantics, clarification contracts, or ranking responsibility require architecture approval.
