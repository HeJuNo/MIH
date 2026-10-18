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
                    VStack(spacing: 14) {
                        Image(systemName: "hockey.puck.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white, Theme.ice)
                            .shadow(color: Theme.ice.opacity(0.6), radius: 24)
                            .symbolEffect(.bounce, value: busy)
                        Text("MyHockey Data")
                            .font(.largeTitle.weight(.heavy))
                            .foregroundStyle(.white)
                        Text("Deine Spiele & Trainings – und jede Änderung sofort als Mitteilung.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 60)

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

                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.alert.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        Button(action: login) {
                            ZStack {
                                Text("Anmelden").opacity(busy ? 0 : 1)
                                if busy { ProgressView().tint(Theme.night) }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(Theme.night)
                        }
                        .disabled(busy || email.isEmpty || password.isEmpty)
                        .opacity(email.isEmpty || password.isEmpty ? 0.6 : 1)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
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
                .animation(.snappy, value: error)
        }
        .scrollDismissesKeyboard(.interactively)
        // Decoration lives in the background so it can never widen the layout.
        .background {
            Theme.heroGradient
                .overlay(alignment: .top) {
                    Circle()
                        .stroke(.white.opacity(0.06), lineWidth: 10)
                        .frame(width: 520, height: 520)
                        .offset(y: -120)
                }
                .clipped()
                .ignoresSafeArea()
        }
    }

    private func field<F: View>(icon: String, @ViewBuilder _ content: () -> F) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.7)).frame(width: 20)
            content().foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
