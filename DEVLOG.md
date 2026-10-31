# Dev log — `feature/calendar-sync`

Running notes for this branch, kept so a new session (human or Claude) doesn't have to reconstruct context from commit messages alone.

## Shipped this round

1. **`347aa11`** — Roster changes in *Änderungen* always list every added/removed name in full; no more "und 5 weitere" truncation (`ChangeFormatter.list`, `ChangesView.ChangeLine`). Also: when an event's free-text notes contain "Treffpunkt" / "Treff" / "TP" plus a time but the structured `meeting_time` field is empty, a Treffpunkt sub-event is still created from that parsed time (`CalendarSync.meetingTimeInNotes`).
2. **`d2c8460`** — The Treffpunkt/Abfahrt sub-event title now mirrors the main event's "PREFIX TEAM Titel" shape (e.g. "PREFIX TEAM Treffpunkt") instead of "Treffpunkt: <full title>" (`CalendarSync.linkedTitle`). Added a per-team **Kürzel** (abbreviation), settable in Settings, substituted for the full club/team name in every calendar title (`SettingsStore.clubAbbreviations`, `AppState.setClubAbbreviation`).
3. **`986b202`** — Club logos are auto-cleaned: `LogoProcessing.cleaned` flood-fills a white/near-white background in from the four edges (never from the inside, so interior whites survive) and crops to what's left. Logos it can't confidently touch (colored background, photo, already-transparent) are left alone and can be replaced manually via `PhotosPicker`, stored per-club in `ClubLogoStore` (Application Support PNG). All per-team settings — Kürzel and logo editing — now live together in one submenu reached by tapping the team's name under *Konto* (`SettingsView.ClubSettingsView`), instead of being split across an inline picker and a separate list.

All three built clean (`BUILD SUCCEEDED`) and are pushed to `origin/feature/calendar-sync`.

## Open: no upcoming events after a real (non-demo) login

Reported 2026-10-30: after logging in with a real account in the Simulator, *Spiele & Trainings* shows only past entries, no upcoming ones.

Traced so far: `AppState.login()` → `refresh(reason: "login")` populates `state.entries` from `/refreshdata`; `importHistory(...)` populates `state.archive` separately via the web season-import endpoint. `SyncEngine.mergeHistory` filters out anything already "live" before archiving it, so it shouldn't be emptying `entries`. No code changes made — root cause unconfirmed.

**Next step, waiting on the user:** check whether the toolbar in *Spiele & Trainings* shows a red error icon instead of the refresh icon (would mean `/refreshdata` is failing silently), and what the last `sync` lines say in Einstellungen → Protokoll (`Club X: N events`, `Finished in …s: N events, M changes, archive K`) after enabling logging and pulling to refresh. Don't speculate further or change code until that comes back — it's just as likely the real API is genuinely returning zero upcoming events right now as it is a bug.

## Environment notes for whoever (or whatever) picks this up next

- **`xcodegen` isn't installable in a locked-down sandbox** (`brew install xcodegen` hits `/opt/homebrew` permission errors). Workaround: `gem install xcodeproj --user-install`, then a short Ruby script using the `xcodeproj` gem to add new `.swift` files to the `Sources/Services` group and `MyHockeyData` target directly in `project.pbxproj`. That file is git-ignored (`*.xcodeproj/`), so this is a local-only workaround — a normal `xcodegen generate` on a real Mac picks up new files the same way.
- **exFAT volume**: tracked files show spurious `100644 → 100755` mode diffs because exFAT can't store Unix permission bits. Fixed locally with `git config core.fileMode false`. AppleDouble `._*` junk files also appear after builds/copies — never git-tracked, safe to delete.
- **GitHub push**: no credential helper available in this sandbox (`git credential fill` is blocked outright — don't try to work around that, it's a deliberate restriction). Push via `https://x-access-token:${TOKEN}@github.com/HeJuNo/MIH.git`, with the token read from `credentials.txt` kept *outside* the repo. A fine-grained PAT's repo access is set server-side on GitHub when the token is created, not by anything in the local file.
- **Simulator**: this sandbox's Simulator runs headless — no Simulator GUI window, so no AppleScript/UI-injection screenshots of interactive flows (only what `-demo` launch-argument screens can show via `simctl launch` + `simctl io screenshot`). Available device types/runtimes have changed mid-session before (a one-off "iPhone Duo" device was briefly the only bootable option; iPhone 17 under iOS 27.0 later became normal).
