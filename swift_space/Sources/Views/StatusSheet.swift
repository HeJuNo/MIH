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
    @State private var error: String?
    @FocusState private var notesFocused: Bool

    private var event: Event { entry.event }
    private var currentAvailability: Availability { Availability(code: entry.detail?.available ?? event.available) }
    private var asksAttendance: Bool { event.isGame && currentAvailability != .notRequested }
    private var statusEnabled: Bool { StatusRules.statusPickerEnabled(attendance: asksAttendance ? attendance : nil) }
    private var canSave: Bool {
        !saving && (attendance == .confirmed && asksAttendance || status != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if asksAttendance {
                        section("Teilnahme") {
                            HStack(spacing: 10) {
                                choice("Ich bin dabei", symbol: "checkmark", color: Theme.positive, selected: attendance == .confirmed) {
                                    attendance = .confirmed
                                    status = nil
                                }
                                choice("Ich kann nicht", symbol: "xmark", color: Theme.alert, selected: attendance == .declined) {
                                    attendance = .declined
                                }
                            }
                        }
                    }

                    section("Status") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(HealthStatus.selectable, id: \.self) { s in
                                let allowed = StatusRules.allowedStatuses(for: [event]).contains(s)
                                choice(StatusText.health(s.rawValue), symbol: symbol(s), color: color(s),
                                       selected: status == s, enabled: allowed && statusEnabled) {
                                    if status != s { notes = "" }   // like the web: new status, new note
                                    status = s
                                }
                            }
                        }
                        if event.isGame {
                            Text("„Gesund“ kann bei Spielen nur dein Trainer setzen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .opacity(statusEnabled ? 1 : 0.45)

                    section("Notiz") {
                        VStack(alignment: .trailing, spacing: 4) {
                            TextField("Optional, z. B. „Fieber seit gestern“", text: $notes, axis: .vertical)
                                .lineLimit(3...6)
                                .font(.subheadline)
                                .focused($notesFocused)
                                .padding(12)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .onChange(of: notes) { _, new in
                                    if new.count > StatusRules.maxNotesLength { notes = String(new.prefix(StatusRules.maxNotesLength)) }
                                }
                            Text("\(notes.count) / \(StatusRules.maxNotesLength)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.alert)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Status ändern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if saving { ProgressView() } else { Text("Speichern").bold() }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: seed)
            .sensoryFeedback(.success, trigger: saving) { old, new in old && !new && error == nil }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(event.tint.gradient).frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name ?? "Termin").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([event.start?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.de)),
                      event.timeRange.isEmpty ? nil : event.timeRange].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            content()
        }
    }

    private func choice(_ title: String, symbol: String, color: Color, selected: Bool, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(selected ? AnyShapeStyle(Color.white.opacity(0.25)) : AnyShapeStyle(color.opacity(0.15)), in: Circle())
                    .foregroundStyle(selected ? .white : color)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").font(.subheadline) }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.clear : Color(.separator).opacity(0.5), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .animation(.snappy(duration: 0.2), value: selected)
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
                dismiss()
            } catch StatusRules.ValidationError.statusRequired {
                error = "Bitte wähle einen Status."
            } catch StatusRules.ValidationError.notEditable {
                error = "Der Termin hat bereits begonnen."
            } catch APIError.rejected(let message) {
                error = message ?? "Der Server hat die Änderung abgelehnt."
            } catch {
                self.error = "Speichern fehlgeschlagen. Bitte prüfe deine Verbindung."
            }
        }
    }
}
