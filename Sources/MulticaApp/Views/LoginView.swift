import MulticaCore
import SwiftUI

struct LoginView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Sign in to Multica").font(.title2.weight(.semibold))
            Text(env.app.config.apiURL.host ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .disabled(codeSent)
                    .onSubmit(sendCode)
                if codeSent {
                    TextField("Verification code", text: $code)
                        .textContentType(.oneTimeCode)
                        .onSubmit(verify)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)

            if let error = env.app.authError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                if codeSent {
                    Button("Use a different email") {
                        codeSent = false
                        code = ""
                    }
                    Button("Sign in", action: verify)
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.isEmpty || busy)
                } else {
                    Button("Email me a code", action: sendCode)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!email.contains("@") || busy)
                }
            }

            Divider().frame(width: 300)

            Button {
                openURL(env.app.browserSignInURL)
            } label: {
                Label("Continue in browser (Google)", systemImage: "safari")
            }
            .help("Signs in on the web and returns here through a multica:// link.")

            SettingsLink {
                Text("Server settings…")
            }
            .buttonStyle(.link)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if busy { ProgressView() } }
    }

    private func sendCode() {
        guard email.contains("@"), !busy else { return }
        busy = true
        Task {
            codeSent = await env.app.sendCode(email: email.trimmingCharacters(in: .whitespaces))
            busy = false
        }
    }

    private func verify() {
        guard !code.isEmpty, !busy else { return }
        busy = true
        Task {
            await env.app.verify(email: email.trimmingCharacters(in: .whitespaces), code: code.trimmingCharacters(in: .whitespaces))
            busy = false
            await env.autoStartIfNeeded()
        }
    }
}
