import Foundation

/// "Heute"/"Morgen"/"Gestern" for a day header, or nil for anything further out — shared by
/// the schedule, changes and log day-sections so the three can't silently diverge again.
func relativeDayLabel(for day: Date) -> String? {
    if Calendar.current.isDateInToday(day) { return "Heute" }
    if Calendar.current.isDateInTomorrow(day) { return "Morgen" }
    if Calendar.current.isDateInYesterday(day) { return "Gestern" }
    return nil
}
