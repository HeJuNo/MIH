import MyIceKit
import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "hockey.puck.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Theme.ice)
                            .symbolEffect(.bounce, value: busy)
                            .accessibilityHidden(true)
                        Text("MyHockey Data")
                            .font(.largeTitle.weight(.bold))
                            .tracking(-0.4)
                            .foregroundStyle(.white)
                        Text("Deine Spiele & Trainings – und jede Änderung sofort als Mitteilung.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 72)

                    VStack(spacing: 12) {
                        field(icon: "envelope.fill") {
                            TextField("", text: $email, prompt: Text("E-Mail").foregroundStyle(.white.opacity(0.5)))
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                        }
                        field(icon: "lock.fill") {
                            SecureField("", text: $password, prompt: Text("Passwort").foregroundStyle(.white.opacity(0.5)))
                                .textContentType(.password)
                                .focused($focus, equals: .password)
                                .submitLabel(.go)
                                .onSubmit(login)
                        }

                        Button(action: login) {
                            ZStack {
                                Text("Anmelden").opacity(busy ? 0 : 1)
                                if busy { ProgressView().tint(Theme.night) }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(.white, in: Capsule())
                            .foregroundStyle(Theme.night)
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(busy || email.isEmpty || password.isEmpty)
                        .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)
                        .padding(.top, 8)

                        // Below the button, so the form never jumps when it appears.
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.62))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                    }
                    .environment(\.colorScheme, .dark)

                    VStack(spacing: 10) {
                        Button("Passwort vergessen?") {
                            openURL(URL(string: "https://app.myice.hockey/forgot/")!)
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        Text("Melde dich mit deinem myice.hockey-Spielerkonto an.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .animation(Theme.spring, value: error)
        }
        .scrollDismissesKeyboard(.interactively)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .background { Theme.heroGradient.ignoresSafeArea() }
    }

    private func field<F: View>(icon: String, @ViewBuilder _ content: () -> F) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.6)).frame(width: 20)
                .accessibilityHidden(true)
            content().foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func login() {
        guard !email.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await state.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            } catch APIError.rejected(let message) {
                error = message ?? "Anmeldung fehlgeschlagen."
            } catch APIError.http(let status) {
                error = "Der Server meldet einen Fehler (HTTP \(status)). Bitte später erneut versuchen."
            } catch APIError.decoding(let detail) {
                error = "Die Antwort des Servers konnte nicht gelesen werden (\(detail))."
            } catch let urlError as URLError {
                error = "Keine Verbindung zum Server (\(urlError.code.rawValue)). Bitte prüfe deine Internetverbindung."
            } catch {
                self.error = "Anmeldung fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}
