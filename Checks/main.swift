import Foundation
import VeltoCore

// `swift run VeltoChecks`: plain preconditions, no XCTest, so it also runs with Command Line Tools only.

let now = Date(timeIntervalSince1970: 1_800_000_000)
let prod = Source(name: "production", kind: .prometheus, url: "https://prom.example.com/")
let lab = Source(name: "homelab", kind: .mimir, url: "https://mimir.example.com/prometheus", orgID: "lab")

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    precondition(condition, message, file: file, line: line)
}

func checkSeverity() {
    check(Severity(label: "critical") == .critical && Severity(label: "page") == .critical, "critical spellings")
    check(Severity(label: "2 - High") == .critical && Severity(label: "3 - Moderate") == .warning, "ServiceNow-style priorities")
    check(Severity(label: "WARNING") == .warning && Severity(label: "info") == .info, "case-insensitive")
    check(Severity(label: nil) == .none && Severity(label: "") == .none, "missing severity")
    check(Severity(label: "weird") == .warning, "unknown but present counts as warning")
    check(Severity.critical < .warning && Severity.info < Severity.none, "worst sorts first")
}

func checkURLs() {
    check(prod.alertsURL()?.absoluteString == "https://prom.example.com/api/v1/alerts", "prometheus path, trailing slash dropped")
    check(lab.alertsURL()?.absoluteString == "https://mimir.example.com/prometheus/api/v1/alerts", "mimir url that already ends in /prometheus")
    let mimir = Source(kind: .mimir, url: "https://mimir.example.com")
    check(mimir.alertsURL()?.absoluteString == "https://mimir.example.com/prometheus/api/v1/alerts", "mimir prefix added")
    check(Source(kind: .grafana, url: "https://g.example.com").alertsURL()?.path == "/api/alertmanager/grafana/api/v2/alerts", "grafana path")
    check(Source(url: "prom.example.com").alertsURL() == nil, "scheme required")
    check(Source(url: "").alertsURL() == nil, "empty url")

    check(lab.request(credentials: Credentials())?.value(forHTTPHeaderField: "X-Scope-OrgID") == "lab", "tenant header")
    check(prod.request(credentials: Credentials())?.value(forHTTPHeaderField: "Authorization") == nil, "no auth by default")
    var bearer = prod; bearer.auth = .bearer
    check(bearer.request(credentials: Credentials(token: "t0k"))?.value(forHTTPHeaderField: "Authorization") == "Bearer t0k", "bearer")
    var basic = prod; basic.auth = .basic; basic.username = "me"
    check(basic.request(credentials: Credentials(password: "pw"))?.value(forHTTPHeaderField: "Authorization") == "Basic bWU6cHc=", "basic")
    var tenantOnPrometheus = prod; tenantOnPrometheus.orgID = "x"
    check(tenantOnPrometheus.request(credentials: Credentials())?.value(forHTTPHeaderField: "X-Scope-OrgID") == nil, "tenant only for Mimir")
}

func checkParsing() throws {
    let prometheus = Data("""
    {"status":"success","data":{"alerts":[
      {"labels":{"alertname":"DiskSpaceLow","severity":"warning","instance":"postgres-02"},"annotations":{"summary":"Disk at 91%"},
       "state":"firing","activeAt":"2027-01-15T07:52:00.60602144+01:00","value":"1e+00"},
      {"labels":{"alertname":"HighMemoryUsage","severity":"critical","instance":"api-server-01","job":"node"},"annotations":{},
       "state":"firing","activeAt":"2027-01-15T06:37:00Z"},
      {"labels":{"alertname":"Pending"},"annotations":{},"state":"pending","activeAt":"2027-01-15T07:59:00Z"}
    ]}}
    """.utf8)
    let alerts = try AlertParser.prometheus(prometheus)
    check(alerts.count == 2, "pending alerts are not firing")
    check(alerts[0].name == "HighMemoryUsage" && alerts[0].severity == .critical, "critical first")
    check(alerts[0].target == "api-server-01", "instance is the target")
    check(alerts[1].summary == "Disk at 91%", "summary annotation")
    check(alerts[1].activeAt != nil, "nanosecond timestamps parse")
    try check(alerts[0].id != alerts[1].id && alerts[0].id == AlertParser.prometheus(prometheus)[0].id, "ids stable and distinct")

    check(AlertParser.parseDate("0001-01-01T00:00:00Z") == nil, "Go zero time is unknown")
    check(AlertParser.parseDate("2027-01-15T06:37:00.5Z") != nil, "short fractions")

    let grafana = Data("""
    [{"labels":{"alertname":"NodeExporterDown","grafana_folder":"Homelab"},"annotations":{"description":"down"},
      "startsAt":"2027-01-15T07:55:00Z","fingerprint":"abc123","generatorURL":"https://g.example.com/alerting/grafana/x/view",
      "status":{"state":"active"}},
     {"labels":{"alertname":"Silenced"},"startsAt":"2027-01-15T07:55:00Z","status":{"state":"suppressed"}}]
    """.utf8)
    let fromGrafana = try AlertParser.alertmanagerV2(grafana)
    check(fromGrafana.count == 1 && fromGrafana[0].id == "abc123", "only active Grafana alerts, fingerprint as id")
    check(fromGrafana[0].url?.hasPrefix("https://g.example.com") == true && fromGrafana[0].target == "Homelab", "link and folder")

    do { _ = try AlertParser.prometheus(Data("<html>".utf8)); check(false, "html must fail") }
    catch { check(error as? FetchError == .unexpectedResponse, "html is an unexpected response") }
}

