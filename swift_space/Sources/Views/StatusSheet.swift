import MyIceKit
import SwiftUI

/// Change own status (Gesund / Entschuldigt / Krank / Verletzt) with a note,
/// and answer attendance requests for games. Rules follow the original app.
struct StatusSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let entry: TrackedEntry

    @State private var status: HealthStatus?
    @State private var attendance: Availability?
    @State private var notes = ""
    @State private var saving = false
    @State private var saved = 0
    @State private var failed = 0
    @State private var error: String?
    @FocusState private var notesFocused: Bool

    /// Snapshot of what `seed()` loaded, to detect edits worth confirming before a discard.
    @State private var seededStatus: HealthStatus?
    @State private var seededAttendance: Availability?
    @State private var seededNotes = ""
    @State private var confirmDiscard = false
    private var hasEdits: Bool { status != seededStatus || attendance != seededAttendance || notes != seededNotes }

    private var event: Event { entry.event }
    private var currentAvailability: Availability { Availability(code: entry.detail?.available ?? event.available) }
    private var asksAttendance: Bool { event.isGame && currentAvailability != .notRequested }
    private var statusEnabled: Bool { StatusRules.statusPickerEnabled(attendance: asksAttendance ? attendance : nil) }
    private var canSave: Bool {
        !saving && (attendance == .confirmed && asksAttendance || status != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                }

                if asksAttendance {
                    Section("Teilnahme") {
                        choice("Ich bin dabei", symbol: "checkmark", color: Theme.positive, selected: attendance == .confirmed) {
                            attendance = .confirmed
                            status = nil
                        }
                        choice("Ich kann nicht", symbol: "xmark", color: Theme.alert, selected: attendance == .declined) {
                            attendance = .declined
                        }
                    }
                }

                Section {
                    ForEach(HealthStatus.selectable, id: \.self) { s in
                        let allowed = StatusRules.allowedStatuses(for: [event]).contains(s)
                        choice(StatusText.health(s.rawValue), symbol: symbol(s), color: color(s),
                               selected: status == s, enabled: allowed && statusEnabled) {
                            if status != s { notes = "" }   // like the web: new status, new note
                            status = s
                        }
                    }
                } header: {
                    Text("Status")
                } footer: {
                    if event.isGame { Text("„Gesund“ kann bei Spielen nur dein Trainer setzen.") }
                }

                Section {
                    TextField("Optional, z. B. „Fieber seit gestern“", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($notesFocused)
                        .onChange(of: notes) { _, new in
                            if new.count > StatusRules.maxNotesLength { notes = String(new.prefix(StatusRules.maxNotesLength)) }
                        }
                } header: {
                    Text("Notiz")
                } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.alert)
                        }
                        Spacer()
                        Text("\(notes.count) / \(StatusRules.maxNotesLength)").monospacedDigit()
                    }
                }
            }
            .navigationTitle("Status ändern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { hasEdits ? (confirmDiscard = true) : dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if saving { ProgressView() } else { Text("Speichern") }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: seed)
            .sensoryFeedback(.selection, trigger: status)
            .sensoryFeedback(.selection, trigger: attendance)
            .sensoryFeedback(.success, trigger: saved)
            .sensoryFeedback(.error, trigger: failed)
            .confirmationDialog("Änderungen verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Änderungen verwerfen", role: .destructive) { dismiss() }
            } message: {
                Text("Deine Eingaben gehen verloren.")
            }
        }
        .interactiveDismissDisabled(hasEdits)
        .presentationDetents([.large])
    }

    private var header: some View {
        HStack(spacing: 12) {
            Capsule().fill(event.tint).frame(width: 4, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name ?? "Termin").font(.body.weight(.semibold)).lineLimit(2)
                Text([event.start?.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.de)),
                      event.timeRange.isEmpty ? nil : event.timeRange].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A selection row like in iOS Settings: colored glyph, title, checkmark when chosen.
    private func choice(_ title: String, symbol: String, color: Color, selected: Bool, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: symbol, color: color)
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .animation(Theme.spring, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func symbol(_ s: HealthStatus) -> String {
        switch s {
        case .healthy, .attending: "checkmark"
        case .excused: "calendar.badge.minus"
        case .sick: "thermometer.medium"
        case .injured: "bandage.fill"
        }
    }

    private func color(_ s: HealthStatus) -> Color {
        switch s {
        case .healthy, .attending: Theme.positive
        case .excused: Theme.warning
        case .sick, .injured: Theme.alert
        }
    }

    private func seed() {
        let code = entry.detail?.healthStatus ?? event.healthStatus
        let current = HealthStatus(rawValue: code ?? 0)
        status = current == .attending ? nil : current
        if let s = status, !StatusRules.allowedStatuses(for: [event]).contains(s) { status = nil }
        notes = entry.detail?.healthNotes ?? event.healthStatusNotes ?? ""
        attendance = [.confirmed, .declined].contains(currentAvailability) ? currentAvailability : nil
        seededStatus = status
        seededAttendance = attendance
        seededNotes = notes
    }

    private func save() {
        error = nil
        saving = true
        let submission = StatusRules.Submission(attendance: asksAttendance ? attendance : nil,
                                                status: statusEnabled ? status : nil,
                                                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes)
        Task {
            defer { saving = false }
            do {
                try await state.submitStatus(for: entry, submission)
                saved += 1
                dismiss()
                return
            } catch StatusRules.ValidationError.statusRequired {
                error = "Bitte wähle einen Status."
            } catch StatusRules.ValidationError.notEditable {
                error = "Der Termin hat bereits begonnen."
            } catch APIError.rejected(let message) {
                error = message ?? "Der Server hat die Änderung abgelehnt."
            } catch {
                self.error = "Speichern fehlgeschlagen. Bitte prüfe deine Verbindung."
            }
            failed += 1
        }
    }
}
