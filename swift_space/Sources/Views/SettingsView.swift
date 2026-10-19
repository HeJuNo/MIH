import MyIceKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmLogout = false
    @State private var testSent = false
    @State private var askPassword = false
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                notificationSection
                categorySection
                mapsSection
                backgroundSection
                aboutSection
            }
            .navigationTitle("Einstellungen")
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            if let user = state.user {
                HStack(spacing: 14) {
                    AsyncImage(url: user.info.photo) { $0.resizable().scaledToFill() } placeholder: {
                        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tint)
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(user.info.fname ?? "") \(user.info.lname ?? "")").font(.headline)
                        Text(user.email).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                ForEach(state.clubs) { club in
                    HStack(spacing: 12) {
                        AsyncImage(url: club.clubLogo) { $0.resizable().scaledToFit() } placeholder: {
                            Image(systemName: "shield.fill").foregroundStyle(.tint)
                        }
                        .frame(width: 26, height: 26)
                        Text(club.clubName ?? club.id).font(.subheadline)
                        Spacer()
                        let count = state.entries.filter { $0.clubID == club.id }.count
                        Text(count == 1 ? "1 Termin" : "\(count) Termine").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Button {
                    askPassword = true
                } label: {
                    HStack {
                        Label { Text("Vergangene Termine laden") } icon: {
                            SettingsIcon(symbol: "clock.arrow.circlepath", color: .indigo)
                        }
                        Spacer()
                        if state.isImportingHistory { ProgressView() }
                        else { Text("\(state.archive.count)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .disabled(state.isImportingHistory)
                .alert("Vergangene Termine laden", isPresented: $askPassword) {
                    SecureField("Passwort", text: $password)
                    Button("Laden") {
                        let pw = password
                        password = ""
                        Task { await state.importHistory(email: user.email, password: pw) }
                    }
                    Button("Abbrechen", role: .cancel) { password = "" }
                } message: {
                    Text("Die bisherige Saison wird einmalig über die Web-Version geladen. Das Passwort wird nicht gespeichert.")
                }
                if let message = state.historyMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }

                Button("Abmelden", role: .destructive) { confirmLogout = true }
                    .confirmationDialog("Abmelden?", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("Abmelden", role: .destructive) { Task { await state.logout() } }
                    } message: {
                        Text("Die Hintergrund-Überwachung wird beendet und gespeicherte Daten werden gelöscht.")
                    }
            }
        } header: { Text("Konto") }
    }

    // MARK: Notifications

    private var notificationSection: some View {
        Section {
            permissionRow

            Toggle(isOn: Binding(get: { state.preferences.enabledByDefault }, set: { state.setNotifyByDefault($0) })) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Änderungen standardmäßig melden")
                        Text("Gilt für alle Termine ohne eigene Einstellung")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { SettingsIcon(symbol: "bell.badge.fill", color: Theme.alert) }
            }

            let overrides = state.preferences.overrides.count
            if overrides > 0 {
                LabeledContent("Eigene Einstellungen", value: "\(overrides) Termin\(overrides == 1 ? "" : "e")")
            }

            Button {
                Task {
                    await state.sendTestNotification()
                    testSent = true
                }
            } label: {
                Label { Text(testSent ? "Test gesendet ✓" : "Test-Benachrichtigung senden") } icon: {
                    SettingsIcon(symbol: "paperplane.fill", color: Theme.accent)
                }
            }
            .disabled(state.notificationStatus != .authorized)
        } header: {
            Text("Benachrichtigungen")
        } footer: {
            Text("Die Glocke in jedem Termin überschreibt diese Voreinstellung für genau diesen Termin.")
        }
    }

    @ViewBuilder private var permissionRow: some View {
        switch state.notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Label { Text("Mitteilungen erlaubt") } icon: { SettingsIcon(symbol: "checkmark", color: Theme.positive) }
        case .denied:
            Button { Task { await state.requestNotificationPermission() } } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text("Mitteilungen deaktiviert")
                        Text("In den iOS-Einstellungen erlauben").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { SettingsIcon(symbol: "exclamationmark", color: Theme.alert) }
            }
        default:
            Button { Task { await state.requestNotificationPermission() } } label: {
                Label { Text("Mitteilungen erlauben") } icon: { SettingsIcon(symbol: "bell", color: Theme.warning) }
            }
        }
    }

    private var categorySection: some View {
        Section {
            ForEach(ChangeKind.Category.allCases, id: \.self) { category in
                Toggle(isOn: Binding(get: { !state.disabledCategories.contains(category) },
                                     set: { state.setCategory(category, enabled: $0) })) {
                    Label { Text(ChangeFormatter.categoryTitle(category)) } icon: {
                        SettingsIcon(symbol: ChangeFormatter.categorySymbol(category), color: .gray)
                    }
                }
            }
        } header: {
            Text("Gemeldete Änderungen")
        }
    }

    private var mapsSection: some View {
        Section {
            Picker(selection: Binding(get: { state.mapProvider }, set: { state.setMapProvider($0) })) {
                ForEach(MapProvider.allCases) { Text($0.title).tag($0) }
            } label: {
                Label { Text("Karten") } icon: { SettingsIcon(symbol: "map.fill", color: Theme.positive) }
            }
        } footer: {
            Text("Ist Google Maps nicht installiert, öffnet sich Google Maps im Browser.")
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        Section {
            Picker(selection: Binding(get: { state.refreshMinutes }, set: { state.setRefreshMinutes($0) })) {
                ForEach(SettingsStore.refreshOptions, id: \.self) { m in
                    Text(m < 60 ? "alle \(m) Minuten" : m == 60 ? "jede Stunde" : "alle \(m / 60) Stunden").tag(m)
                }
            } label: {
                Label { Text("Prüfen") } icon: { SettingsIcon(symbol: "arrow.triangle.2.circlepath", color: Theme.accent) }
            }

            if state.backgroundRefreshStatus != .available {
                Label {
                    VStack(alignment: .leading) {
                        Text("Hintergrundaktualisierung ist aus")
                        Text("Einstellungen › Allgemein › Hintergrundaktualisierung").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { SettingsIcon(symbol: "exclamationmark.triangle.fill", color: Theme.warning) }
            }

            LabeledContent("Zuletzt geprüft") {
                if let last = state.lastSync {
                    Text(last, format: .relative(presentation: .named).locale(.de))
                } else {
                    Text("noch nie")
                }
            }
            LabeledContent("Überwachte Termine", value: "\(state.entries.count)")

            Button {
                Task { await state.refresh() }
            } label: {
                HStack {
                    Label { Text("Jetzt prüfen") } icon: { SettingsIcon(symbol: "bolt.fill", color: Theme.positive) }
                    Spacer()
                    if state.isSyncing { ProgressView() }
                }
            }
            .disabled(state.isSyncing)

            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.alert)
            }
        } header: {
            Text("Hintergrund-Aktualisierung")
        } footer: {
            Text("iOS bestimmt den genauen Zeitpunkt anhand deiner Nutzung und des Akkustands. Das Intervall ist der frühestmögliche Abstand.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.versionString)
        } footer: {
            Text("MyHockey Data ist eine inoffizielle App und steht in keiner Verbindung zu den Betreibern von myice.hockey.")
        }
    }
}

struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(.white)
    }
}

extension Bundle {
    var versionString: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
