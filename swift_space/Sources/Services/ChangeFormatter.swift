import Foundation
import MyIceKit

/// Human-readable German text for a detected change.
enum ChangeFormatter {
    struct Text {
        var headline: String
        var detail: String
        var symbol: String
    }

    static func text(for change: EventChange) -> Text {
        switch change.kind {
        case .added:
            return Text(headline: "Neuer Termin", detail: when(change), symbol: "calendar.badge.plus")
        case .removed:
            return Text(headline: "Termin entfernt",
                        detail: "\(when(change)) ist nicht mehr in deinem Plan.", symbol: "calendar.badge.minus")
        case let .renamed(old, new):
            return Text(headline: "Titel geändert", detail: "„\(old)“ → „\(new)“", symbol: "textformat")
        case let .date(old, new):
            return Text(headline: "Datum geändert", detail: "\(day(old)) → \(day(new))", symbol: "calendar")
        case let .time(old, new):
            return Text(headline: "Uhrzeit geändert", detail: "\(dash(old)) → \(dash(new))", symbol: "clock")
        case let .place(old, new):
            return Text(headline: "Ort geändert", detail: "\(dash(old)) → \(dash(new))", symbol: "mappin.and.ellipse")
        case let .departure(label, old, new):
            return Text(headline: "\(label ?? "Abfahrt") geändert", detail: "\(dash(old)) → \(dash(new))", symbol: "bus")
        case let .meeting(label, old, new):
            return Text(headline: "\(label ?? "Treffpunkt") geändert", detail: "\(dash(old)) → \(dash(new))", symbol: "person.2.wave.2")
        case let .notes(new):
            return Text(headline: "Notizen aktualisiert", detail: new, symbol: "note.text")
        case let .attendance(_, new):
            return Text(headline: attendanceHeadline(new), detail: attendanceDetail(new), symbol: "light.beacon.max")
        case let .healthStatus(old, new):
            return Text(headline: "Status geändert",
                        detail: "\(StatusText.health(old)) → \(StatusText.health(new))", symbol: "heart.text.square")
        case let .rosterPublished(players):
            return Text(headline: "Aufgebot veröffentlicht",
                        detail: players == 1 ? "1 Spieler nominiert" : "\(players) Spieler nominiert", symbol: "person.3.sequence")
        case let .players(added, removed):
            return Text(headline: "Aufgebot geändert", detail: diffLine(added: added, removed: removed), symbol: "person.3")
        case let .staff(added, removed):
            return Text(headline: "Betreuer geändert", detail: diffLine(added: added, removed: removed), symbol: "person.badge.shield.checkmark")
        case let .message(subject, body):
            return Text(headline: subject.isEmpty ? "Neue Mitteilung" : "Mitteilung: \(subject)",
                        detail: body, symbol: "envelope.badge")
        }
    }

    static func categoryTitle(_ c: ChangeKind.Category) -> String {
        switch c {
        case .added: "Neue Termine"
        case .removed: "Entfernte Termine"
        case .schedule: "Datum, Uhrzeit & Abfahrt"
        case .info: "Ort, Titel & Notizen"
        case .status: "Anwesenheit & Status"
        case .people: "Aufgebot & Betreuer"
        case .message: "Mitteilungen"
        }
    }

    static func categorySymbol(_ c: ChangeKind.Category) -> String {
        switch c {
        case .added: "calendar.badge.plus"
        case .removed: "calendar.badge.minus"
        case .schedule: "clock"
        case .info: "mappin.and.ellipse"
        case .status: "light.beacon.max"
        case .people: "person.3"
        case .message: "envelope"
        }
    }

    // MARK: - Helpers

    private static func when(_ c: EventChange) -> String {
        let title = c.eventTitle.isEmpty ? "Termin" : c.eventTitle
        guard let start = c.eventStart else { return title }
        return "\(title) · \(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(.de)))"
    }

    private static func day(_ d: Date?) -> String {
        d?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.de)) ?? "–"
    }

    private static func dash(_ s: String) -> String { s.isEmpty ? "–" : s }

    private static func diffLine(added: [String], removed: [String]) -> String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("Neu: " + list(added)) }
        if !removed.isEmpty { parts.append("Nicht mehr dabei: " + list(removed)) }
        return parts.joined(separator: "\n")
    }

    private static func list(_ names: [String]) -> String {
        names.count <= 4 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " und \(names.count - 3) weitere"
    }

    private static func attendanceHeadline(_ v: Int) -> String {
        switch Availability(code: v) {
        case .requested: "Anwesenheit angefragt"
        case .confirmed: "Teilnahme bestätigt"
        case .declined: "Absage eingetragen"
        case .notRequested: "Anfrage zurückgezogen"
        }
    }

    private static func attendanceDetail(_ v: Int) -> String {
        switch Availability(code: v) {
        case .requested: "Der Trainer bittet um deine Rückmeldung."
        case .confirmed: "Du bist für diesen Termin eingeplant."
        case .declined: "Du bist für diesen Termin abgemeldet."
        case .notRequested: "Für diesen Termin ist keine Rückmeldung mehr nötig."
        }
    }
}

enum StatusText {
    static func health(_ code: Int?) -> String {
        switch code {
        case 1: "Gesund"
        case 3: "Dabei"
        case 6: "Entschuldigt"
        case 8: "Krank"
        case 9: "Verletzt"
        default: "–"
        }
    }

    static func availability(_ a: Availability) -> String {
        switch a {
        case .notRequested: ""
        case .requested: "Angefragt"
        case .confirmed: "Zugesagt"
        case .declined: "Abgesagt"
        }
    }
}

extension Locale {
    static let de = Locale(identifier: "de_AT")
}
