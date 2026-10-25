import EventKit
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
                appearanceSection
                notificationSection
                calendarSection
                mapsSection
                backgroundSection
                logSection
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

            NavigationLink {
                CategoriesView()
            } label: {
                LabeledContent {
                    let all = ChangeKind.Category.allCases.count
                    Text("\(all - state.disabledCategories.count) von \(all)")
                } label: {
                    Label { Text("Gemeldete Änderungen") } icon: { SettingsIcon(symbol: "list.bullet", color: .gray) }
                }
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
                Label { Text(testSent ? "Test gesendet" : "Test-Benachrichtigung senden") } icon: {
                    SettingsIcon(symbol: testSent ? "checkmark" : "paperplane.fill", color: testSent ? Theme.positive : Theme.accent)
                }
            }
            .sensoryFeedback(.success, trigger: testSent) { _, new in new }
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

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Picker(selection: Binding(get: { state.appearance }, set: { state.setAppearance($0) })) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            } label: {
                Label { Text("Darstellung") } icon: { SettingsIcon(symbol: "circle.lefthalf.filled", color: .gray) }
            }
        }
    }

    // MARK: Calendar sync

    private var calendarSection: some View {
        Section {
            calendarPermissionRow

            Toggle(isOn: Binding(get: { state.calendarSyncEnabled }, set: { state.setCalendarSyncEnabled($0) })) {
                Label { Text("Kalendersynchronisation") } icon: { SettingsIcon(symbol: "calendar.badge.clock", color: Theme.accent) }
            }

            if state.calendarSyncEnabled {
                Picker(selection: Binding(get: { state.calendarIdentifier }, set: { state.setCalendarIdentifier($0) })) {
                    Text("Automatisch (\(CalendarSync.defaultCalendarTitle))").tag(nil as String?)
                    ForEach(state.calendarOptions, id: \.id) { option in
                        Text(option.title).tag(option.id as String?)
                    }
                } label: {
                    Label { Text("Kalender") } icon: { SettingsIcon(symbol: "calendar", color: .gray) }
                }

                Toggle(isOn: Binding(get: { state.calendarTitlePrefixEnabled }, set: { state.setCalendarTitlePrefixEnabled($0) })) {
                    Label { Text("Eigenes Präfix") } icon: { SettingsIcon(symbol: "textformat", color: .gray) }
                }
                if state.calendarTitlePrefixEnabled {
                    TextField("z. B. 🏒", text: Binding(get: { state.calendarTitlePrefix },
                                                         set: { state.setCalendarTitlePrefix($0) }))
                }
            }
        } header: {
            Text("Kalender")
        } footer: {
            Text("Spiegelt Spiele und Trainings der laufenden Saison inklusive Treffpunkt, Abfahrt und Aufgebot in einen iOS-Kalender.")
        }
        .task { await state.loadCalendarOptions() }
    }

    @ViewBuilder private var calendarPermissionRow: some View {
        switch state.calendarAuthStatus {
        case .fullAccess:
            Label { Text("Kalenderzugriff erlaubt") } icon: { SettingsIcon(symbol: "checkmark", color: Theme.positive) }
        case .denied, .restricted:
            Button { Task { await state.requestCalendarAccess() } } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text("Kalenderzugriff deaktiviert")
                        Text("In den iOS-Einstellungen erlauben").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { SettingsIcon(symbol: "exclamationmark", color: Theme.alert) }
            }
        default:
            Button { Task { await state.requestCalendarAccess() } } label: {
                Label { Text("Kalenderzugriff erlauben") } icon: { SettingsIcon(symbol: "calendar.badge.plus", color: Theme.warning) }
            }
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
            LabeledContent("Zuletzt im Hintergrund") {
                if let last = state.lastBackgroundRun {
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

    // MARK: Protocol

    private var logSection: some View {
        Section {
            Toggle(isOn: Binding(get: { state.loggingEnabled }, set: { state.setLoggingEnabled($0) })) {
                Label { Text("Protokoll aufzeichnen") } icon: { SettingsIcon(symbol: "list.bullet.rectangle.fill", color: .brown) }
            }
            if state.loggingEnabled {
                Picker(selection: Binding(get: { state.logLevel }, set: { state.setLogLevel($0) })) {
                    ForEach(LogLevel.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label { Text("Stufe") } icon: { SettingsIcon(symbol: "slider.horizontal.3", color: .gray) }
                }
                NavigationLink {
                    LogAreasView()
                } label: {
                    LabeledContent {
                        Text("\(state.logAreas.count) von \(LogArea.allCases.count)")
                    } label: {
                        Label { Text("Bereiche") } icon: { SettingsIcon(symbol: "square.grid.2x2.fill", color: .gray) }
                    }
                }
            }
        } header: {
            Text("Protokoll")
        } footer: {
            Text(state.loggingEnabled
                 ? "Aufgezeichnet wird ab der gewählten Stufe: Debug enthält alles, auch jede Anfrage an den Server; Fehler nur Probleme. Das Protokoll findest du im eigenen Tab."
                 : "Zeichnet Synchronisierung, Hintergrundläufe, Netzwerk und Benachrichtigungen auf, um Probleme nachzuvollziehen. Passwörter und Zugangsdaten werden nie protokolliert.")
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

private struct CategoriesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                ForEach(ChangeKind.Category.allCases, id: \.self) { category in
                    Toggle(isOn: Binding(get: { !state.disabledCategories.contains(category) },
                                         set: { state.setCategory(category, enabled: $0) })) {
                        Label { Text(ChangeFormatter.categoryTitle(category)) } icon: {
                            SettingsIcon(symbol: ChangeFormatter.categorySymbol(category), color: .gray)
                        }
                    }
                }
            } footer: {
                Text("Nur eingeschaltete Arten von Änderungen lösen eine Mitteilung aus. Im Tab „Änderungen“ erscheinen weiterhin alle.")
            }
        }
        .navigationTitle("Gemeldete Änderungen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LogAreasView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                ForEach(LogArea.allCases) { area in
                    Toggle(isOn: Binding(get: { state.logAreas.contains(area) }, set: { state.setLogArea(area, enabled: $0) })) {
                        Label { Text(area.title) } icon: { SettingsIcon(symbol: area.symbol, color: .gray) }
                    }
                }
            } footer: {
                Text("Nur eingeschaltete Bereiche werden aufgezeichnet.")
            }
        }
        .navigationTitle("Bereiche")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Bundle {
    var versionString: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
