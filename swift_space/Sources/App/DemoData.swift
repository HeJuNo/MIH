#if DEBUG
import Foundation
import MyIceKit
import UIKit

/// Sample content for simulator screenshots: launch with `-demo`.
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    /// Screenshot deep links: `-demoDetail <index>`, `-demoSection people|messages`, `-demoStatus`, `-demoPast`,
    /// `-demoFilter all|games|practices`, `-demoClub <id>`.
    static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static var detailIndex: Int? { value(after: "-demoDetail").flatMap(Int.init) }
    static var section: String? { value(after: "-demoSection") }
    static var opensStatus: Bool { isEnabled && ProcessInfo.processInfo.arguments.contains("-demoStatus") }
    static var opensPast: Bool { isEnabled && ProcessInfo.processInfo.arguments.contains("-demoPast") }

    static let user = User(id: "1", email: "spieler@example.com",
                           info: decode(##"{"id_player":1,"id_club":"1","fname":"Alex","lname":"Muster","active_clubs":[{"club_id":"1","club_name":"EHC Musterstadt"},{"club_id":"2","club_name":"Eishockey Akademie"}]}"##),
                           hasNotifications: true)

    static func entries(now: Date = .now) -> [TrackedEntry] {
        func day(_ offset: Int, _ time: String) -> (String, String) {
            let d = Calendar.current.date(byAdding: .day, value: offset, to: now)!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let s = f.string(from: d)
            return (s, "\(s) \(time):00")
        }
        let (d1, t1) = day(1, "17:30"), (d2, t2) = day(2, "18:00"), (d3, t3) = day(4, "11:15"), (d4, t4) = day(6, "17:30")
        let (d5, t5) = day(1, "12:00")
        let roster = ##""convocation":{"available_total":8,"available_totalG":1,"available_totalD":3,"available_totalF":4,"staff":[{"fname":"Thomas","lname":"Berger","role":"Headcoach"},{"fname":"Sabine","lname":"Huber","role":"Teammanagerin"}],"available":[{"fname":"Lukas","lname":"Gruber","number":"30","position":"G"},{"fname":"Felix","lname":"Wagner","number":"4","position":"D"},{"fname":"Jonas","lname":"Pichler","number":"7","position":"D"},{"fname":"Paul","lname":"Steiner","number":"22","position":"D"},{"fname":"Alex","lname":"Muster","number":"17","position":"F"},{"fname":"Max","lname":"Hofer","number":"9","position":"F"},{"fname":"Leon","lname":"Mayr","number":"91","position":"F"},{"fname":"Elias","lname":"Bauer","number":"88","position":"F"}]}"##
        return [
            TrackedEntry(event: decode(##"{"id_practice":11,"name":"Eistraining","agegroup":"U15","practicegroup":"Gruppe A","place":"Eishalle Musterstadt, Platz 1","color":"#1E88E5","date":"\##(d1)","datetime":"\##(t1)","time_start":"17:30:00","time_end":"19:00:00","available":0,"health_status":3}"##),
                         detail: decode(##"{"type":"Training","category":"practices","available":0,"health_status":3,"notes":"<p>Bitte 20 Minuten vorher in der Kabine sein.</p>","convocation":{"staff":[{"fname":"Thomas","lname":"Berger","role":"Headcoach"}],"available":[]}}"##)),
            TrackedEntry(event: decode(##"{"id_game":21,"name":"EHC Musterstadt – HC Bergtal","agegroup":"U15","place":"Eishalle Musterstadt","color":"#E53935","date":"\##(d2)","datetime":"\##(t2)","time_start":"18:00:00","time_end":"20:30:00","available":1,"health_status":3,"has_notifications":1}"##),
                         detail: decode(##"{"type":"Meisterschaft","is_away":"heim","category":"games","available":1,"available_date":"\##(d1)","departure":"Abfahrt","departure_time":"–","meeting":"Treffpunkt","meeting_time":"16:45","notes":"Weiße Trikots mitnehmen.",\##(roster),"notifications":[{"id_notification":1,"subject":"Aufstellung","message":"Bitte bis Donnerstag zu- oder absagen.","fname":"Thomas","lname":"Berger","date":"\##(d1)"}]}"##)),
            TrackedEntry(event: decode(##"{"id_game":22,"name":"EC Talheim – EHC Musterstadt","agegroup":"U15","place":"Sportzentrum Talheim","color":"#8E24AA","date":"\##(d3)","datetime":"\##(t3)","time_start":"11:15:00","time_end":"13:30:00","available":0,"health_status":3}"##),
                         detail: decode(##"{"type":"Meisterschaft","is_away":"ausw&auml;rts","category":"games","available":0,"departure":"Abfahrt Bus","departure_time":"08:45","meeting":"Treffpunkt","meeting_time":"08:30 Parkplatz Halle",\##(roster)}"##)),
            TrackedEntry(event: decode(##"{"id_practice":12,"name":"Trockentraining","agegroup":"U15","place":"Turnhalle Mittelschule","color":"#43A047","date":"\##(d4)","datetime":"\##(t4)","time_start":"17:30:00","time_end":"18:30:00","available":0,"health_status":8,"health_status_notes":"Erkältet"}"##)),
            cancelled(TrackedEntry(event: decode(##"{"id_practice":13,"name":"Eistraining","agegroup":"U15","practicegroup":"Gruppe A","place":"Eishalle Musterstadt, Platz 2","color":"#1E88E5","date":"\##(d5)","datetime":"\##(t5)","time_start":"12:00:00","time_end":"13:30:00","available":0,"health_status":3}"##),
                                   detail: decode(##"{"type":"Training","category":"practices","available":0,"health_status":3,"notes":"<p>Schläger-Check vor dem Training.</p>"}"##)),
                      at: now.addingTimeInterval(-1800)),
        ]
    }

    /// Stand-in logos (the demo clubs have no logo URL): colored badges with initials.
    static func clubLogos() -> [String: UIImage] {
        func badge(_ text: String, _ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { _ in
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 64, height: 64)).fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 24, weight: .heavy), .foregroundColor: UIColor.white]
                let size = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: (64 - size.width) / 2, y: (64 - size.height) / 2), withAttributes: attrs)
            }.menuIcon()
        }
        return ["1": badge("EHC", .systemRed), "2": badge("EA", .systemIndigo)]
    }

    private static func cancelled(_ entry: TrackedEntry, at date: Date) -> TrackedEntry {
        var e = entry
        e.cancelledAt = date
        return e
    }

    /// Assigns clubs: the off-ice session belongs to the second club.
    static func entriesWithClubs(now: Date = .now) -> [TrackedEntry] {
        entries(now: now).enumerated().map { i, e in
            var e = e
            e.clubID = i == 3 ? "2" : "1"
            return e
        }
    }

    static func archive(now: Date = .now) -> [TrackedEntry] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        func day(_ offset: Int) -> String { f.string(from: Calendar.current.date(byAdding: .day, value: offset, to: now)!) }
        let rows: [(String, Int)] = [
            (##"{"id_game":5,"name":"HC Talheim – EHC Musterstadt","agegroup":"U15","place":"Sportzentrum Talheim","color":"#8E24AA","date":"\##(day(-1))","datetime":"\##(day(-1)) 12:40:00","time_start":"12:40","time_end":"01:00","available":0,"health_status":1}"##, -1),
            (##"{"id_practice":6,"name":"Eistraining","agegroup":"U15","practicegroup":"Gruppe A","place":"Eishalle Musterstadt","color":"#1E88E5","date":"\##(day(-3))","datetime":"\##(day(-3)) 17:30:00","time_start":"17:30","time_end":"19:00","available":0,"health_status":8,"health_status_notes":"Fieber"}"##, -3),
            (##"{"id_practice":7,"name":"Athletik","agegroup":"U15","place":"Turnhalle","color":"#43A047","date":"\##(day(-4))","datetime":"\##(day(-4)) 16:00:00","time_start":"16:00","time_end":"17:00","available":0,"health_status":1}"##, -4),
        ]
        return rows.map { json, _ in
            var e = TrackedEntry(event: decode(json), clubID: "1")
            e.archivedAt = now
            return e
        }
    }

    static func changes(for entries: [TrackedEntry], now: Date = .now) -> [EventChange] {
        [
            EventChange(entry: entries[4], detectedAt: now.addingTimeInterval(-1800), kind: .removed),
            EventChange(entry: entries[1], detectedAt: now.addingTimeInterval(-600), kind: .attendance(old: 0, new: 1)),
            EventChange(entry: entries[2], detectedAt: now.addingTimeInterval(-3600), kind: .rosterPublished(players: 8)),
            EventChange(entry: entries[0], detectedAt: now.addingTimeInterval(-7200), kind: .time(old: "17:00–18:30", new: "17:30–19:00")),
            EventChange(entry: entries[2], detectedAt: now.addingTimeInterval(-90000), kind: .departure(label: "Abfahrt Bus", old: "09:00", new: "08:45")),
            EventChange(entry: entries[3], detectedAt: now.addingTimeInterval(-95000), kind: .added),
        ]
    }

    static var showsLog: Bool { isEnabled && ProcessInfo.processInfo.arguments.contains("-demoLog") }

    static func logEntries(now: Date = .now) -> [LogEntry] {
        let lines: [(TimeInterval, LogLevel, LogArea, String)] = [
            (-20, .info, .background, "Hintergrundaktualisierung beendet: 2 Änderung(en), 2 Benachrichtigung(en)"),
            (-21, .info, .notifications, "2 Benachrichtigung(en) gesendet"),
            (-22, .debug, .changes, "p12 U15 Trockentraining: players(added: [], removed: [\"Lukas Gruber\"])"),
            (-23, .info, .changes, "Synchronisierung: 2 Änderung(en) erkannt"),
            (-24, .info, .sync, "Fertig in 3.8 s: 6 Termine, 2 Änderungen, Archiv 3"),
            (-26, .info, .sync, "Details: 6 von 6 geladen"),
            (-29, .debug, .network, "/getevent games/21 club=1 HTTP 200, 18342 Bytes, 0.41 s"),
            (-30, .debug, .network, "/refreshdata club=1 HTTP 200, 40211 Bytes, 0.92 s"),
            (-31, .info, .sync, "Start: Vereine 1, 2, gespeichert 6 Termine"),
            (-32, .info, .background, "Hintergrundaktualisierung gestartet"),
            (-1900, .warning, .background, "Hintergrundaktualisierung: von iOS vorzeitig beendet"),
            (-1910, .warning, .sync, "Details: 4 von 6 geladen (Rest behält den letzten Stand)"),
            (-5400, .error, .network, "/refreshdata club=2 fehlgeschlagen nach 30.01 s: Zeitüberschreitung bei der Anforderung."),
            (-7200, .info, .app, "App gestartet"),
        ]
        return lines.map { LogEntry(date: now.addingTimeInterval($0.0), level: $0.1, area: $0.2, message: $0.3) }
    }

    private static func decode<T: Decodable>(_ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
#endif