func snapshot(_ sources: [SourceSnapshot], checked: TimeInterval = -10) -> Snapshot {
    Snapshot(checkedAt: now.addingTimeInterval(checked), refreshSeconds: 30, sources: sources)
}
func ok(_ source: Source, _ alerts: [Alert] = []) -> SourceSnapshot {
    SourceSnapshot(source: source, alerts: alerts, lastAttempt: now.addingTimeInterval(-10), lastSuccess: now.addingTimeInterval(-10))
}
func failed(_ source: Source, _ alerts: [Alert] = []) -> SourceSnapshot {
    SourceSnapshot(source: source, alerts: alerts, error: "Timed out after 10s", lastAttempt: now.addingTimeInterval(-10))
}
let critical = Alert(id: "1", name: "HighMemoryUsage", severity: .critical, target: "api-server-01", activeAt: now.addingTimeInterval(-23 * 60))
let warning = Alert(id: "2", name: "DiskSpaceLow", severity: .warning, target: "postgres-02", activeAt: now.addingTimeInterval(-8 * 60))

func checkStatus() {
    check(Status(snapshot: nil, now: now).health == .unavailable, "no file")
    check(Status(snapshot: Snapshot(), now: now).health == .unconfigured, "no sources")
    check(Status(snapshot: snapshot([SourceSnapshot(source: prod)]), now: now).health == .loading, "never checked")
    check(Status(snapshot: snapshot([ok(prod), ok(lab)]), now: now).health == .healthy, "all clear")

    let firing = Status(snapshot: snapshot([ok(prod, [critical, warning]), ok(lab)]), now: now)
    check(firing.health == .firing && firing.firing == 2 && firing.worst == .critical, "firing")
    check(firing.headline == "2 firing" && firing.compact == "2", "firing text")

    // The rule the brand insists on: never "0 firing" while a source is unverified.
    let partial = Status(snapshot: snapshot([ok(prod), failed(lab, [warning])]), now: now)
    check(partial.health == .partial && partial.headline == "1 firing · 1 offline", "partial keeps cached alerts and says so")
    check(partial.detail(now: now) == "Last checked 10s ago · 1 source unreachable", "partial detail")
    check(Status(snapshot: snapshot([failed(prod), failed(lab)]), now: now).health == .offline, "all failed")

    let stale = Status(snapshot: snapshot([ok(prod, [critical])], checked: -600), now: now)
    check(stale.health == .stale && stale.headline == "1 cached · stale" && stale.compact == "?", "stale beats firing")
    check(Status(snapshot: snapshot([ok(prod)], checked: -119), now: now).health == .healthy, "2 minutes grace for fast intervals")
    check(Status(snapshot: snapshot([ok(prod)]), now: now).detail(now: now) == "Last checked 10s ago · 1 source healthy", "healthy detail")
}

func checkFormat() {
    check(Format.duration(20) == "1m" && Format.duration(23 * 60) == "23m", "minutes")
    check(Format.duration(2 * 3600 + 5 * 60) == "2h 5m" && Format.duration(3600) == "1h", "hours")
    check(Format.duration(3 * 86400 + 4 * 3600) == "3d 4h", "days")
    check(Format.ago(now, now: now) == "just now" && Format.ago(now.addingTimeInterval(-12), now: now) == "12s ago", "ago")
    check(Format.ago(now.addingTimeInterval(-720), now: now) == "12m ago", "minutes ago")
}

func checkRender() throws {
    let snap = snapshot([ok(prod, [critical, warning]), failed(lab)])
    let text = Render.alerts(snap, style: .init(color: false), now: now)
    check(text.hasPrefix("2 firing · 1 offline  (2 sources)\n"), "alerts headline")
    check(text.contains("  production  2 firing\n    ● HighMemoryUsage  api-server-01 · 23m\n"), "aligned row")
    check(text.contains("homelab  offline · Timed out after 10s"), "offline source")
    check(!text.contains("\u{1b}["), "no color codes when color is off")
    check(Render.alerts(snap, filter: AlertFilter(minimum: .critical), style: .init(color: false), now: now).contains("DiskSpaceLow") == false, "severity filter")
    check(Render.alerts(snap, source: "nope", style: .init(color: false), now: now).hasPrefix("No source named"), "unknown source")

    check(Render.starship(snapshot([ok(prod)]), now: now) == "", "starship hides when healthy")
    check(Render.plain(snap, now: now) == "2", "plain count")

    let waybar = try JSONSerialization.jsonObject(with: Data(Render.waybar(snap, now: now).utf8)) as? [String: String]
    check(waybar?["class"] == "partial" && waybar?["text"] == "2!", "waybar json")

    let xbar = Render.xbar(snapshot([ok(prod, [Alert(id: "x", name: "A|B", severity: .info, url: "https://x")])]), cli: "/bin/velto", now: now)
    check(xbar.hasPrefix("1 | sfimage=flame\n---\n1 firing"), "xbar title")
    check(xbar.contains("● A¦B") && xbar.contains("href=https://x"), "xbar escapes pipes and links rows")

    let json = try JSONSerialization.jsonObject(with: Data(Render.json(snap, now: now).utf8)) as? [String: Any]
    check(json?["status"] as? String == "partial" && json?["firing"] as? Int == 2, "json summary")
}

