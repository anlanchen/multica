import MulticaCore
import SwiftUI

/// Native-only panels (server endpoint, diagnostics) shown in Settings.
struct ServerSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var apiURL = ""
    @State private var appURL = ""
    @State private var saved = false

    var body: some View {
        SettingsSectionView(description: "Self-hosted servers use the API and web URLs of your deployment. Changes apply after relaunch; each server keeps its own sign-in.") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCardView {
                    SettingsRowView("API URL", size: .text) {
                        TextField("", text: $apiURL, prompt: Text("https://api.multica.ai")).textFieldStyle(.roundedBorder)
                    }
                    SettingsRowView("Web app URL", size: .text) {
                        TextField("", text: $appURL, prompt: Text("https://multica.ai")).textFieldStyle(.roundedBorder)
                    }
                }
                HStack {
                    Button("Use Multica Cloud") {
                        AppEnvironment.resetServerConfig()
                        apiURL = ServerConfig.production.apiURL.absoluteString
                        appURL = ServerConfig.production.appURL.absoluteString
                        saved = true
                    }
                    Spacer()
                    if saved {
                        Text("Saved. Quit and reopen Multica to connect.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Save") {
                        guard let api = URL(string: apiURL), let web = URL(string: appURL), api.scheme != nil, web.scheme != nil else { return }
                        AppEnvironment.saveServerConfig(apiURL: api, appURL: web)
                        saved = true
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 32) {
            SettingsSectionView(title: "HTTP") {
                SettingsCardView {
                    value("Requests", "\(network.requests)")
                    value("Deduplicated (shared in flight)", "\(network.deduplicated)")
                    value("Received", ByteCountFormatter.string(fromByteCount: Int64(network.bytesReceived), countStyle: .binary))
                    value("Failures", "\(network.failures)")
                }
            }
            SettingsSectionView(title: "Realtime") {
                SettingsCardView {
                    value("Frames", "\(realtime.frames)")
                    value("Received", ByteCountFormatter.string(fromByteCount: Int64(realtime.bytes), countStyle: .binary))
                    value("Task messages kept / dropped", "\(realtime.taskMessagesKept) / \(realtime.taskMessagesDropped)")
                    value("Batches delivered to UI", "\(realtime.batchesEmitted)")
                    value("Decode time (total)", "\(realtime.decodeTime)")
                    value("Reconnects", "\(realtime.reconnects)")
                }
            }
        }
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

    private func value(_ label: String, _ value: String) -> some View {
        SettingsRowView(label) {
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
