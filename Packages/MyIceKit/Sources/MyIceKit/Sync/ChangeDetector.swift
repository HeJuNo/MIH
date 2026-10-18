import Foundation

/// Pure diff between two sync generations.
///
/// Rules:
/// * Detail fields are compared only when both generations have a detail, so a
///   failed `/getevent` call never produces phantom changes.
/// * A vanished event is reported as removed only if it was still in the future;
///   past events simply age out of `app_data`.
/// * New events are reported only if they have not started yet.
public enum ChangeDetector {
    public static func diff(old: [TrackedEntry], new: [TrackedEntry], now: Date = .now) -> [EventChange] {
        let oldByKey = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newKeys = Set(new.map(\.id))
        var changes: [EventChange] = []

        for entry in new {
            guard let previous = oldByKey[entry.id] else {
                if isUpcoming(entry, now: now) {
                    changes.append(EventChange(entry: entry, detectedAt: now, kind: .added))
                }
                continue
            }
            changes += diff(previous, entry, now: now).map { EventChange(entry: entry, detectedAt: now, kind: $0) }
        }

        for entry in old where !newKeys.contains(entry.id) && isUpcoming(entry, now: now) {
            changes.append(EventChange(entry: entry, detectedAt: now, kind: .removed))
        }
        return changes
    }

    static func isUpcoming(_ entry: TrackedEntry, now: Date) -> Bool {
        guard let start = EventDates.start(of: entry.event) else { return true }
        return start > now
    }

    static func diff(_ a: TrackedEntry, _ b: TrackedEntry, now: Date) -> [ChangeKind] {
        var out: [ChangeKind] = []
        let ea = a.event, eb = b.event

        if let old = ea.name, let new = eb.name, norm(old) != norm(new) {
            out.append(.renamed(old: old, new: new))
        }

        let dayA = EventDates.parseDay(ea.date), dayB = EventDates.parseDay(eb.date)
        if dayA != dayB, dayA != nil || dayB != nil {
            out.append(.date(old: dayA, new: dayB))
        }

        let timeA = timeRange(ea), timeB = timeRange(eb)
        if timeA != timeB { out.append(.time(old: timeA, new: timeB)) }

        if norm(ea.place) != norm(eb.place) {
            out.append(.place(old: ea.place ?? "", new: eb.place ?? ""))
        }

        // Status fields are present on the list row; prefer them over the detail
        // so they are tracked even for events outside the detail horizon.
        let availA = ea.available ?? 0, availB = eb.available ?? 0
        if availA != availB { out.append(.attendance(old: availA, new: availB)) }

        let healthA = ea.healthStatus ?? 0, healthB = eb.healthStatus ?? 0
        if healthA != healthB { out.append(.healthStatus(old: healthA, new: healthB)) }

        guard let da = a.detail, let db = b.detail else { return out }

        if norm(da.departureTime) != norm(db.departureTime) {
            out.append(.departure(label: db.departure, old: da.departureTime ?? "", new: db.departureTime ?? ""))
        }
        if norm(da.meetingTime) != norm(db.meetingTime) {
            out.append(.meeting(label: db.meeting, old: da.meetingTime ?? "", new: db.meetingTime ?? ""))
        }

        let notesA = PlainText.from(html: da.notes), notesB = PlainText.from(html: db.notes)
        if notesA != notesB, !notesB.isEmpty { out.append(.notes(new: notesB)) }

        let playersA = players(da), playersB = players(db)
        if playersA.isEmpty, !playersB.isEmpty {
            out.append(.rosterPublished(players: playersB.count))
        } else if !playersA.isEmpty {
            let added = playersB.subtracting(playersA).sorted(), removed = playersA.subtracting(playersB).sorted()
            if !added.isEmpty || !removed.isEmpty { out.append(.players(added: added, removed: removed)) }
        }

        let staffA = staff(da), staffB = staff(db)
        if !staffA.isEmpty || !staffB.isEmpty, staffA != staffB {
            out.append(.staff(added: staffB.subtracting(staffA).sorted(), removed: staffA.subtracting(staffB).sorted()))
        }

        let seen = Set((da.notifications ?? []).compactMap(\.idNotification))
        for n in db.notifications ?? [] where !(n.idNotification.map(seen.contains) ?? true) {
            out.append(.message(subject: n.subject ?? "", body: n.message ?? ""))
        }
        return out
    }

    static func timeRange(_ e: Event) -> String {
        let s = EventDates.shortTime(e.timeStart), t = EventDates.shortTime(e.timeEnd)
        return t.isEmpty ? s : "\(s)–\(t)"
    }

    static func players(_ d: EventDetail) -> Set<String> {
        Set((d.convocation?.available ?? []).map { "\($0.fname ?? "") \($0.lname ?? "")".trimmingCharacters(in: .whitespaces) })
    }

    static func staff(_ d: EventDetail) -> Set<String> {
        Set((d.convocation?.staff ?? []).map { "\($0.fname ?? "") \($0.lname ?? "")".trimmingCharacters(in: .whitespaces) })
    }

    static func norm(_ s: String?) -> String {
        (s ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

/// Minimal HTML → text used for comparison and notification bodies.
public enum PlainText {
    public static func from(html: String?) -> String {
        guard var s = html, !s.isEmpty else { return "" }
        s = s.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        while let r = s.range(of: #"&#x?[0-9A-Fa-f]+;"#, options: .regularExpression) {
            let token = s[r].dropFirst(2).dropLast()
            let value = token.first == "x" ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
            s.replaceSubrange(r, with: value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
        }
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