func checkStore() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("velto-checks-\(UUID().uuidString)")
    setenv("VELTO_HOME", home.path, 1)
    defer { try? FileManager.default.removeItem(at: home) }
    try check(Store.loadSnapshot() == nil && Store.loadConfig() == nil, "empty home")
    let config = Config(refreshSeconds: 60, sources: [prod, lab])
    try Store.save(config)
    try check(Store.loadConfig() == config, "config round-trips")
    let snap = snapshot([ok(prod, [critical])])
    try Store.save(snap)
    check(Store.loadSnapshot() == snap, "snapshot round-trips")
    let mode = try FileManager.default.attributesOfItem(atPath: Store.configURL.path)[.posixPermissions] as? Int
    check(mode == 0o600, "owner-only config")
    try check(Store.decoder.decode(Config.self, from: Data(#"{"sources":[{"url":"https://x"}]}"#.utf8)).sources[0].kind == .prometheus, "sparse config loads")
}

func checkPulseImport() {
    let toml = """
    interval_secs = 45   # comment
    statusbar_mode = "simple"

    [[sources]]
    name = "source1"
    kind = "mimir"
    url  = "https://mimir.example.com/"
    org_id = "team#1"

    [[sources]]
    name = "secured"
    kind = "prometheus"
    url = "https://prom.example.com"
    bearer_token = "s3cret"
    insecure_skip_tls_verify = true

    [[sources]]
    name = "az"
    kind = "grafana"
    url = "https://g.example.com"
    token_command = "az account get-access-token --query accessToken -o tsv"

    [[sources]]
    name = "tickets"
    kind = "service_now"
    url = "https://x.service-now.com"
    """
    let result = PulseImport(toml: toml)
    check(result.config.refreshSeconds == 30, "interval snaps to the nearest choice")
    check(result.config.sources.map(\.name) == ["source1", "secured", "az"], "supported sources in order")
    check(result.config.sources[0].orgID == "team#1", "# inside a string is not a comment")
    let secured = result.config.sources[1]
    check(secured.auth == .bearer && result.secrets[secured.id] == "s3cret" && secured.skipTLSVerify, "inline token goes to secrets")
    check(result.config.sources[2].auth == .command && result.config.sources[2].tokenCommand.hasPrefix("az account"), "token command")
    check(result.notes.count == 1 && result.notes[0].contains("tickets"), "unsupported kind is reported")
}

func checkContext() throws {
    let prometheus = Data("""
    {"status":"success","data":{"alerts":[
      {"labels":{"alertname":"A","team":"platform","owner":"x","environment":"prod","cluster":"eu1"},
       "annotations":{"runbook_url":"https://runbooks.example.com/a","summary":"s","__dashboardUid__":"abc","__panelId__":"7"},
       "state":"firing","activeAt":"2027-01-15T06:37:00Z"}]}}
    """.utf8)
    let a = try AlertParser.prometheus(prometheus)[0]
    check(a.annotations["runbook_url"] == "https://runbooks.example.com/a" && a.annotations.count == 4, "prometheus keeps annotations")
    check(a.runbookURL?.absoluteString == "https://runbooks.example.com/a", "runbook url")
    check(a.owner == "platform" && a.environment == "prod", "owner and env label precedence")
    check(a.dashboardURL(base: "https://grafana.example.com/")?.absoluteString == "https://grafana.example.com/d/abc?viewPanel=7", "dashboard from uid and panel")
    check(a.dashboardURL(base: "") == nil, "no base, no uid link")
    let linked = Source(kind: .prometheus, url: "https://prom.example.com", linkURL: "https://grafana.example.com/alerting/list")
    check(linked.dashboardURL(for: a)?.absoluteString == "https://grafana.example.com/d/abc?viewPanel=7", "source link host is the base")
    check(Source(kind: .grafana, url: "https://g.example.com/grafana").dashboardURL(for: a)?.absoluteString == "https://g.example.com/grafana/d/abc?viewPanel=7", "grafana source url is the base")

    let grafana = Data(#"[{"labels":{"alertname":"B","squad":"core"},"annotations":{"runbook":"javascript:alert(1)","dashboard_url":"https://d.example.com/x"},"status":{"state":"active"}}]"#.utf8)
    let b = try AlertParser.alertmanagerV2(grafana)[0]
    check(b.annotations.count == 2, "grafana keeps annotations")
    check(b.runbookURL == nil, "runbook rejects non-http")
    check(b.dashboardURL(base: "")?.absoluteString == "https://d.example.com/x", "explicit dashboard link wins")
    check(b.owner == "core" && b.environment == nil, "squad is an owner")

    let old = Data(#"{"checkedAt":"2027-01-15T06:37:00Z","refreshSeconds":30,"sources":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"p","kind":"prometheus","alerts":[{"id":"1","name":"A","severity":"critical","labels":{}}]}]}"#.utf8)
    let snap = try Store.decoder.decode(Snapshot.self, from: old)
    check(snap.alerts.count == 1 && snap.alerts[0].annotations.isEmpty, "v0.1.0 snapshot decodes")

    let text = Render.alerts(snapshot([ok(prod, [a])]), style: .init(color: false), now: now)
    check(text.contains("platform\n      runbook: https://runbooks.example.com/a\n"), "owner and runbook in alerts output")
    let xbar = Render.xbar(snapshot([ok(prod, [a, b])]), cli: "/bin/velto", now: now)
    check(xbar.contains("--Runbook | href=https://runbooks.example.com/a") && xbar.contains("--Dashboard | href=https://d.example.com/x"), "xbar submenu links")
}

func checkChanges() {
    let a = Alert(id: "a", name: "A", severity: .critical, activeAt: now.addingTimeInterval(-7200))
    let b = Alert(id: "b", name: "B", severity: .warning)
    // First-ever check: nothing is new just because Velto is.
    let first = SnapshotMerge.merge(previous: SourceSnapshot(source: prod), result: .success([a, b]), now: now)
    check(first.started.isEmpty && first.ended.isEmpty, "no baseline, no events")
    check(first.source.alerts[0].firstSeen == a.activeAt && !first.source.alerts[0].isNew(now: now), "first check uses activeAt")
    check(first.source.alerts[1].firstSeen == now && first.source.alerts[1].isNew(now: now), "first check without activeAt is now")

    let later = now.addingTimeInterval(60)
    let c = Alert(id: "c", name: "C", severity: .info)
    let second = SnapshotMerge.merge(previous: first.source, result: .success([a, c]), now: later)
    check(second.source.alerts[0].firstSeen == a.activeAt, "firstSeen carried over")
    check(second.started.map(\.id) == ["c"] && second.source.alerts[1].firstSeen == later, "new alert gets now")
    check(second.ended.map(\.id) == ["b"] && second.source.resolved.map(\.id) == ["b"], "disappeared alert is resolved")
    check(!second.source.alerts[1].isNew(now: later.addingTimeInterval(Alert.newWindow)), "new window ends")

    let failed = SnapshotMerge.merge(previous: second.source, result: Result<[Alert], Error>.failure(FetchError.http(500)), now: later.addingTimeInterval(30))
    check(failed.source.alerts == second.source.alerts && failed.source.resolved == second.source.resolved, "failure keeps lists")
    check(failed.source.error == "Server answered 500" && failed.source.lastSuccess == later, "failure sets error only")

    let back = SnapshotMerge.merge(previous: second.source, result: .success([a, b, c]), now: later.addingTimeInterval(60))
    check(back.source.resolved.isEmpty, "firing again leaves the resolved list")

    var many = SourceSnapshot(source: prod, lastSuccess: now)
    many.resolved = (0..<30).map { ResolvedAlert(alert: Alert(id: "r\($0)", name: "R", severity: .info), resolvedAt: now.addingTimeInterval(Double(-$0 * 150))) }
    let pruned = SnapshotMerge.merge(previous: many, result: .success([]), now: now)
    check(pruned.source.resolved.count == 20, "resolved list caps at 20")
    let aged = SnapshotMerge.merge(previous: many, result: .success([]), now: now.addingTimeInterval(1800))
    check(aged.source.resolved.allSatisfy { now.addingTimeInterval(1800).timeIntervalSince($0.resolvedAt) < 3600 } && aged.source.resolved.count == 12, "resolved prunes at 1h")

    let text = Render.alerts(snapshot([second.source].map { var s = $0; s.lastAttempt = now; return s }), style: .init(color: false), now: later)
    check(text.contains("  new\n") && text.contains("resolved in the last hour\n    ✓ B  just now"), "new marker and resolved list")
}

func checkFilters() {
    let d2 = Alert(id: "d2", name: "DiskSpaceLow", severity: .warning, target: "postgres-02", summary: "Disk at 91%", labels: ["env": "prod"])
    let mem = Alert(id: "m", name: "HighMemoryUsage", severity: .critical, target: "api-01", labels: ["environment": "staging"])
    let d3 = Alert(id: "d3", name: "DiskSpaceLow", severity: .critical, target: "postgres-03", labels: ["env": "prod"])
    let d4 = Alert(id: "d4", name: "DiskSpaceLow", severity: .warning, target: "postgres-04", labels: ["env": "Prod"])
    let all = [d2, mem, d3, d4]
    check(all.filter(AlertFilter(environment: "prod").matches).map(\.id) == ["d2", "d3", "d4"], "environment filter, case-insensitive")
    check(all.filter(AlertFilter(text: "91%").matches).map(\.id) == ["d2"], "text matches summary")
    check(all.filter(AlertFilter(text: "api-01").matches).map(\.id) == ["m"], "text matches target")
    check(all.filter(AlertFilter(text: "memory").matches).map(\.id) == ["m"], "text matches name")
    check(all.filter(AlertFilter(minimum: .critical).matches).map(\.id) == ["m", "d3"], "severity filter")
    check(AlertFilter.environments(in: all) == ["prod", "Prod", "staging"] || AlertFilter.environments(in: all).count == 3, "environments listed")

    let groups = Grouping.group(all, scope: "s")
    check(groups.map(\.name) == ["DiskSpaceLow", "HighMemoryUsage"], "group order follows first appearance")
    check(groups[0].alerts.map(\.id) == ["d2", "d3", "d4"] && groups[0].worst == .critical, "group keeps distinct ids, worst severity")
    check(groups[0].id == "s/DiskSpaceLow", "group id is scope and name")

    let text = Render.alerts(snapshot([ok(prod, all)]), grouped: true, style: .init(color: false), now: now)
    check(text.contains("● DiskSpaceLow ×3      postgres-02, postgres-03, postgres-04\n"), "grouped row")
    check(text.contains("● HighMemoryUsage      api-01\n"), "single-alert group renders as a plain row")
    let filtered = Render.alerts(snapshot([ok(prod, all)]), filter: AlertFilter(environment: "staging"), style: .init(color: false), now: now)
    check(filtered.contains("1 firing") && !filtered.contains("DiskSpaceLow"), "env filter in output")
    check(try! Store.decoder.decode(AlertFilter.self, from: Data("{}".utf8)) == AlertFilter(), "empty filter decodes")
}

func checkSnooze() throws {
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    var muted = warning; muted.snoozedUntil = now.addingTimeInterval(3600)
    let only = Status(snapshot: snapshot([ok(prod, [muted])]), now: now)
    check(only.health == .healthy && only.firing == 0 && only.snoozed == 1, "snoozed alert not counted")
    check(only.headline == "All clear" && only.compact == "", "all clear with only snoozed alerts")
    check(only.detail(now: now) == "Last checked 10s ago · 1 source healthy · 1 snoozed", "snoozed in detail")
    let mixed = Status(snapshot: snapshot([ok(prod, [critical, muted])]), now: now)
    check(mixed.firing == 1 && mixed.worst == .critical, "firing excludes snoozed")
    var expiredAlert = warning; expiredAlert.snoozedUntil = now.addingTimeInterval(-1)
    check(Status(snapshot: snapshot([ok(prod, [expiredAlert])]), now: now).firing == 1, "past snooze counts again")

    let d2 = Alert(id: "d2", name: "DiskSpaceLow", severity: .warning)
    let d3 = Alert(id: "d3", name: "DiskSpaceLow", severity: .warning)
    let other = Alert(id: "x", name: "Other", severity: .warning)
    var source = ok(prod, [d2, d3, other])
    Snooze.apply([Mute(sourceID: prod.id, alertName: "DiskSpaceLow", until: now.addingTimeInterval(600))], to: &source, now: now)
    check(source.alerts.map { $0.snoozedUntil != nil } == [true, true, false], "name-scope mute matches all ids")
    Snooze.apply([Mute(sourceID: prod.id, alertName: "DiskSpaceLow", alertID: "d3", until: now.addingTimeInterval(600))], to: &source, now: now)
    check(source.alerts.map { $0.snoozedUntil != nil } == [false, true, false], "alert-scope mute matches one id, others cleared")
    Snooze.apply([Mute(sourceID: prod.id, alertName: "DiskSpaceLow", until: now.addingTimeInterval(-5))], to: &source, now: now)
    check(source.alerts.allSatisfy { $0.snoozedUntil == nil }, "expired mute ignored")
    Snooze.apply([Mute(sourceID: lab.id, alertName: "DiskSpaceLow", until: now.addingTimeInterval(600))], to: &source, now: now)
    check(source.alerts.allSatisfy { $0.snoozedUntil == nil }, "mute is per source")

    func at(_ h: Int, _ m: Int) -> Date { utc.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: h, minute: m))! }
    let quiet = QuietHours(start: 22 * 60, end: 7 * 60, allowCritical: true)
    check(quiet.contains(at(23, 30), calendar: utc) && quiet.contains(at(6, 59), calendar: utc), "quiet hours wrap midnight")
    check(!quiet.contains(at(7, 0), calendar: utc) && !quiet.contains(at(21, 59), calendar: utc), "quiet hours edges")
    check(quiet.allows(critical, at: at(23, 0), calendar: utc) && !quiet.allows(warning, at: at(23, 0), calendar: utc), "critical gets through")
    check(QuietHours(start: 9 * 60, end: 17 * 60).contains(at(12, 0), calendar: utc), "daytime window")

    let late = Snooze.presets(now: at(23, 30), calendar: utc)
    check(late[2].until == utc.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 9))!, "until tomorrow at 23:30")
    let early = Snooze.presets(now: at(8, 0), calendar: utc)
    check(early[2].until == utc.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 9))!, "until tomorrow at 08:00 is the next day")
    check(early[0].until == at(9, 0) && early[1].until == at(12, 0), "1h and 4h presets")

    let text = Render.alerts(snapshot([ok(prod, [critical, muted])]), style: .init(color: false), now: now)
    check(text.contains("1 firing · 1 snoozed") && text.contains("◌ DiskSpaceLow") && text.contains("snoozed until"), "snoozed in alerts output")
    check(Render.starship(snapshot([ok(prod, [muted])]), now: now) == "" && Render.plain(snapshot([ok(prod, [muted])]), now: now) == "0", "status lines follow Status")
    let config = try Store.decoder.decode(Config.self, from: Data(#"{"sources":[]}"#.utf8))
    check(config.mutes.isEmpty && config.quietHours == nil && !config.notifyResolved, "v0.1.0 config loads")
}

func checkPaused() throws {
    func paused(_ source: Source, _ alerts: [Alert] = [], reason: String = "VPN required") -> SourceSnapshot {
        var s = failed(source, alerts); s.pausedReason = reason; return s
    }
    let mixed = Status(snapshot: snapshot([ok(prod), paused(lab, [critical])]), now: now)
    check(mixed.health == .healthy && mixed.offline == 0 && mixed.paused == 1 && mixed.firing == 0, "paused is not offline, cached alerts not counted")
    check(mixed.detail(now: now) == "Last checked 10s ago · 1 source healthy · 1 paused", "mixed detail")
    let all = Status(snapshot: snapshot([paused(prod), paused(lab)]), now: now)
    check(all.health == .paused && all.headline == "Paused" && all.compact == "‖", "all paused")
    check(all.detail(now: now) == "Paused · VPN required", "all paused detail")
    check(Status(snapshot: snapshot([paused(prod), paused(lab)], checked: -600), now: now).health == .stale, "stale beats paused")
    check(Status(snapshot: snapshot([ok(prod), paused(lab)], checked: -600), now: now).health == .stale, "stale with one paused source")
    check(Status(snapshot: snapshot([SourceSnapshot(source: prod), paused(lab)]), now: now).health == .loading, "loading ignores paused sources")
    check(Status(snapshot: snapshot([failed(prod), paused(lab)]), now: now).health == .offline, "offline counts active sources only")

    for condition in [NetworkCondition.vpn, .resolves(host: "prom.corp")] {
        var source = prod; source.requires = condition
        let data = try Store.encoder.encode(source)
        check(try Store.decoder.decode(Source.self, from: data).requires == condition, "network condition round-trips")
    }
    check(try Store.decoder.decode(Source.self, from: Data(#"{"url":"https://x"}"#.utf8)).requires == nil, "config without requires loads")
    check(NetworkCondition.resolves(host: "https://prom.corp:9090/x").pausedReason == "needs prom.corp", "host from a pasted URL")
    check(NetworkCondition.hostName("prom.corp:9090") == "prom.corp", "port dropped")

    let text = Render.alerts(snapshot([ok(prod), paused(lab, [critical])]), style: .init(color: false), now: now)
    check(text.contains("homelab  paused · VPN required"), "paused line in alerts")
    let waybar = try JSONSerialization.jsonObject(with: Data(Render.waybar(snapshot([paused(prod)]), now: now).utf8)) as? [String: String]
    check(waybar?["class"] == "paused", "waybar paused class")
    check(Render.xbar(snapshot([paused(prod)]), cli: "/bin/velto", now: now).contains("production: paused · VPN required | color=gray"), "xbar paused row")
}

func checkHistory() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("velto-history-\(UUID().uuidString)")
    setenv("VELTO_HOME", home.path, 1)
    defer { try? FileManager.default.removeItem(at: home) }
    check(History.load().isEmpty, "no history file")
    func event(_ minutes: Double, _ kind: HistoryEvent.Kind = .fired, id: String = "a") -> HistoryEvent {
        HistoryEvent(at: now.addingTimeInterval(minutes * 60), sourceID: prod.id, source: "production", alertID: id, name: "A", kind: kind)
    }
    try History.append([event(-10), event(-5, .resolved)])
    try History.append([event(-1)])
    let loaded = History.load()
    check(loaded == [event(-10), event(-5, .resolved), event(-1)], "append and load round-trip")
    check(History.load(since: now.addingTimeInterval(-6 * 60)).count == 2, "load since")
    let mode = try FileManager.default.attributesOfItem(atPath: Store.historyURL.path)[.posixPermissions] as? Int
    check(mode == 0o600, "owner-only history")

    let handle = try FileHandle(forWritingTo: Store.historyURL)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("{not json\n".utf8)); try handle.close()
    check(History.load().count == 3, "corrupt line skipped")

    try History.append([HistoryEvent(at: now.addingTimeInterval(-8 * 86400), sourceID: prod.id, source: "p", alertID: "old", name: "Old", kind: .fired)])
    try History.prune(now: now)
    check(History.load().map(\.alertID) == ["a", "a", "a"], "prune by age, corrupt line dropped")
    try History.append((0..<(History.maxLines + 10)).map { event(-Double($0) / 100, id: "n\($0)") })
    try History.prune(now: now)
    check(History.load().count == History.maxLines, "prune by count")

    let flaps = [event(-50), event(-30), event(-10), event(-70), event(-20, id: "b")]
    check(History.flapCount(alertID: "a", events: flaps, now: now) == 3, "flap count at exactly 3")
    check(History.flapCount(alertID: "a", events: Array(flaps.dropFirst()), now: now) == 2, "below threshold")

    var flapping = critical; flapping.flapCount = 4
    check(Render.alerts(snapshot([ok(prod, [flapping])]), style: .init(color: false), now: now).contains("⟳ 4× in 1h"), "flap marker in alerts")
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let text = Render.history([event(-10), event(-5, .resolved)], style: .init(color: false), now: now, calendar: utc)
    check(text.hasPrefix("Today\n") && text.contains("✓ A  resolved · production") && text.contains("● A  fired"), "history text")
    check(text.range(of: "resolved")!.lowerBound < text.range(of: "fired")!.lowerBound, "history newest first")
}

func checkAlertmanager() throws {
    let am = Source(kind: .alertmanager, url: "https://am.example.com/", orgID: "team-a")
    check(am.alertsURL()?.absoluteString == "https://am.example.com/api/v2/alerts?active=true&silenced=false&inhibited=false", "alertmanager url")
    let mimirAM = Source(kind: .alertmanager, url: "https://mimir.example.com/alertmanager")
    check(mimirAM.alertsURL()?.absoluteString == "https://mimir.example.com/alertmanager/api/v2/alerts?active=true&silenced=false&inhibited=false", "mimir alertmanager url")
    check(am.request(credentials: Credentials())?.value(forHTTPHeaderField: "X-Scope-OrgID") == "team-a", "tenant header for alertmanager")
    check(Source(kind: .grafana, url: "https://g.example.com", orgID: "x").request(credentials: Credentials())?.value(forHTTPHeaderField: "X-Scope-OrgID") == nil, "no tenant for grafana")

    var labeled = critical
    labeled.labels = ["alertname": "HighMemoryUsage", "instance": "api-server-01"]
    var bearerAM = am; bearerAM.auth = .bearer
    let until = now.addingTimeInterval(3600)
    let request = try SilenceRequest.make(source: bearerAM, alert: labeled, until: until, now: now, user: "mike", credentials: Credentials(token: "t")).unwrap("silence request")
    check(request.httpMethod == "POST" && request.url?.absoluteString == "https://am.example.com/api/v2/silences", "silence POST url")
    check(request.value(forHTTPHeaderField: "Authorization") == "Bearer t" && request.value(forHTTPHeaderField: "X-Scope-OrgID") == "team-a", "silence auth and tenant")
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    let matchers = body?["matchers"] as? [[String: Any]]
    check(matchers?.count == 2 && matchers?[0]["name"] as? String == "alertname" && matchers?[0]["isEqual"] as? Bool == true
          && matchers?[0]["isRegex"] as? Bool == false, "matchers are the exact label set")
    check(body?["startsAt"] as? String == "2027-01-15T08:00:00Z" && body?["endsAt"] as? String == "2027-01-15T09:00:00Z", "ISO 8601 dates")
    check(body?["createdBy"] as? String == "mike" && body?["comment"] as? String == SilenceRequest.comment, "createdBy and comment")

    let grafana = Source(kind: .grafana, url: "https://g.example.com/")
    check(SilenceRequest.make(source: grafana, alert: labeled, until: until, now: now, user: "m")?.url?.absoluteString
          == "https://g.example.com/api/alertmanager/grafana/api/v2/silences", "grafana silences path")
    check(SilenceRequest.make(source: prod, alert: labeled, until: until, now: now, user: "m") == nil, "no silences for prometheus")
    let expire = SilenceRequest.expire(source: am, id: "abc-123")
    check(expire?.httpMethod == "DELETE" && expire?.url?.absoluteString == "https://am.example.com/api/v2/silence/abc-123", "expire path")
    check(try SilenceRequest.silenceID(from: Data(#"{"silenceID":"s1"}"#.utf8)) == "s1", "silence response")

    let v2 = Data(#"[{"labels":{"alertname":"X","severity":"critical"},"annotations":{},"startsAt":"2027-01-15T07:55:00Z","fingerprint":"f1","status":{"state":"active","silencedBy":[],"inhibitedBy":[]}}]"#.utf8)
    check(try AlertParser.alertmanagerV2(v2).first?.id == "f1", "alertmanager v2 parses")
    let vmalert = Data(#"{"status":"success","data":{"alerts":[{"state":"firing","name":"VMAlert","value":"1","labels":{"alertname":"VMAlert"},"annotations":{},"activeAt":"2027-01-15T07:00:00Z","id":"123","rule_id":"9","group_id":"8","expression":"up == 0","source":"http://vmalert"}]}}"#.utf8)
    check(try AlertParser.prometheus(vmalert).first?.name == "VMAlert", "vmalert parses as prometheus")
    let loki = Data(#"{"status":"success","data":{"alerts":[{"labels":{"alertname":"LogErrors","severity":"warning"},"annotations":{"summary":"errors"},"state":"firing","activeAt":"2027-01-15T07:00:00.123456789Z","value":"5e+00"}]}}"#.utf8)
    check(try AlertParser.prometheus(loki).first?.summary == "errors", "loki ruler parses as prometheus")
}

extension Optional {
    func unwrap(_ what: String) throws -> Wrapped {
        guard let self else { precondition(false, "\(what) is nil"); fatalError() }
        return self
    }
}

func checkQueries() throws {
    let vector = Data(#"{"status":"success","data":{"resultType":"vector","result":[{"metric":{"instance":"a"},"value":[1700000000.1,"11.5"]},{"metric":{"instance":"b"},"value":[1700000000.1,"42"]},{"metric":{},"value":[1700000000.1,"NaN"]}]}}"#.utf8)
    let values = try QueryParser.values(vector)
    check(values.count == 3 && values[0] == 11.5, "vector parses")
    let scalar = Data(#"{"status":"success","data":{"resultType":"scalar","result":[1700000000.1,"7"]}}"#.utf8)
    check(try QueryParser.values(scalar) == [7], "scalar parses")
    let empty = Data(#"{"status":"success","data":{"resultType":"vector","result":[]}}"#.utf8)
    check(try QueryParser.values(empty).isEmpty, "empty vector")
    let error = Data(#"{"status":"error","errorType":"bad_data","error":"parse error at char 12"}"#.utf8)
    check(QueryParser.errorMessage(error) == "bad_data: parse error at char 12", "error body")
    do { _ = try QueryParser.values(error); check(false, "error body must not parse") } catch {}

    let disk = PinnedQuery(name: "Disk free", query: "x", unit: .percent, direction: .below, warn: 15, crit: 5)
    check(disk.worst(of: values) == 11.5, "below takes the lowest, NaN ignored")
    let down = PinnedQuery(name: "Targets down", query: "x", direction: .above, crit: 0)
    check(down.worst(of: values) == 42, "above takes the highest")
    check(disk.check(value: disk.worst(of: values)).state == .warn && disk.check(value: 11.5).display == "11.5 %", "below warn")
    check(disk.evaluate(15).0 == .ok && disk.evaluate(14.9).0 == .warn && disk.evaluate(5).0 == .warn && disk.evaluate(4.9).0 == .crit, "below boundaries are strict")
    check(down.evaluate(0).0 == .ok && down.evaluate(1).0 == .crit, "above boundaries are strict")
    check(disk.evaluate(nil) == (.unknown, "no data") && disk.check(value: disk.worst(of: [])).state == .unknown, "empty result is no data, never green")
    check(PinnedQuery(query: "x").evaluate(3).0 == .ok, "no thresholds is ok")
    check(down.check(error: "bad_data: x").state == .unknown && down.check(error: "e").message == "e", "query error is unknown with message")

    check(PinnedQuery.Unit.percent.format(11) == "11 %", "percent")
    check(PinnedQuery.Unit.days.format(23.7) == "23 days" && PinnedQuery.Unit.days.format(1.2) == "1 day", "days")
    check(PinnedQuery.Unit.bytes.format(1_234_000_000) == "1.2 GB" && PinnedQuery.Unit.bytes.format(512) == "512 B", "bytes")
    check(PinnedQuery.Unit.seconds.format(0.34) == "340 ms" && PinnedQuery.Unit.seconds.format(12.5) == "12.5 s" && PinnedQuery.Unit.seconds.format(7200) == "2h", "seconds")
    check(PinnedQuery.Unit.none.format(0.126) == "0.13" && PinnedQuery.Unit.none.format(1234.4) == "1234" && PinnedQuery.Unit.none.format(2) == "2", "numbers")

    check(prod.queryURL("count(up == 0) or vector(0)")?.absoluteString == "https://prom.example.com/api/v1/query?query=count%28up%20%3D%3D%200%29%20or%20vector%280%29", "query url escaped")
    check(lab.queryURL("a+b")?.absoluteString == "https://mimir.example.com/prometheus/api/v1/query?query=a%2Bb", "mimir query url, plus escaped")
    check(Source(kind: .grafana, url: "https://g.example.com").queryURL("up") == nil, "no queries on grafana")

    let breach = Check(id: "q", name: "Disk free", value: 4, display: "4 %", state: .crit)
    let unknown = Check(id: "u", name: "Queue", display: "no data", state: .unknown)
    let withChecks = Status(snapshot: snapshot([ok(prod).with(checks: [breach, unknown, Check(id: "o", name: "OK", display: "1", state: .ok)])]), now: now)
    check(withChecks.firing == 1 && withChecks.worst == .critical && withChecks.health == .firing, "breached check counts, unknown does not")
    check(withChecks.detail(now: now) == "Last checked 10s ago · 1 source healthy · 1 check no data", "no data in detail")
    check(Status(snapshot: snapshot([ok(prod).with(checks: [unknown])]), now: now).health == .healthy, "unknown alone is not firing")

    let previous = ok(prod).with(checks: [breach])
    let failedCheck = SnapshotMerge.merge(previous: previous, result: Result<SourceResult, Error>.failure(FetchError.http(502)), now: now)
    check(failedCheck.source.checks == [breach], "failed source keeps cached checks")
    let fresh = SnapshotMerge.merge(previous: previous, result: .success(SourceResult(alerts: [], checks: [unknown])), now: now)
    check(fresh.source.checks == [unknown], "checks replaced on success")

    let old = Data(#"{"refreshSeconds":30,"sources":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"p","kind":"alertmanager","alerts":[],"resolved":[]}]}"#.utf8)
    check(try Store.decoder.decode(Snapshot.self, from: old).sources[0].checks.isEmpty, "v0.3 snapshot without checks decodes")
    check(try Store.decoder.decode(Source.self, from: Data(#"{"url":"https://x","queries":[{"query":"up"}]}"#.utf8)).queries[0].direction == .above, "sparse query loads")

    let text = Render.alerts(snapshot([ok(prod).with(checks: [breach])]), style: .init(color: false), now: now)
    check(text.contains("production  1 firing") && text.contains("● Disk free  4 %"), "breached check in alerts")
    let checksText = Render.checks(snapshot([ok(prod).with(checks: [breach, unknown])]), style: .init(color: false), now: now)
    check(checksText.contains("× Disk free  4 %") && checksText.contains("? Queue      no data"), "checks output")
    check(Render.xbar(snapshot([ok(prod).with(checks: [breach])]), cli: "/bin/velto", now: now).contains("Disk free  4 % | color=#E66A56"), "xbar checks block")
    let waybar = try JSONSerialization.jsonObject(with: Data(Render.waybar(snapshot([ok(prod).with(checks: [breach])]), now: now).utf8)) as? [String: String]
    check(waybar?["tooltip"]?.contains("Checks") == true, "waybar tooltip has checks")
}

extension SourceSnapshot {
    func with(checks: [Check]) -> SourceSnapshot { var copy = self; copy.checks = checks; return copy }
}

/// A listening TCP socket on 127.0.0.1 with a free port, so the TCP probe has something real to reach.
func listener() -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
    listen(fd, 4)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
    return (fd, UInt16(bigEndian: address.sin_port))
}

func checkProbes() async throws {
    var probes = Source(name: "lab", kind: .probes)
    check(!probes.isComplete && probes.alertsURL() == nil, "probes without targets are incomplete")
    probes.probes = [Probe(type: .tcp, target: "  ")]
    check(!probes.isComplete, "blank target is incomplete")
    probes.probes.append(Probe(name: "Site", type: .tls, target: "example.com", expectStatus: 200...204, warnDays: 30, critDays: 10))
    check(probes.isComplete && probes.displayName == "lab", "one target is enough")
    let decoded = try Store.decoder.decode(Source.self, from: Store.encoder.encode(probes))
    check(decoded.probes == probes.probes, "probe config round-trips")
    check(try Store.decoder.decode(Probe.self, from: Data(#"{"target":"x"}"#.utf8)).warnDays == 14, "sparse probe loads")

    let site = probes.probes[1]
    check(site.tlsState(daysLeft: 30) == .ok && site.tlsState(daysLeft: 29) == .warn && site.tlsState(daysLeft: 10) == .warn && site.tlsState(daysLeft: 9) == .crit, "TLS day thresholds")
    check(Probe().tlsState(daysLeft: 14) == .ok && Probe().tlsState(daysLeft: 6) == .crit, "default TLS thresholds")
    check(site.statusIsUp(204) && !site.statusIsUp(301), "expected status range")
    check(Probe().statusIsUp(302) && !Probe().statusIsUp(404) && !Probe().statusIsUp(500), "default status range")
    check(Probe.hostAndPort("db.example.com:5432", defaultPort: nil)! == ("db.example.com", 5432), "host:port")
    check(Probe.hostAndPort("example.com", defaultPort: 443)! == ("example.com", 443) && Probe.hostAndPort("example.com", defaultPort: nil) == nil, "default port")
    check(Probe.hostAndPort("https://example.com/x", defaultPort: nil)! == ("example.com", 443) && Probe.hostAndPort("[::1]:22", defaultPort: nil)! == ("::1", 22), "url and IPv6")

    func targets(_ health: [String]) -> Data {
        Data(("{\"status\":\"success\",\"data\":{\"activeTargets\":[" + health.map { "{\"health\":\"\($0)\",\"labels\":{}}" }.joined(separator: ",") + "],\"droppedTargets\":[]}}").utf8)
    }
    let allUp = try TargetHealth.check(from: targets(Array(repeating: "up", count: 5) + ["unknown"]))
    check(allUp.state == .ok && allUp.display == "6/6", "all targets up")
    let someDown = try TargetHealth.check(from: targets(Array(repeating: "up", count: 214) + ["down", "down"]))
    check(someDown.state == .warn && someDown.display == "214/216" && someDown.message == "2 down", "some targets down")
    check(try TargetHealth.check(from: targets(Array(repeating: "up", count: 8) + ["down", "down"])).state == .crit, "more than 10% down")
    check(try TargetHealth.check(from: targets(Array(repeating: "up", count: 9) + ["down"])).state == .warn, "exactly 10% is warn")
    check(TargetHealth.check(error: "x").state == .unknown, "targets failure is unknown")
    var mimirTargets = lab; mimirTargets.watchTargets = true
    check(await Fetcher.targetCheck(for: mimirTargets, credentials: Credentials()) == nil, "target toggle ignored for Mimir")
    check(await Fetcher.targetCheck(for: prod, credentials: Credentials()) == nil, "no target check unless watched")

    let open = listener()
    defer { close(open.fd) }
    let openCheck = await ProbeRunner.run(Probe(type: .tcp, target: "127.0.0.1:\(open.port)"), skipTLSVerify: false)
    check(openCheck.state == .ok && openCheck.display.hasPrefix("open · "), "TCP open")
    let closed = listener()
    close(closed.fd)
    let closedCheck = await ProbeRunner.run(Probe(type: .tcp, target: "127.0.0.1:\(closed.port)"), skipTLSVerify: false)
    check(closedCheck.state == .crit && closedCheck.display == "closed", "TCP closed")
    check(await ProbeRunner.run(Probe(type: .tcp, target: "nope"), skipTLSVerify: false).state == .unknown, "TCP target without port")
    check(await ProbeRunner.run(Probe(type: .http, target: "example.com"), skipTLSVerify: false).state == .unknown, "HTTP needs a full URL")
    check(await ProbeRunner.run(Probe(type: .dns, target: "localhost"), skipTLSVerify: false).state == .ok, "DNS resolves localhost")
    let result = try await Fetcher.fetch(for: Source(kind: .probes, probes: [Probe(type: .tcp, target: "127.0.0.1:\(closed.port)")]), credentials: Credentials())
    check(result.alerts.isEmpty && result.checks.count == 1 && result.checks[0].state == .crit, "probes source fetch never throws")
}

checkSeverity()
checkURLs()
try checkParsing()
checkStatus()
checkFormat()
try checkRender()
try checkStore()
checkPulseImport()
try checkContext()
checkChanges()
checkFilters()
try checkSnooze()
try checkPaused()
try checkHistory()
try checkAlertmanager()
try checkQueries()
try await checkProbes()
print("All Velto checks passed.")
if ProcessInfo.processInfo.environment["VELTO_NET"] != nil {
    for p in [Probe(type: .tls, target: "github.com"), Probe(type: .tls, target: "expired.badssl.com"), Probe(type: .http, target: "https://example.com"), Probe(type: .dns, target: "github.com")] {
        let c = await ProbeRunner.run(p, skipTLSVerify: false)
        FileHandle.standardError.write(Data("\(p.type) \(p.target): \(c.state) \(c.display) \(c.message ?? "")\n".utf8))
    }
}
