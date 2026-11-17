import Foundation
import VeltoCore

/// Owns the config and the snapshot: polls every source on a timer and writes the snapshot that the menu
/// and every CLI integration read.
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var snapshot: Snapshot
    @Published private(set) var isRefreshing = false
    /// Set when config.json exists but can't be read; the file is then left alone rather than overwritten.
    @Published private(set) var configError: String?
    /// Lines from the Pulse import that need the user's attention, shown once in Settings.
    @Published var importNotes: [String] = []
    /// The result of the last upstream silence, shown for 10 seconds with an Undo.
    @Published private(set) var silenceNotice: SilenceNotice?

    struct SilenceNotice: Equatable, Identifiable {
        let id = UUID()
        let sourceID: UUID
        /// Set on success: what Undo expires.
        let silenceID: String?
        let message: String
        var isError: Bool { silenceID == nil }
    }

    /// Alerts that started firing since the previous successful check of their source.
    var onNewAlerts: (([(source: SourceSnapshot, alert: Alert)]) -> Void)?
    /// Alerts that stopped firing, when the user asked to hear about it.
    var onResolvedAlerts: (([(source: SourceSnapshot, alert: Alert)]) -> Void)?

    private var timer: Timer?
    private var pendingRefresh: Task<Void, Never>?
    private var pendingNetworkRefresh: Task<Void, Never>?
    /// The last hour of history, kept in memory for flap counts instead of re-reading the file each check.
    private var recentEvents: [HistoryEvent] = []
    private var lastPrune = Date.distantPast
    private var refreshQueued = false

    init() {
        var saved: Config?
        var loadError: String?
        do { saved = try Store.loadConfig() } catch {
            loadError = "config.json could not be read: \(error.localizedDescription)"
        }
        let config = saved ?? Config()
        self.config = config
        snapshot = Store.loadSnapshot() ?? Snapshot(refreshSeconds: config.refreshSeconds)
        configError = loadError
        // First launch for a Pulse user: bring their sources along instead of starting empty.
        if saved == nil, configError == nil, FileManager.default.fileExists(atPath: Store.pulseConfigURL.path) {
            importFromPulse()
        }
        recentEvents = History.load(since: Date().addingTimeInterval(-History.flapWindow))
        reconcile()
    }

    #if DEBUG
    /// Fixed data for snapshot rendering; touches no files.
    init(preview config: Config, snapshot: Snapshot) {
        self.config = config
        self.snapshot = snapshot
    }
    #endif

    func start() {
        schedule()
        refresh()
    }

    /// Checks every source at once. A request made while one is running is queued, not dropped, so a
    /// config edit mid-check is still picked up.
    func refresh() {
        guard !isRefreshing else { refreshQueued = true; return }
        let sources = config.sources.filter(\.isComplete)
        guard !sources.isEmpty else { return }
        isRefreshing = true
        Task {
            let results = await withTaskGroup(of: (UUID, Outcome).self) { group in
                for source in sources {
                    group.addTask {
                        if let condition = source.requires, !(await NetworkGate.satisfied(condition)) {
                            return (source.id, .paused(condition.pausedReason))
                        }
                        do {
                            let credentials = try await Secrets.credentials(for: source)
                            return (source.id, .checked(.success(try await Fetcher.fetch(for: source, credentials: credentials))))
                        } catch {
                            return (source.id, .checked(.failure(error)))
                        }
                    }
                }
                var results: [UUID: Outcome] = [:]
                for await (id, result) in group { results[id] = result }
                return results
            }
            apply(results, at: Date())
            isRefreshing = false
            if refreshQueued { refreshQueued = false; refresh() }
        }
    }

    private enum Outcome {
        /// The network condition is unmet: not fetched, nothing about the source changes but the reason.
        case paused(String)
        case checked(Result<SourceResult, Error>)
    }

    /// A network change: re-check soon, so a paused source resumes (or pauses) without waiting for the timer.
    /// Debounced, since joining a VPN fires several path updates in a row.
    func networkChanged() {
        guard config.sources.contains(where: { $0.requires != nil }) else { return }
        pendingNetworkRefresh?.cancel()
        pendingNetworkRefresh = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { refresh() }
        }
    }

    private func apply(_ results: [UUID: Outcome], at now: Date) {
        var started: [(source: SourceSnapshot, alert: Alert)] = []
        var ended: [(source: SourceSnapshot, alert: Alert)] = []
        for index in snapshot.sources.indices {
            guard let outcome = results[snapshot.sources[index].id] else { continue } // added mid-check
            guard case .checked(let result) = outcome else {
                if case .paused(let reason) = outcome { snapshot.sources[index].pausedReason = reason }
                continue
            }
            snapshot.sources[index].pausedReason = nil
            let merged = SnapshotMerge.merge(previous: snapshot.sources[index], result: result, now: now)
            snapshot.sources[index] = merged.source
            started += merged.started.map { (merged.source, $0) }
            ended += merged.ended.map { (merged.source, $0) }
        }
        snapshot.checkedAt = now
        config.mutes.removeAll { $0.until <= now }
        applyMutes(now: now)
        record(started: started, ended: ended, now: now)
        save()
        // Snoozed alerts and quiet hours silence notifications only; the counts above already stand.
        let quiet = config.quietHours
        func notifiable(_ item: (source: SourceSnapshot, alert: Alert)) -> Bool {
            let muted = config.mutes.contains { $0.until > now && $0.matches(item.alert, in: item.source.id) }
            return !muted && (quiet?.allows(item.alert, at: now) ?? true)
        }
        started = started.filter(notifiable)
        ended = ended.filter(notifiable)
        if !started.isEmpty { onNewAlerts?(started) }
        if !ended.isEmpty, config.notifyResolved { onResolvedAlerts?(ended) }
    }

    /// Appends fire and resolve events to history and marks alerts that keep coming back.
    private func record(started: [(source: SourceSnapshot, alert: Alert)], ended: [(source: SourceSnapshot, alert: Alert)], now: Date) {
        let events = started.map { HistoryEvent(.fired, $0.alert, in: $0.source, at: now) }
            + ended.map { HistoryEvent(.resolved, $0.alert, in: $0.source, at: now) }
        try? History.append(events)
        recentEvents = (recentEvents + events).filter { now.timeIntervalSince($0.at) < History.flapWindow }
        for s in snapshot.sources.indices {
            for a in snapshot.sources[s].alerts.indices {
                let count = History.flapCount(alertID: snapshot.sources[s].alerts[a].id, events: recentEvents, now: now)
                snapshot.sources[s].alerts[a].flapCount = count >= History.flapThreshold ? count : nil
            }
        }
        if now.timeIntervalSince(lastPrune) > 3600 {
            lastPrune = now
            try? History.prune(now: now)
        }
    }

    private func applyMutes(now: Date = Date()) {
        for index in snapshot.sources.indices { Snooze.apply(config.mutes, to: &snapshot.sources[index], now: now) }
    }

    /// Snoozes one alert, or every alert with its name in that source, until `until`. Local only.
    func snooze(_ alert: Alert, in sourceID: UUID, scope: Snooze.Scope, until: Date) {
        config.mutes.removeAll { $0.sourceID == sourceID && $0.alertName == alert.name && (scope == .name || $0.alertID == alert.id) }
        config.mutes.append(Mute(sourceID: sourceID, alertName: alert.name, alertID: scope == .alert ? alert.id : nil, until: until))
        applyMutes()
        save()
    }

    /// Lifts every snooze that covers this alert, whether set on the alert or on its name.
    func unsnooze(_ alert: Alert, in sourceID: UUID) {
        config.mutes.removeAll { $0.matches(alert, in: sourceID) }
        applyMutes()
        save()
    }

    /// Every settings change goes through here: save, re-align the snapshot, and check again shortly.
    /// The delay lets someone finish typing a URL before it is tried.
    func update(_ change: (inout Config) -> Void) {
        let old = config
        change(&config)
        guard config != old else { return }
        for source in config.sources {
            if let before = old.sources.first(where: { $0.id == source.id }), connectionChanged(before, source),
               let index = snapshot.sources.firstIndex(where: { $0.id == source.id }) {
                // Alerts from the old URL must not show up as if they came from the new one.
                snapshot.sources[index] = SourceSnapshot(source: source)
            }
        }
        for removed in old.sources where !config.sources.contains(where: { $0.id == removed.id }) {
            Secrets.delete(removed.id)
            config.mutes.removeAll { $0.sourceID == removed.id }
        }
        reconcile()
        if config.refreshSeconds != old.refreshSeconds { schedule() }
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { refresh() }
        }
    }

    func importFromPulse() {
        guard let text = try? String(contentsOf: Store.pulseConfigURL, encoding: .utf8) else { return }
        let result = PulseImport(toml: text)
        for (id, secret) in result.secrets { Secrets.write(secret, for: id) }
        let existing = Set(config.sources.map { $0.url + $0.orgID })
        let added = result.config.sources.filter { !existing.contains($0.url + $0.orgID) }
        if config.sources.isEmpty { config.refreshSeconds = result.config.refreshSeconds }
        config.sources += added
        importNotes = ["Imported \(Format.count(added.count, "source")) from Pulse."] + result.notes
        reconcile()
    }

    /// One snapshot entry per configured source, in config order, keeping what is known about each.
    /// Sources still being filled in stay out of the snapshot: a half-typed URL is not "offline".
    private func reconcile() {
        snapshot.refreshSeconds = config.refreshSeconds
        snapshot.sources = config.sources.filter(\.isComplete).map { source in
            guard var existing = snapshot.sources.first(where: { $0.id == source.id }) else { return SourceSnapshot(source: source) }
            existing.name = source.displayName
            existing.kind = source.kind
            return existing
        }
        save()
    }

    private func save() {
        // A broken config is left for the user to fix; saving would replace it with defaults.
        if configError == nil { try? Store.save(config) }
        try? Store.save(snapshot)
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.refreshSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = Double(config.refreshSeconds) * 0.1
    }

    private func connectionChanged(_ a: Source, _ b: Source) -> Bool {
        var a = a, b = b
        // Name, link and network condition don't change where alerts come from.
        a.name = ""; b.name = ""; a.linkURL = ""; b.linkURL = ""; a.requires = nil; b.requires = nil
        return a != b
    }

    /// Creates an Alertmanager silence matching exactly this alert's labels. Checks again on success,
    /// so the alert leaves the list as soon as the server agrees.
    func silence(_ alert: Alert, in sourceID: UUID, until: Date) async {
        guard let source = config.sources.first(where: { $0.id == sourceID }) else { return }
        do {
            let credentials = try await Secrets.credentials(for: source)
            guard let request = SilenceRequest.make(source: source, alert: alert, until: until, user: NSUserName(), credentials: credentials) else {
                throw FetchError.invalidURL
            }
            let id = try SilenceRequest.silenceID(from: try await Fetcher.send(request, for: source))
            notify(SilenceNotice(sourceID: sourceID, silenceID: id, message: "Silenced until \(Format.clock(until))"))
            refresh()
        } catch {
            notify(SilenceNotice(sourceID: sourceID, silenceID: nil, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    /// Undo: expires the silence upstream and checks again.
    func expireSilence(_ id: String, in sourceID: UUID) async {
        guard let source = config.sources.first(where: { $0.id == sourceID }) else { return }
        do {
            let credentials = try await Secrets.credentials(for: source)
            guard let request = SilenceRequest.expire(source: source, id: id, credentials: credentials) else { throw FetchError.invalidURL }
            _ = try await Fetcher.send(request, for: source)
            silenceNotice = nil
            refresh()
        } catch {
            notify(SilenceNotice(sourceID: sourceID, silenceID: nil, message: "Undo failed · " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)))
        }
    }

    private func notify(_ notice: SilenceNotice) {
        silenceNotice = notice
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if silenceNotice?.id == notice.id { silenceNotice = nil }
        }
    }

    /// For a pinned query's "Test" in Settings: its current value, nothing saved.
    nonisolated static func test(_ query: PinnedQuery, on source: Source) async -> Check {
        do { return await Fetcher.check(query, for: source, credentials: try await Secrets.credentials(for: source)) }
        catch { return query.check(error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    }

    /// For "Test connection" in Settings: one source, nothing saved.
    nonisolated static func test(_ source: Source) async -> Result<[Alert], Error> {
        do { return .success(try await Fetcher.alerts(for: source, credentials: try await Secrets.credentials(for: source))) }
        catch { return .failure(error) }
    }
}
