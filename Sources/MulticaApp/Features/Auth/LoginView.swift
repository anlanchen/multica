import AppKit
import MulticaCore
import SwiftUI

/// Email-code sign-in with a browser (Google) alternative (upstream
/// auth/login-page.tsx + desktop pages/login.tsx).
struct LoginView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var step: LoginStep = .email
    @State private var email = ""
    @State private var code = ""
    @State private var error = ""
    @State private var loading = false
    @State private var cooldown = 0
    @State private var sessionExpired = false
    @State private var showServer = false

    var body: some View {
        VStack(spacing: 16) {
            LoginCard {
                switch step {
                case .email: emailStep
                case .code: codeStep
                }
            }
            HStack(spacing: 6) {
                Text(env.app.config.apiURL.host ?? env.app.config.apiURL.absoluteString)
                Text("·")
                Button("Server settings…") { showServer = true }
                    .buttonStyle(.link)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .sheet(isPresented: $showServer) { LoginServerSheet() }
        .onAppear {
            sessionExpired = env.app.authError == LoginSupport.sessionExpiredMessage
            if sessionExpired { env.app.authError = nil }
            LoginSupport.closeIssueWindows()
        }
        .task(id: cooldown) {
            guard cooldown > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { cooldown -= 1 }
        }
    }

    // MARK: Email

    private var emailStep: some View {
        VStack(spacing: 0) {
            LoginHeader(title: tr("auth", "signin.title"), description: tr("auth", "signin.description"))
            VStack(alignment: .leading, spacing: 14) {
                if sessionExpired {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(tr("auth", "errors.session_expired")).font(Theme.Font.body)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("auth", "common.email")).font(Theme.Font.bodyMedium)
                    LoginEmailField(email: $email, placeholder: tr("auth", "common.email_placeholder"), onSubmit: sendCode)
                }
                if !error.isEmpty {
                    Text(error).font(Theme.Font.body).foregroundStyle(Theme.destructive)
                }
            }
            .padding(.top, 20)
            VStack(spacing: 10) {
                Button(action: sendCode) {
                    Text(loading ? tr("auth", "signin.sending") : tr("auth", "signin.continue"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                Button { openURL(env.app.browserSignInURL) } label: {
                    HStack(spacing: 8) {
                        LoginGoogleMark().frame(width: 15, height: 15)
                        Text(tr("auth", "signin.google"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(loading)
            }
            .padding(.top, 20)
        }
    }

    // MARK: Code

    private var codeStep: some View {
        VStack(spacing: 0) {
            LoginHeader(title: tr("auth", "verify.title"), description: tr("auth", "verify.description", ["email": email]))
            VStack(spacing: 14) {
                LoginCodeField(code: $code, disabled: loading) { verify($0) }
                if !error.isEmpty {
                    Text(error).font(Theme.Font.body).foregroundStyle(Theme.destructive).multilineTextAlignment(.center)
                }
                Button(cooldown > 0 ? tr("auth", "verify.resend_cooldown", ["seconds": cooldown]) : tr("auth", "verify.resend"), action: resend)
                    .buttonStyle(.link)
                    .font(Theme.Font.body)
                    .disabled(cooldown > 0)
            }
            .padding(.top, 20)
            Button {
                step = .email
                code = ""
                error = ""
            } label: {
                Text(tr("auth", "common.back")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(.top, 20)
        }
    }

    // MARK: Actions

    private func sendCode() {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard !loading else { return }
        guard !address.isEmpty else {
            error = tr("auth", "common.email_required")
            return
        }
        loading = true
        error = ""
        Task {
            defer { loading = false }
            do {
                try await env.app.api.sendCode(email: address)
                step = .code
                code = ""
                cooldown = 60
            } catch {
                self.error = LoginView.message(error) ?? "\(tr("auth", "errors.send_failed")) \(tr("auth", "errors.server_unreachable"))"
            }
        }
    }

    private func verify(_ value: String) {
        guard value.count == 6, !loading else { return }
        loading = true
        error = ""
        Task {
            await env.app.verify(email: email.trimmingCharacters(in: .whitespaces), code: value)
            if env.app.phase != .signedIn {
                error = env.app.authError.flatMap { $0.isEmpty ? nil : $0 } ?? tr("auth", "errors.code_invalid")
                env.app.authError = nil
                code = ""
                loading = false
            }
        }
    }

    private func resend() {
        guard cooldown == 0 else { return }
        error = ""
        Task {
            do {
                try await env.app.api.sendCode(email: email.trimmingCharacters(in: .whitespaces))
                cooldown = 60
            } catch {
                self.error = LoginView.message(error) ?? tr("auth", "errors.resend_failed")
            }
        }
    }

    private static func message(_ error: Error) -> String? {
        if let e = error as? APIError { return e.message.isEmpty ? nil : e.message }
        if error is URLError { return nil }
        let text = error.localizedDescription
        return text.isEmpty ? nil : text
    }
}

private enum LoginStep {
    case email, code
}

enum LoginSupport {
    /// What `AppModel.signOut(serverRejected:)` leaves in `authError`.
    static let sessionExpiredMessage = "Your session expired. Sign in again."

    /// Dedicated issue windows belong to the account that opened them; on
    /// sign-out they close (desktop auth-session-coordinator.ts).
    @MainActor static func closeIssueWindows() {
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("issue") == true {
            window.close()
        }
    }
}

/// Server endpoint for self-hosted deployments, reachable before sign-in.
private struct LoginServerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var apiURL = ""
    @State private var appURL = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("API URL", text: $apiURL, prompt: Text(ServerConfig.production.apiURL.absoluteString))
                TextField("Web app URL", text: $appURL, prompt: Text(ServerConfig.production.appURL.absoluteString))
            } footer: {
                Text("Self-hosted servers use the API and web URLs of your deployment. Changes apply after relaunch; each server keeps its own sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if saved {
                Text("Saved. Quit and reopen Multica to connect.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(tr("common", "cancel")) { dismiss() } }
            ToolbarItem(placement: .destructiveAction) {
                Button("Use Multica Cloud") {
                    AppEnvironment.resetServerConfig()
                    apiURL = ServerConfig.production.apiURL.absoluteString
                    appURL = ServerConfig.production.appURL.absoluteString
                    saved = true
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("common", "save")) {
                    guard let api = URL(string: apiURL), let web = URL(string: appURL), api.scheme != nil, web.scheme != nil else { return }
                    AppEnvironment.saveServerConfig(apiURL: api, appURL: web)
                    saved = true
                }
            }
        }
        .onAppear {
            apiURL = env.app.config.apiURL.absoluteString
            appURL = env.app.config.appURL.absoluteString
        }
    }
}

private struct LoginCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(24)
            .frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

private struct LoginHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .padding(.bottom, 10)
            Text(title).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
            Text(description).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LoginEmailField: View {
    @Binding var email: String
    let placeholder: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $email)
            .textFieldStyle(.roundedBorder)
            .textContentType(.emailAddress)
            .controlSize(.large)
            .focused($focused)
            .onSubmit(onSubmit)
            .onAppear { focused = true }
    }
}

/// Six-slot one-time-code input that submits on the sixth character
/// (upstream InputOTP).
private struct LoginCodeField: View {
    @Binding var code: String
    let disabled: Bool
    let onComplete: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in
                    let chars = Array(code)
                    let isActive = focused && (i == chars.count || (i == 5 && chars.count == 6))
                    Text(i < chars.count ? String(chars[i]) : "")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .frame(width: 40, height: 44)
                        .background(Rectangle().fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(Rectangle().strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isActive ? 2 : 1))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.15)))
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($focused)
                .frame(width: 240, height: 44)
                .opacity(0.02)
        }
        .opacity(disabled ? 0.6 : 1)
        .disabled(disabled)
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        .onChange(of: code) { _, new in
            let cleaned = String(new.filter { $0.isLetter || $0.isNumber }.prefix(6))
            if cleaned != new {
                code = cleaned
                return
            }
            if cleaned.count == 6 { onComplete(cleaned) }
        }
        .onChange(of: disabled) { if !disabled { focused = true } }
    }
}

/// The four-colour Google "G" from the upstream button.
private struct LoginGoogleMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 24
            ctx.scaleBy(x: s, y: s)
            func fill(_ d: (inout Path) -> Void, _ hex: UInt32) {
                var p = Path()
                d(&p)
                ctx.fill(p, with: .color(Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)))
            }
            fill({ p in
                p.move(to: CGPoint(x: 22.56, y: 12.25)); p.addCurve(to: CGPoint(x: 22.36, y: 10), control1: CGPoint(x: 22.56, y: 11.47), control2: CGPoint(x: 22.49, y: 10.72))
                p.addLine(to: CGPoint(x: 12, y: 10)); p.addLine(to: CGPoint(x: 12, y: 14.26)); p.addLine(to: CGPoint(x: 17.92, y: 14.26))
                p.addCurve(to: CGPoint(x: 15.72, y: 17.58), control1: CGPoint(x: 17.66, y: 15.63), control2: CGPoint(x: 16.88, y: 16.79))
                p.addLine(to: CGPoint(x: 15.72, y: 20.35)); p.addLine(to: CGPoint(x: 19.29, y: 20.35))
                p.addCurve(to: CGPoint(x: 22.56, y: 12.25), control1: CGPoint(x: 21.37, y: 18.43), control2: CGPoint(x: 22.56, y: 15.61))
                p.closeSubpath()
            }, 0x4285F4)
            fill({ p in
                p.move(to: CGPoint(x: 12, y: 23)); p.addCurve(to: CGPoint(x: 19.28, y: 20.34), control1: CGPoint(x: 14.97, y: 23), control2: CGPoint(x: 17.46, y: 22.02))
                p.addLine(to: CGPoint(x: 15.71, y: 17.57)); p.addCurve(to: CGPoint(x: 12, y: 18.63), control1: CGPoint(x: 14.73, y: 18.23), control2: CGPoint(x: 13.48, y: 18.63))
                p.addCurve(to: CGPoint(x: 5.84, y: 14.1), control1: CGPoint(x: 9.14, y: 18.63), control2: CGPoint(x: 6.71, y: 16.7))
                p.addLine(to: CGPoint(x: 2.18, y: 14.1)); p.addLine(to: CGPoint(x: 2.18, y: 16.94))
                p.addCurve(to: CGPoint(x: 12, y: 23), control1: CGPoint(x: 3.99, y: 20.53), control2: CGPoint(x: 7.7, y: 23))
                p.closeSubpath()
            }, 0x34A853)
            fill({ p in
                p.move(to: CGPoint(x: 5.84, y: 14.09)); p.addCurve(to: CGPoint(x: 5.49, y: 12), control1: CGPoint(x: 5.62, y: 13.43), control2: CGPoint(x: 5.49, y: 12.73))
                p.addCurve(to: CGPoint(x: 5.84, y: 9.91), control1: CGPoint(x: 5.49, y: 11.27), control2: CGPoint(x: 5.62, y: 10.57))
                p.addLine(to: CGPoint(x: 5.84, y: 7.07)); p.addLine(to: CGPoint(x: 2.18, y: 7.07))
                p.addCurve(to: CGPoint(x: 1, y: 12), control1: CGPoint(x: 1.43, y: 8.55), control2: CGPoint(x: 1, y: 10.22))
                p.addCurve(to: CGPoint(x: 2.18, y: 16.93), control1: CGPoint(x: 1, y: 13.78), control2: CGPoint(x: 1.43, y: 15.45))
                p.addLine(to: CGPoint(x: 5.84, y: 14.09)); p.closeSubpath()
            }, 0xFBBC05)
            fill({ p in
                p.move(to: CGPoint(x: 12, y: 5.38)); p.addCurve(to: CGPoint(x: 16.21, y: 7.02), control1: CGPoint(x: 13.62, y: 5.38), control2: CGPoint(x: 15.06, y: 5.94))
                p.addLine(to: CGPoint(x: 19.36, y: 3.87)); p.addCurve(to: CGPoint(x: 12, y: 1), control1: CGPoint(x: 17.45, y: 2.09), control2: CGPoint(x: 14.97, y: 1))
                p.addCurve(to: CGPoint(x: 2.18, y: 7.07), control1: CGPoint(x: 7.7, y: 1), control2: CGPoint(x: 3.99, y: 3.47))
                p.addLine(to: CGPoint(x: 5.84, y: 9.91)); p.addCurve(to: CGPoint(x: 12, y: 5.38), control1: CGPoint(x: 6.71, y: 7.31), control2: CGPoint(x: 9.14, y: 5.38))
                p.closeSubpath()
            }, 0xEA4335)
        }
    }
}
