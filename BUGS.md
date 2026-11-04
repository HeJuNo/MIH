# Bug list

Open issues found in real (non-demo) usage, not yet root-caused with certainty. Each entry: symptom, when/where seen, what's been traced in code, what's still needed to confirm.

## Fixed, am Gerät zu überprüfen

### Day-group header says "Morgen" for an event that is actually today

Reported 2026-11-03, live account, *Spiele & Trainings*. Device clock and header both show Dienstag, 3. November (today); the "Als Nächstes" card correctly says "in 5 Stunden" for the 17:00 Eistraining, but the day-section below the same event is headed "Dienstag, 3. November — **Morgen**" instead of "— Heute".

Not reproducible with demo data — demo's day labels were correct in a same-day check (`-demoTab schedule`, Nov 3 host clock), so this isn't a bug in the label logic itself (`DayHeader.relative` / `Calendar.current.isDateInToday`), and the fix below can't be re-demonstrated in the Simulator with demo data either — it only shows up when the backend's `date` and `datetime` fields genuinely disagree, which demo data never does.

**Root cause, confirmed by code inspection** (`Packages/MyIceKit/Sources/MyIceKit/Domain/EventDates.swift`): `start(of:)` — used by the "Als Nächstes" card and detail views — prefers the event's full `datetime` field, falling back to `date` + `time_start` only if `datetime` is absent. `groupedByDay(_:)` — used for the day-section headers — did the opposite: it preferred the bare `date` field, falling back to `start(of:)` only if `date` was unparseable. A `date`/`datetime` disagreement from the backend (e.g. a UTC-midnight boundary effect on the server for an evening event) therefore put the two call sites on different calendar days for the same event.

**Fixed 2026-11-03**: `groupedByDay` now prefers `datetime` the same way `start(of:)` and `end(of:)` already do (`start(of: e) ?? parseDay(e.date)`), so all three agree by construction. Covered by a new regression test, `EventDatesTests.testGroupedByDayAgreesWithStartOfWhenDateAndDatetimeDisagree` (`Packages/MyIceKit/Tests/MyIceKitTests/EventDatesTests.swift`), which fails on the old code and passes on the new.

**Am Gerät zu überprüfen**: confirm on the real account, over a few days, that the day-section header and the "Als Nächstes" card always agree again (no raw payload capture was taken to confirm the exact `date`/`datetime` values that triggered this, so this is a plausible, tested fix rather than a confirmed one).
