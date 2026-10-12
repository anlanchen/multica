import MulticaCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ServerSettings()
                .tabItem { SwiftUI.Label("Server", systemImage: "network") }
            DiagnosticsView()
                .tabItem { SwiftUI.Label("Diagnostics", systemImage: "gauge.with.dots.needle.33percent") }
        }
        .frame(width: 520, height: 360)
    }
}

struct ServerSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var apiURL = ""
    @State private var appURL = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("API URL", text: $apiURL, prompt: Text("https://api.multica.ai"))
                TextField("Web app URL", text: $appURL, prompt: Text("https://multica.ai"))
            } footer: {
                Text("Self-hosted servers use the API and web URLs of your deployment. Changes apply after relaunch; each server keeps its own sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Use Multica Cloud") {
                    AppEnvironment.resetServerConfig()
                    apiURL = ServerConfig.production.apiURL.absoluteString
                    appURL = ServerConfig.production.appURL.absoluteString
                    saved = true
                }
                Spacer()
                Button("Save") {
                    guard let api = URL(string: apiURL), let web = URL(string: appURL), api.scheme != nil, web.scheme != nil else { return }
                    AppEnvironment.saveServerConfig(apiURL: api, appURL: web)
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
            }
            if saved {
                Text("Saved. Quit and reopen Multica to connect.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiURL = env.app.config.apiURL.absoluteString
            appURL = env.app.config.appURL.absoluteString
        }
    }
}

/// Live client-side counters, refreshed once a second while visible.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var network = NetworkMetrics()
    @State private var realtime = RealtimeMetrics()

    var body: some View {
        Form {
            Section("HTTP") {
                LabeledContent("Requests", value: "\(network.requests)")
                LabeledContent("Deduplicated (shared in flight)", value: "\(network.deduplicated)")
                LabeledContent("Received", value: ByteCountFormatter.string(fromByteCount: Int64(network.bytesReceived), countStyle: .binary))
                LabeledContent("Failures", value: "\(network.failures)")
            }
            Section("Realtime") {
                LabeledContent("Frames", value: "\(realtime.frames)")
                LabeledContent("Received", value: ByteCountFormatter.string(fromByteCount: Int64(realtime.bytes), countStyle: .binary))
                LabeledContent("Task messages kept / dropped", value: "\(realtime.taskMessagesKept) / \(realtime.taskMessagesDropped)")
                LabeledContent("Batches delivered to UI", value: "\(realtime.batchesEmitted)")
                LabeledContent("Decode time (total)", value: "\(realtime.decodeTime)")
                LabeledContent("Reconnects", value: "\(realtime.reconnects)")
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                network = await env.app.api.metrics
                if let session = env.app.session {
                    realtime = await session.realtime.metrics
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
