import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        if state.isLoggedIn {
            TabView(selection: $state.selectedTab) {
                Tab("Spiele & Trainings", systemImage: "hockey.puck", value: AppState.Tab.schedule) {
                    ScheduleView()
                }
                Tab("Änderungen", systemImage: "bell.badge", value: AppState.Tab.changes) {
                    ChangesView()
                }
                .badge(state.unseenChanges)
                Tab("Einstellungen", systemImage: "gearshape", value: AppState.Tab.settings) {
                    SettingsView()
                }
            }
        } else {
            LoginView()
        }
    }
}
