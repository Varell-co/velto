import AppKit
import SwiftUI
import VeltoCore

/// Edits one source. Every change is saved right away; the monitor waits a moment before re-checking.
struct SourceEditor: View {
    @ObservedObject var monitor: Monitor
    @State var source: Source
    @State private var secret = ""
    @State private var testResult: TestResult?
    @State private var testing = false
    @FocusState private var nameFocused: Bool

    enum TestResult { case success(Int), failure(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            GlassSection(title: "Connection", footer: urlHelp) {
                GlassRow(label: "Name") {
                    TextField("", text: $source.name, prompt: Text("production")).glassField().frame(width: 360).focused($nameFocused)
                }
                GlassRow(label: "Type") {
                    Picker("", selection: $source.kind) {
                        ForEach(SourceKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if source.kind != .probes {
                    GlassRow(label: "URL") {
                        TextField("", text: $source.url, prompt: Text(urlPrompt)).glassField().frame(width: 360)
                    }
                }
                if source.kind == .prometheus {
                    GlassRow(label: "Watch scrape targets", detail: "Adds a \"Targets up\" check: warning when any target is down, critical above 10%") {
                        Toggle("", isOn: $source.watchTargets).toggleStyle(.switch).labelsHidden()
                    }
                }
                if source.kind.usesTenant {
                    GlassRow(label: "Tenant", detail: "Sent as X-Scope-OrgID") {
                        TextField("", text: $source.orgID, prompt: Text("Optional")).glassField().frame(width: 360)
                    }
                }
            }

            if source.kind == .probes {
                GlassSection(title: "Probes", footer: "Checked with every refresh, no Prometheus needed. A failing probe counts as firing.") {
                    ForEach($source.probes) { $probe in
                        ProbeEditor(probe: $probe, skipTLSVerify: source.skipTLSVerify) { source.probes.removeAll { $0.id == probe.id } }
                    }
                    HStack {
                        Menu {
                            ForEach(Probe.Kind.allCases, id: \.self) { kind in
                                Button(kind.label) { source.probes.append(Probe(type: kind)) }
                            }
                        } label: { Label("Add Probe", systemImage: "plus") }
                            .menuStyle(.button)
                            .fixedSize()
                        Spacer()
                    }
                }
            }

            if source.kind != .probes {
                GlassSection(title: "Authentication") {
                    GlassRow(label: "Method") {
                        Picker("", selection: $source.auth) {
                            ForEach(AuthMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    switch source.auth {
                    case .none:
                        EmptyView()
                    case .bearer:
                        GlassRow(label: "Token", detail: "Stored in your Keychain") {
                            SecureField("", text: $secret).glassField().frame(width: 360)
                        }
                    case .command:
                        GlassRow(label: "Command", detail: "Runs in your login shell before every check. Its output is sent as a bearer token.") {
                            TextField("", text: $source.tokenCommand, prompt: Text("az account get-access-token …"))
                                .font(.system(size: 12, design: .monospaced))
                                .glassField().frame(width: 360)
                        }
                    case .basic:
                        GlassRow(label: "Username") {
                            TextField("", text: $source.username).glassField().frame(width: 360)
                        }
                        GlassRow(label: "Password", detail: "Stored in your Keychain") {
                            SecureField("", text: $secret).glassField().frame(width: 360)
                        }
                    }
                }

            }

            if source.kind == .prometheus || source.kind == .mimir {
                GlassSection(title: "Pinned queries",
                             footer: "Instant PromQL queries checked with every refresh. A value past a threshold counts as firing; no data is never shown as healthy.") {
                    ForEach($source.queries) { $query in
                        QueryEditor(query: $query, source: source) { source.queries.removeAll { $0.id == query.id } }
                    }
                    HStack(spacing: 10) {
                        Button { source.queries.append(PinnedQuery()) } label: { Label("Add Query", systemImage: "plus") }
                            .buttonStyle(GlassButtonStyle())
                        Menu {
                            ForEach(PinnedQuery.presets, id: \.name) { preset in
                                Button(preset.name) { var copy = preset; copy.id = UUID(); source.queries.append(copy) }
                            }
                        } label: { Label("Presets", systemImage: "list.bullet") }
                            .menuStyle(.button)
                            .fixedSize()
                        Spacer()
                    }
                }
            }

            GlassSection(title: "Only check when",
                         footer: "Otherwise the source shows as paused instead of unreachable, and its cached alerts aren't counted.") {
                GlassRow(label: "Condition") {
                    Picker("", selection: conditionMode) {
                        Text("Always").tag(0)
                        Text("Connected to a VPN").tag(1)
                        Text("This host resolves").tag(2)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if case .resolves(let host)? = source.requires {
                    GlassRow(label: "Host", detail: "Use an internal name that only resolves on the corporate network") {
                        TextField("", text: Binding(get: { host }, set: { source.requires = .resolves(host: $0) }),
                                  prompt: Text(URL(string: source.url)?.host ?? "internal.example.com"))
                            .glassField().frame(width: 360)
                    }
                }
            }

            GlassSection(title: "Advanced") {
                if source.kind != .probes {
                    GlassRow(label: "Dashboard link", detail: "Opened from alerts that have no link of their own") {
                        TextField("", text: $source.linkURL, prompt: Text("https://grafana.example.com/alerting/list")).glassField().frame(width: 360)
                    }
                }
                GlassRow(label: "Skip TLS certificate verification",
                         detail: source.skipTLSVerify ? "Only for self-signed certificates on networks you trust. Anyone in the middle could read the token." : nil) {
                    Toggle("", isOn: $source.skipTLSVerify).toggleStyle(.switch).labelsHidden()
                }
            }

            if source.kind != .probes {
                HStack(spacing: 14) {
                    Button { test() } label: {
                        Label(testing ? "Testing…" : "Test Connection", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(testing || !source.isComplete)
                    testLabel
                    Spacer()
                }
                .animation(Glass.easeOut(), value: testing)
            }
        }
        .onAppear {
            secret = Secrets.read(source.id) ?? ""
            if source.name.isEmpty && source.url.isEmpty { nameFocused = true }
        }
        .onChange(of: source) { new in
            testResult = nil
            monitor.update { config in
                if let index = config.sources.firstIndex(where: { $0.id == new.id }) { config.sources[index] = new }
            }
        }
        .onChange(of: secret) { value in
            testResult = nil
            Secrets.write(value, for: source.id)
        }
    }

    private var conditionMode: Binding<Int> {
        Binding(get: {
            switch source.requires { case nil: 0; case .vpn?: 1; case .resolves?: 2 }
        }, set: { mode in
            switch mode {
            case 1: source.requires = .vpn
            case 2: source.requires = .resolves(host: URL(string: source.url)?.host ?? "")
            default: source.requires = nil
            }
        })
    }

    @ViewBuilder private var testLabel: some View {
        switch testResult {
        case .success(let count)?:
            Label("Connected · \(count) firing", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Glass.healthy)
        case .failure(let message)?:
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Glass.critical).lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    private var urlPrompt: String {
        switch source.kind {
        case .prometheus: "https://prometheus.example.com"
        case .mimir: "https://mimir.example.com"
        case .grafana: "https://grafana.example.com"
        case .alertmanager: "https://alertmanager.example.com"
        case .probes: ""
        }
    }

    private var urlHelp: String {
        guard let url = source.alertsURL() else {
            return source.kind == .alertmanager
                ? "Enter the base URL, e.g. https://alertmanager.example.com or https://mimir.example.com/alertmanager"
                : "Enter the base URL, starting with https://"
        }
        return "Velto reads \(url.absoluteString)"
    }

    private func test() {
        testing = true
        let source = source
        Task {
            let result = await Monitor.test(source)
            testing = false
            switch result {
            case .success(let alerts): testResult = .success(alerts.count)
            case .failure(let error): testResult = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

/// One pinned query: name, PromQL, unit, which side is bad, thresholds, and a Test that shows the value now.
private struct QueryEditor: View {
    @Binding var query: PinnedQuery
    let source: Source
    let remove: () -> Void
    @State private var result: Check?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("", text: $query.name, prompt: Text("Name, e.g. Disk free")).glassField().frame(width: 220)
                Picker("", selection: $query.unit) {
                    ForEach(PinnedQuery.Unit.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(GlassButtonStyle(destructive: true))
                    .help("Remove query")
            }
            TextField("", text: $query.query, prompt: Text("count(up == 0) or vector(0)"), axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .glassField()
            HStack(spacing: 10) {
                Text("Bad when").font(.system(size: 12)).foregroundStyle(Glass.muted)
                Picker("", selection: $query.direction) {
                    Text("above").tag(PinnedQuery.Direction.above)
                    Text("below").tag(PinnedQuery.Direction.below)
                }
                .labelsHidden().fixedSize()
                Text("warn").font(.system(size: 12)).foregroundStyle(Glass.muted)
                ThresholdField(value: $query.warn)
                Text("crit").font(.system(size: 12)).foregroundStyle(Glass.muted)
                ThresholdField(value: $query.crit)
                Spacer()
                if let result {
                    Text(result.state == .unknown ? (result.message ?? result.display) : result.display)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(result.state == .ok ? Glass.healthy : result.state == .crit ? Glass.critical : Glass.warning)
                        .lineLimit(2)
                }
                Button(testing ? "Testing…" : "Test") { test() }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(testing || query.query.trimmingCharacters(in: .whitespaces).isEmpty || !source.isComplete)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: query) { _ in result = nil }
    }

    private func test() {
        testing = true
        let query = query, source = source
        Task {
            result = await Monitor.test(query, on: source)
            testing = false
        }
    }
}

/// One probe: type, target, and a Test that runs it now.
private struct ProbeEditor: View {
    @Binding var probe: Probe
    let skipTLSVerify: Bool
    let remove: () -> Void
    @State private var result: Check?
    @State private var testing = false

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $probe.type) {
                ForEach(Probe.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
            TextField("", text: $probe.target, prompt: Text(probe.type.placeholder))
                .font(.system(size: 12, design: .monospaced))
                .glassField()
            TextField("", text: $probe.name, prompt: Text("Name (optional)")).glassField().frame(width: 140)
            if let result {
                Text(result.display)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(result.state == .ok ? Glass.healthy : result.state == .crit ? Glass.critical : Glass.warning)
                    .help(result.message ?? result.display)
                    .lineLimit(1)
            }
            Button(testing ? "…" : "Test") {
                testing = true
                let probe = probe
                Task {
                    result = await ProbeRunner.run(probe, skipTLSVerify: skipTLSVerify)
                    testing = false
                }
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(testing || probe.target.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .buttonStyle(GlassButtonStyle(destructive: true))
                .help("Remove probe")
        }
        .onChange(of: probe) { _ in result = nil }
    }
}

/// An optional number. Keeps its own text so "0." survives while typing; empty means no threshold.
private struct ThresholdField: View {
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text("–"))
            .glassField()
            .frame(width: 70)
            .onAppear { text = value.map { PinnedQuery.Unit.none.format($0) } ?? "" }
            .onChange(of: text) { new in
                let trimmed = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                if trimmed.isEmpty { value = nil } else if let parsed = Double(trimmed) { value = parsed }
            }
    }
}

/// App preferences: checking, notifications, integrations, Pulse import.
struct SettingsForm: View {
    @ObservedObject var monitor: Monitor
    let notifier: Notifier
    @AppStorage(Notifier.enabledKey) private var notify = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let error = monitor.configError {
                Banner(icon: "exclamationmark.triangle.fill", color: Glass.warning, title: error,
                       text: "Velto won't overwrite the file. Fix or remove it at \(Store.configURL.path), then restart Velto.")
            }
            if !monitor.importNotes.isEmpty {
                Banner(icon: "info.circle.fill", color: Glass.info, title: "Imported from Pulse", text: monitor.importNotes.joined(separator: "\n")) {
                    Button("Got It") { monitor.importNotes = [] }.buttonStyle(GlassButtonStyle())
                }
            }

            GlassSection(title: "Checking") {
                GlassRow(label: "Check every") {
                    Picker("", selection: Binding(get: { monitor.config.refreshSeconds },
                                                  set: { value in monitor.update { $0.refreshSeconds = value } })) {
                        ForEach(Config.refreshChoices, id: \.self) { seconds in
                            Text(seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes").tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GlassRow(label: "Open at login", detail: loginError) {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                        .onChange(of: launchAtLogin) { enabled in
                            do { try LoginItem.setEnabled(enabled); loginError = nil }
                            catch { loginError = error.localizedDescription; launchAtLogin = LoginItem.isEnabled }
                        }
                }
                GlassRow(label: "Notify when an alert starts firing") {
                    Toggle("", isOn: $notify).toggleStyle(.switch).labelsHidden()
                        .onChange(of: notify) { on in if on { notifier.requestAuthorization() } }
                }
                GlassRow(label: "Notify when alerts resolve") {
                    Toggle("", isOn: Binding(get: { monitor.config.notifyResolved },
                                             set: { value in monitor.update { $0.notifyResolved = value } }))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(!notify)
                }
            }

            GlassSection(title: "Quiet hours", footer: "Pauses notifications only. Counts, the menu and status lines stay accurate.") {
                GlassRow(label: "Pause notifications") {
                    Toggle("", isOn: Binding(get: { monitor.config.quietHours != nil },
                                             set: { on in monitor.update { $0.quietHours = on ? QuietHours() : nil } }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if let quiet = monitor.config.quietHours {
                    GlassRow(label: "From") { minutePicker(quiet.start) { value in monitor.update { $0.quietHours?.start = value } } }
                    GlassRow(label: "Until") { minutePicker(quiet.end) { value in monitor.update { $0.quietHours?.end = value } } }
                    GlassRow(label: "Let critical alerts through") {
                        Toggle("", isOn: Binding(get: { quiet.allowCritical }, set: { value in monitor.update { $0.quietHours?.allowCritical = value } }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }

            GlassSection(title: "Integrations",
                         footer: "These read the cache Velto writes, so they never query your servers. The menu bar icon already shows the same information.") {
                Snippet(icon: "apple.terminal", title: "Terminal", code: "velto alerts")
                Snippet(icon: "sparkles", title: "Starship", code: """
                [custom.velto]
                command = "velto status --format starship"
                when = true
                format = "[$output]($style) "
                style = "bold #E66A56"
                """)
                Snippet(icon: "menubar.rectangle", title: "xbar or SwiftBar plugin (velto.1m.sh)", code: """
                #!/bin/bash
                exec \(cliPath) status --format xbar
                """)
            }

            if FileManager.default.fileExists(atPath: Store.pulseConfigURL.path) {
                GlassSection(title: "Pulse") {
                    GlassRow(label: "Import sources", detail: "From ~/.config/pulse/config.toml") {
                        Button("Import") { monitor.importFromPulse() }.buttonStyle(GlassButtonStyle())
                    }
                }
            }

            HStack(spacing: 14) {
                VeltoMark().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("velto \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .font(.system(size: 13, weight: .semibold))
                    Text("by Varell · Your infrastructure, at a glance.").font(.system(size: 12)).foregroundStyle(Glass.muted)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.configURL]) }
                    .buttonStyle(GlassButtonStyle())
            }
            .glassCard(padding: 16)
        }
    }

    /// Hour and minute of the day, stored as minutes after midnight.
    private func minutePicker(_ minutes: Int, set: @escaping (Int) -> Void) -> some View {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        return DatePicker("", selection: Binding(
            get: { midnight.addingTimeInterval(TimeInterval(minutes * 60)) },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
    }

    /// The Homebrew cask links `velto` onto PATH; without it, point at the copy inside the app.
    private var cliPath: String {
        for path in ["/opt/homebrew/bin/velto", "/usr/local/bin/velto"] where FileManager.default.fileExists(atPath: path) { return path }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/velto").path
    }
}

/// A tinted notice card for problems or one-off information at the top of Settings.
private struct Banner<Actions: View>: View {
    let icon: String
    let color: Color
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(Glass.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous).strokeBorder(color.opacity(0.30)))
    }
}

private extension Banner where Actions == EmptyView {
    init(icon: String, color: Color, title: String, text: String) {
        self.init(icon: icon, color: color, title: title, text: text) { EmptyView() }
    }
}

private struct Snippet: View {
    let icon: String
    let title: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.markIris).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(Glass.easeOut()) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(Glass.easeOut()) { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(GlassButtonStyle())
            }
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06)))
        }
    }
}
