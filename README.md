# MyHockey Data

A native iOS companion for **myice.hockey** player accounts. It shows your *Spiele & Trainings* and notifies you about every change: time, place, departure, lineup, attendance requests, club messages and more, even while the app is closed.

> Unofficial app. Not affiliated with the operators of myice.hockey.

## Phase 1 scope

| Area | What's included |
|---|---|
| **Spiele & Trainings** | Personal schedule grouped by day, "next up" hero card, filter (all / games / practices), status pills, pull-to-refresh |
| **Event detail** | **Overview** (attendance/status, place, date, time, departure and meeting point, notes, maps), **People** (staff and players grouped by goalie/defence/forward with jersey numbers), **Messages** (club messages plus a history of the changes detected for this event) |
| **Per-event notifications** | Bell toggle in the detail view, the list context menu and the detail header |
| **Change notifications** | Background refresh fetches the schedule and every upcoming entry's detail, diffs it against the last snapshot and posts **one notification per change**. Tapping a notification opens the event. |
| **Settings** | Default on/off for change notifications, per-category filters, notification permission, background interval, "check now", test notification, club switcher, logout |

Not in phase 1: changing your status or attendance, club calendar, multi-account.

## How change tracking works

```
BGAppRefreshTask ─► SyncCoordinator
                     ├─ POST /refreshdata          → app_data (Spiele & Trainings)
                     ├─ POST /getevent × upcoming   → details (≤ 40, 4 in parallel, 60-day horizon)
                     ├─ ChangeDetector.diff(old, new)
                     ├─ SyncStore (JSON, Application Support, readable after first unlock)
                     └─ ChangeNotifier → UNNotification per change (threaded by event)
```

* The **first sync**, and the first sync after switching clubs, only records a baseline, so you don't get a flood of notifications.
* Detail fields are only compared when both snapshots have a detail, so a failed request never produces phantom changes.
* A vanished event is reported as *removed* only if it hadn't started yet.
* Detected change types: new or removed event, title, date, time, place, departure, meeting point, notes, attendance request, health status, lineup published, players added/removed, staff, and new club messages.
* iOS decides when the background refresh actually runs. The interval in Settings is only the earliest possible gap. Background App Refresh must be enabled.

## Project layout

```
Packages/MyIceKit/        Swift package: API client, models, domain rules, sync engine (+ unit tests)
swift_space/              XcodeGen project for the iOS app
  project.yml
  Sources/App/            App entry, AppState, debug demo data
  Sources/Services/       Environment, settings, sync coordinator, notifications, background refresh
  Sources/Views/          SwiftUI screens
  Assets.xcassets/        App icon + colours
tools/icon/render_icon.swift   Regenerates the app icon (CoreGraphics)
fastlane/, .github/workflows/  Build & TestFlight pipeline (LightPods template)
```

## Building locally

```bash
brew install xcodegen
cd swift_space && xcodegen generate
open MyHockeyData.xcodeproj

# Unit tests for the core package
cd Packages/MyIceKit && swift test
```

In Debug builds, launch with the `-demo` argument to see sample data without an account (handy for screenshots).

## CI/CD (GitHub Actions + Fastlane)

This uses the same pipeline as [LightPods](https://github.com/HeJuNo/LightPods) and LoopWorkspace: browser-based builds to TestFlight on the self-hosted `xcode-27` runner.

| # | Workflow | Purpose |
|---|---|---|
| 1 | **Validate Secrets** | Checks GH_PAT, Match-Secrets, the App Store Connect API key and TEAMID |
| 2 | **Add Identifiers** | Creates the App ID `com.<TEAMID>.MyHockeyData` |
| 3 | **Create Certificates** | Fastlane Match distribution certificate and profile |
| 4 | **Build MyHockey Data Manual / Auto** | Build → sign → upload to TestFlight (manual, on push to `main`, or monthly) |

Required secrets: `GH_PAT`, `TEAMID`, `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY`, `MATCH_PASSWORD`.
Optional variables: `SCHEDULED_BUILD`, `ENABLE_NUKE_CERTS`, `FORCE_NUKE_CERTS`.

### First-time setup
1. Run **1. Validate Secrets**.
2. Run **2. Add Identifiers**.
3. In App Store Connect, create the app (**Apps → +**) with bundle ID `com.<TEAMID>.MyHockeyData`. TestFlight uploads need this app record, and the API key can't create it.
4. Run **3. Create Certificates**.
5. Run **4. Build MyHockey Data Manual**.

No App ID capabilities are needed: background refresh (`UIBackgroundModes: fetch`) and local notifications work without entitlements.
