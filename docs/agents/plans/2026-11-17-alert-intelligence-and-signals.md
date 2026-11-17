---
date: 2026-11-17T21:25:19+00:00
git_commit: ""
branch: main
topic: "Alert intelligence, network-aware sources, Alertmanager, and pinned checks (v0.2 to v0.4)"
tags: [plan, velto-core, monitor, menu, cli, snapshot, alertmanager, checks]
status: ready
---

# PLAN: Alert intelligence and signals (v0.2 to v0.4)

Velto v0.1.0 counts firing alerts from Prometheus, Mimir and Grafana Alerting. User research (Reddit, Nov 2026: r/sre, r/devops, r/grafana, r/PrometheusMonitoring, r/selfhosted) points at noise, missing context and "green but broken" as the real pain, not missing integrations. This plan makes existing alerts more useful first (v0.2), makes monitoring smarter (v0.3), then adds a second signal type next to alerts (v0.4). The long tail of integrations (incident, uptime, CI, Kubernetes, homelab, Raycast, widget) is captured as a roadmap at the end for a separate plan once demand is validated.

Product promise that every phase must respect: **Know what changed. Know what matters. Know where to look.** No dashboards, no charts, no log explorer.

## Acceptance Criteria

- Every existing source type, CLI command and status-line format keeps working. A snapshot written by the new app still decodes with the same build's CLI, and a v0.1.0 snapshot still decodes after upgrade.
- Alert rows show runbook, dashboard and owner context when the alert carries it, with one click to each link.
- Alerts that started firing recently are marked "New"; alerts that stopped firing in the last hour are listed as resolved.
- Alerts can be filtered by severity and environment, and same-name alerts can be grouped for display without ever merging distinct label sets.
- A single alert or an alert name can be snoozed locally for 1h, 4h or until 09:00 tomorrow. Snoozed alerts are not counted in the badge, stay visible dimmed, and the status says how many are snoozed.
- Quiet hours suppress notifications (optionally letting critical alerts through) without touching counts.
- A source can require a VPN or a resolvable host. When the condition is not met it shows `Paused · VPN required`, is not polled, is not counted as offline, and its cached data is never shown as fresh.
- Velto keeps 7 days of local fire/resolve history; alerts that fired 3 or more times in 60 minutes show a flapping marker. `velto history` prints it.
- Alertmanager (standalone and Mimir Alertmanager) is a source type. Loki ruler, vmalert and Thanos Ruler are documented and covered by checks with existing types.
- Alerts from Alertmanager and Grafana sources can be silenced upstream from the menu (1h, 4h, until 09:00 tomorrow), with an Undo.
- Prometheus and Mimir sources can carry pinned PromQL queries with warn/crit thresholds. A breached check counts toward "firing"; an empty result is "no data", never green.
- Prometheus sources can watch scrape-target health. A new "Probes" source runs HTTP, TCP, TLS-expiry and DNS checks without any Prometheus stack.
- `swift run VeltoChecks` covers every parser, state rule and render change. README and RELEASE_NOTES are updated in the phase that ships the behavior.

## Technical Key Decisions and Tradeoffs

1. **Keep `[Alert]` as the core model through v0.3; add optional fields only.**
   - Why: research and architecture both say alert intelligence needs no new concept.
   - Impact: `Alert` and `SourceSnapshot` get hand-written `init(from:)` with `decodeIfPresent`, matching `Source`'s existing pattern (`Model.swift:52`), so v0.1.0 snapshots and configs still load.

2. **Derived state (new, snoozed, flapping) is computed by the app and written into the snapshot.**
   - Why: the CLI must never touch the network or Keychain and must agree with the menu. Writing `firstSeen`, `snoozedUntil` and `flapCount` into the snapshot keeps `Status` a pure function both sides share.
   - Impact: `Monitor.apply` carries these fields across checks; `Status` reads them.

3. **"New" means first seen within the last 10 minutes (`Alert.newWindow = 600`).**
   - Why: deterministic, identical in menu, CLI and status lines, no per-viewer read state.
   - Impact: no "mark as read" UI. Can be revisited later.

4. **Grouping is presentation-only.** Same `alertname` within one source collapses into an expandable group row; each child keeps its own label-hash `id` (`Fetch.swift:126`).
   - Why: research shows similar-named alerts can be different incidents; silently merging misleads.

5. **Local snooze lives in `config.json` as `mutes`, applied by the Monitor into `Alert.snoozedUntil`.**
   - Why: survives restarts, readable by the CLI through the snapshot, no Keychain.
   - Impact: `Status.firing` excludes snoozed alerts; `Status.snoozed` counts them so the headline stays honest (`All clear · 1 snoozed`).

6. **Upstream silences stay app-only, and only for Alertmanager and Grafana sources.**
   - Why: CLI contract (no network). Prometheus/Mimir ruler endpoints do not know which Alertmanager routes their alerts, so the action is hidden there rather than guessed.
   - Impact: silence matchers are the alert's full label set (`isEqual: true`, `isRegex: false`), `createdBy` is `NSUserName()`, comment `Silenced from Velto`.

7. **Network conditions: `.vpn` (any `utun`/`ppp`/`ipsec` interface with an address) or `.resolves(host)` (getaddrinfo succeeds).**
   - Why: Wi-Fi SSID needs Location permission on recent macOS; DNS resolution of an internal host is the most reliable "am I on the corporate network" test with split DNS.
   - Impact: new `SourceSnapshot.pausedReason`, new `Health.paused`, `NWPathMonitor` triggers re-evaluation.

8. **History is a local JSON-lines file next to the snapshot** (`history.jsonl`), pruned to 7 days and 5,000 lines.
   - Why: append-only, cheap, readable by the CLI, no database.

9. **Alertmanager reuses the Grafana v2 parser.** Grafana's built-in Alertmanager answers in the Alertmanager v2 shape; `AlertParser.grafana` is renamed `alertmanagerV2` and used for both. The `X-Scope-OrgID` header is sent for `.mimir` and `.alertmanager` when a tenant is set.

10. **Checks are a second, optional list on `SourceSnapshot`, not synthetic alerts.** `Check{id, name, value, display, state(ok|warn|crit|unknown), message}`.
    - Why: "seeing infra" means seeing values when healthy too. Synthetic alerts would hide them.
    - Impact: `Status.firing` = unsnoozed alerts + checks in warn/crit; `worst` includes check states. `unknown` is shown but not counted.

11. **No `Integration` protocol yet.** `Fetcher` keeps a `switch source.kind` that now returns `SourceResult(alerts, checks)`.
    - Why: 5 kinds after this plan; a protocol earns its place with the roadmap integrations, not before.
    - Impact: the roadmap plan starts with that refactor.

12. **Query failures are per-check, not per-source.** A broken PromQL query marks only that check `unknown` with its error; the alerts fetch decides whether the source is offline.

13. **Releases:** phases 1-4 ship as 0.2.0, phases 5-7 as 0.3.0, phases 8-9 as 0.4.0. Everything stays SwiftPM and ad-hoc signed; nothing here needs an Xcode project.

## Current State

```
config.json ──► Monitor.refresh()            Sources/VeltoApp/Monitor.swift:481
                  │ all complete sources in parallel, every refreshSeconds
                  ▼
   Secrets.credentials(for:)                 Sources/VeltoApp/Secrets.swift:38
   Fetcher.alerts(for:credentials:)          Sources/VeltoCore/Fetch.swift:151
     └ alertsURL() per kind                  Fetch.swift:35  (prometheus | mimir | grafana)
     └ AlertParser.prometheus | .grafana     Fetch.swift:93 / :101
         keeps labels + summary only; other annotations dropped (Fetch.swift:118)
                  ▼
   Monitor.apply()                           Monitor.swift:508
     └ diff ids vs previous good check → onNewAlerts → Notifier.post (Notifier.swift:29)
     └ on failure: keep cached alerts, set error
                  ▼
   snapshot.json (Store.swift)  ◄── MenuView, MainWindow, velto CLI, Starship, xbar, Waybar
                  ▼
   Status(snapshot:)                         Sources/VeltoCore/Status.swift:217
     precedence: unavailable > unconfigured > loading > stale > offline > partial > firing > healthy
```

- Menu: root (status + one row per source) → `SourcePage` / `AllAlertsPage` → `AlertRow` with context menu (copy name, copy labels, open). `MenuView.swift`.
- Window: Overview, Alerts (already has search + minimum-severity filter, `MainWindow.swift:494`), Sources, Settings.
- CLI: `status`, `alerts [--source] [--severity] [--json]`, `refresh`, `doctor`, `open` (`Sources/VeltoCLI/main.swift`).
- Tests: `Checks/main.swift`, plain preconditions, `swift run VeltoChecks`.
- Dev rendering: `VELTO_SNAPSHOTS=/tmp/shots swift run VeltoApp` renders menu states to PNG (`Sources/VeltoApp/Snapshots.swift`).

## Desired End State

```
config.json (+ mutes, quietHours, source.requires, source.queries, source.probes, source.watchTargets)
   │
   ▼
Monitor.refresh()
   ├─ NetworkGate: condition unmet? → SourceSnapshot.pausedReason, skip fetch
   ├─ Fetcher.fetch(source) → SourceResult(alerts, checks)
   │     prometheus | mimir | grafana | alertmanager | probes
   │     + pinned queries (/api/v1/query), + targets (/api/v1/targets)
   ├─ apply(): carry firstSeen, compute resolved (1h), apply mutes → snoozedUntil,
   │           append history.jsonl, compute flapCount
   └─ Notifier: new alerts (minus snoozed, minus quiet hours), optional resolved
   ▼
snapshot.json  { sources: [{ alerts[+annotations,firstSeen,snoozedUntil,flapCount],
                             resolved[], checks[], pausedReason }] }
   ▼
Status: + snoozed, + paused, + check breaches; Health + .paused
   ▼
Menu / Window / CLI (status, alerts, checks, history) / Starship / xbar / Waybar
```

Menu source page, end of v0.4:

```
┌──────────────────────────────────────────┐
│ ‹  Production                            │
│    Prometheus · checked 12s ago          │
│ ──────────────────────────────────────── │
│ ● HighMemoryUsage           NEW  Critical│
│   api-server-01 · 23m · platform         │
│   [Runbook] [Dashboard] [Silence ▾]      │
│ ● DiskSpaceLow  ×3      ⟳ 4× in 1h  Warn │
│   postgres-02, -03, -04 · 8m          ›  │
│ ◌ CertRenewal   snoozed until 14:00      │
│ ── Checks ────────────────────────────── │
│ Targets up            214/216      !     │
│ Cert expiry (min)     23 days      ✓     │
│ Disk free (min)       11 %         !     │
│ ── Resolved in the last hour ─────────── │
│ ✓ NodeExporterDown   homelab-01 · 12m ago│
└──────────────────────────────────────────┘
```

Menu root with a paused source:

```
┌──────────────────────────────────────────┐
│ (v) velto                                │
│     ● 3 firing · 1 snoozed            ›  │
│ ──────────────────────────────────────── │
│ ● Production                        3  › │
│ ● Homelab                              › │
│ ◌ Corp Mimir         Paused · VPN      › │
└──────────────────────────────────────────┘
```

## Abstractions and Code Reuse

- `Sources/VeltoCore`
  - `Model.swift`
    - `Alert` - add `annotations`, `firstSeen`, `snoozedUntil`, `flapCount`; derived `runbookURL`, `dashboardURL(base:)`, `owner`, `environment`, `isNew(now:)`; custom `init(from:)`
    - `SourceSnapshot` - add `resolved: [ResolvedAlert]`, `checks: [Check]`, `pausedReason: String?`; custom `init(from:)`
    - `Source` - add `requires: NetworkCondition?`, `queries: [PinnedQuery]`, `watchTargets: Bool`, `probes: [Probe]`
    - `Config` - add `mutes: [Mute]`, `quietHours: QuietHours?`, `notifyResolved: Bool`
    - `SourceKind` - add `.alertmanager`, `.probes`
    - new `Mute`, `QuietHours`, `NetworkCondition`, `ResolvedAlert`, `Check`, `CheckState`, `PinnedQuery`, `Probe`
  - `Fetch.swift` - `AlertParser.grafana` renamed `alertmanagerV2`; `Fetcher.fetch` returns `SourceResult`; query + targets parsing; silence request builder
  - `Status.swift` - `snoozed`, `paused`, check breaches, `Health.paused`
  - `Render.swift` - context, new markers, groups, checks, history, paused
  - new `Merge.swift` - `SnapshotMerge.merge(previous:result:now:)`: firstSeen carry-over, resolved list, history events (pure, moved out of `Monitor.apply`)
  - new `Filter.swift` - `AlertFilter`, `AlertGroup`, `Grouping`, `Snooze.presets` (pure, shared by menu, window, CLI)
  - new `History.swift` - `HistoryEvent`, append/prune/read, flap count
  - new `Silence.swift` - `SilenceRequest` build + response parse
  - new `Probe.swift` - probe runners (HTTP, TCP, TLS, DNS) behind one `ProbeRunner.run(_:)`
  - `Store.swift` - `historyURL`
- `Sources/VeltoApp`
  - `Monitor.swift` - carry-over in `apply`, mutes, history, network gate, query/probe results
  - new `NetworkGate.swift` - `NWPathMonitor`, condition evaluation
  - `Notifier.swift` - skip snoozed, quiet hours, resolved notifications, snooze actions on notifications
  - `MenuView.swift` - `AlertRow` context links + chips, group rows, resolved section, checks section, filter bar, snooze/silence menus, paused rows
  - `MainWindow.swift` - Alerts page filters/grouping/history; Sources page paused state
  - `SourceEditor.swift` - Network section, Queries section, Targets toggle, Probes editor, Alertmanager kind, Settings: quiet hours + resolved toggle
  - `Snapshots.swift` - new preview states per phase
- `Sources/VeltoCLI/main.swift` - `alerts --env --group`, `checks`, `history`, usage text
- `Checks/main.swift` - new check functions per phase
- `README.md`, `RELEASE_NOTES.md`, `VERSION`

## Logging & Observability

Velto has no log file; `velto doctor` is the observability surface. Extend it per phase:

```
Sources
  ✓ Production · Prometheus · https://prom.example.com · ok 12s ago
      3 queries (1 failing: "disk_free" · bad_data: parse error at char 12)
  ! Corp Mimir · Grafana Mimir · https://mimir.corp · paused · VPN required
  ✓ Homelab probes · Probes · 4 probes · ok 8s ago

Local state
  ✓ history   ~/Library/Application Support/co.varell.velto/history.jsonl · 412 events · 7 days
  ✓ mutes     2 active (until 14:00, until tomorrow 09:00)
```

Error strings stay short, human and free of secrets (existing rule in `FetchError.errorDescription`).

## Implementation

### Phase 1: Alert context (runbook, dashboard, owner)

Dependencies: None

Keep annotations on every alert and surface the three links people need during an incident.

**Tasks**:
- [x] `Model.swift` `Alert`: add `annotations: [String: String]` (default `[:]`) and a hand-written `init(from:)` that decodes every field with `decodeIfPresent` so v0.1.0 snapshots load.
- [x] `Model.swift` `Alert`: add derived properties:
  ```swift
  var runbookURL: URL?   // annotations runbook_url | runbook | playbook, http(s) only
  var owner: String?     // labels team | owner | squad | service_owner
  var environment: String? // labels env | environment | cluster | tenant
  func dashboardURL(base: String) -> URL? // annotations dashboard_url | grafana_url, else
                                          // __dashboardUid__ (+ __panelId__) → {base}/d/{uid}?viewPanel={id}
  ```
- [x] `Fetch.swift` `AlertParser.alert(...)`: pass the full annotations dictionary into `Alert`.
- [x] `MenuView.swift` `AlertRow`: add owner to the subtitle; add a compact link strip (Runbook, Dashboard) shown when present; add "Open Runbook" / "Open Dashboard" / "Copy Annotations" to the context menu. `dashboardURL(base:)` uses `Source.linkURL` host, falling back to `Source.url` for Grafana sources.
- [x] `MainWindow.swift` Alerts page rows: same links and owner.
- [x] `Render.swift` `alerts`: append owner after target; add `runbook: <url>` line under an alert when present (no color codes when color is off). `xbar`: add submenu items `--Runbook | href=` and `--Dashboard | href=`.
- [x] `Snapshots.swift`: add a "context" state with runbook, dashboard and owner.
- [x] `Checks/main.swift`: `checkContext()` — annotations survive parsing for both formats; runbook rejects non-http values; dashboard URL from `__dashboardUid__` + `__panelId__`; owner/env label precedence; a v0.1.0 snapshot JSON without `annotations` decodes.
- [x] `README.md`: short "Alert context" section listing the recognized annotation and label names.

**Automated Verification**:
- [x] `swift build` succeeds
- [x] `swift run VeltoChecks` passes, including `checkContext()`
- [x] `VELTO_SNAPSHOTS=$TMPDIR/shots swift run VeltoApp` writes the new `context` PNG

**Manual Verification**:
- [ ] With a real source whose rules carry `runbook_url`, the menu row shows Runbook and opens it in one click

### Phase 2: Change tracking (new and resolved)

Dependencies: Phase 1

Answer "what changed?" at a glance.

**Tasks**:
- [x] `Model.swift` `Alert`: add `firstSeen: Date?`, `static let newWindow: TimeInterval = 600`, `func isNew(now:) -> Bool` (`firstSeen` within window).
- [x] `Model.swift`: add `ResolvedAlert { alert: Alert; resolvedAt: Date }` and `SourceSnapshot.resolved: [ResolvedAlert]` (custom `init(from:)`, default `[]`).
- [x] `Monitor.swift` `apply`: on success, set `firstSeen` from the previous snapshot's matching id, else `now` (on the first-ever check, use `activeAt ?? now` so a fresh install doesn't mark everything new). Alerts that disappeared go to `resolved` with `resolvedAt = now`; prune entries older than 1 hour and cap at 20. A source whose connection changed (`Monitor.update`) resets `resolved`. On failure, keep both lists untouched.
- [x] `Config`: add `notifyResolved: Bool` (default `false`). `Notifier`: new `postResolved(_:)` when enabled, single summary above 3 like `post`.
- [x] `MenuView.swift`: "NEW" chip on `AlertRow` when `isNew`; root summary adds `· 1 new` when any; `SourcePage` gets a dimmed "Resolved in the last hour" section (✓ name, target, "12m ago").
- [x] `MainWindow.swift`: same chip; Settings gets the "Notify when alerts resolve" toggle.
- [x] `Render.swift` `alerts`: `new` marker after the duration; a `resolved` sub-list per source in the default format; `json` includes the new fields automatically.
- [x] `Checks/main.swift`: `checkChanges()` on a pure helper extracted from `apply` (`SnapshotMerge.merge(previous:result:now:)` in new `Sources/VeltoCore/Merge.swift`, called from `Monitor.apply`): firstSeen carried over; new alert gets `now`; first-ever check is not new; resolved list prunes at 1h and caps at 20; failure keeps lists.
- [x] `README.md` + `RELEASE_NOTES.md`: describe New and Resolved.

**Automated Verification**:
- [x] `swift run VeltoChecks` passes, including `checkChanges()`
- [x] `swift build` succeeds

**Manual Verification**:
- [ ] Trigger a test alert, see "NEW" in the menu, resolve it, see it in "Resolved in the last hour"

### Phase 3: Filters and grouping

Dependencies: Phase 1 (environment label)

Fewer rows to scan without hiding anything.

**Tasks**:
- [x] New `Sources/VeltoCore/Filter.swift`:
  ```swift
  public struct AlertFilter: Codable, Equatable { var minimum: Severity = .none; var environment: String?; var text = "" }
  public struct AlertGroup: Identifiable { let id: String; let name: String; let alerts: [Alert] } // id = source id + name
  public enum Grouping { static func group(_ alerts: [Alert]) -> [AlertGroup] } // by alertname, order preserved, never merges ids
  ```
- [x] `MenuView.swift` `AllAlertsPage`/`SourcePage`: a one-line filter bar (severity: All / Critical / Warning+, environment menu built from environments present) persisted in `UserDefaults` key `menuFilter`. Groups with more than one alert render as `DiskSpaceLow ×3` with joined targets and expand inline on click.
- [x] `MainWindow.swift` Alerts page: replace the local filter state with `AlertFilter`, add environment picker and a "Group by name" toggle.
- [x] `Sources/VeltoCLI/main.swift`: `velto alerts --env NAME --group`; update usage text.
- [x] `Render.swift` `alerts`: accept `AlertFilter` and `grouped: Bool`; grouped rows print `● DiskSpaceLow ×3  postgres-02, postgres-03, postgres-04`.
- [x] `Checks/main.swift`: `checkFilters()` — environment filter, text filter matches name/target/summary, grouping keeps distinct ids and order, single-alert groups render as plain rows.
- [x] `README.md`: document `--env` and `--group`.

**Automated Verification**:
- [x] `swift run VeltoChecks` passes, including `checkFilters()`
- [x] `swift run velto alerts --help` lists `--env` and `--group`

**Manual Verification**:
- [ ] In the menu, filtering to Critical and grouping a 3-alert name behaves as in the mockup and survives reopening the menu

### Phase 4: Local snooze and quiet hours

Dependencies: Phase 2 (carry-over in `apply`)

Reduce interruptions without lying about state. Ships v0.2.0.

**Tasks**:
- [x] `Model.swift`: `Mute { id: UUID; sourceID: UUID; alertName: String; alertID: String?; until: Date }` (nil `alertID` = whole alert name in that source); `QuietHours { start: Int; end: Int; allowCritical: Bool }` (minutes after midnight, wraps midnight); `Config.mutes`, `Config.quietHours` with `decodeIfPresent`.
- [x] `Model.swift` `Alert`: add `snoozedUntil: Date?`.
- [x] `Monitor.swift`: after merge, set `snoozedUntil` from the latest matching unexpired mute; drop expired mutes from config on each refresh; add `snooze(_ alert:, in source:, scope: .alert | .name, until:)` and `unsnooze(_:)`.
- [x] `Status.swift`: `snoozed` count; `firing` and `worst` exclude alerts with `snoozedUntil > now`; healthy detail becomes `… · 1 snoozed`; headline `All clear` stays when only snoozed alerts remain, `compact` stays empty.
- [x] `Filter.swift`: `Snooze.presets(now:calendar:) -> [(label, Date)]` → 1 hour, 4 hours, until 09:00 tomorrow.
- [x] `Notifier.swift`: skip snoozed alerts; skip everything during quiet hours except critical when `allowCritical`; add notification actions "Snooze 1h" and "Snooze until tomorrow" (UNNotificationCategory) that call back into `Monitor.snooze`.
- [x] `MenuView.swift` `AlertRow`: context menu "Snooze ▸ 1 hour / 4 hours / Until tomorrow 09:00" for this alert and "Snooze all \(name)"; snoozed rows render dimmed with `snoozed until 14:00` and an "Unsnooze" item.
- [x] `SourceEditor.swift` `SettingsForm`: Quiet hours section (toggle, start, end, "Let critical alerts through").
- [x] `Render.swift`: snoozed alerts print dimmed with `snoozed until HH:mm`; `starship`/`waybar`/`plain` counts follow `Status`.
- [x] `Checks/main.swift`: `checkSnooze()` — snoozed alert not counted, `All clear · 1 snoozed` detail, name-scope mute matches all ids, expired mute ignored, quiet-hours window across midnight, preset "until 09:00 tomorrow" at 23:30 and at 08:00.
- [x] `README.md`, `RELEASE_NOTES.md` (v0.2.0 section), `VERSION` → `0.2.0`.

**Automated Verification**:
- [x] `swift run VeltoChecks` passes, including `checkSnooze()`
- [x] `swift build -c release` succeeds

**Manual Verification**:
- [ ] Snooze a firing alert from its notification; the menu bar count drops, the alert shows dimmed, and it returns after the snooze ends
- [ ] During quiet hours, a warning alert produces no notification and a critical one does (with the option on)

### Phase 5: Network-aware sources

Dependencies: None (can run after Phase 4 for release grouping)

Stop calling the corporate stack "offline" when you are simply not on the VPN.

**Tasks**:
- [x] `Model.swift`: `NetworkCondition: Codable` — `.vpn`, `.resolves(host: String)`; `Source.requires: NetworkCondition?`; `SourceSnapshot.pausedReason: String?`.
- [x] New `Sources/VeltoApp/NetworkGate.swift`: wraps `NWPathMonitor`; `func satisfied(_ c: NetworkCondition) async -> Bool` — `.vpn` checks `getifaddrs` for an up `utun*`/`ppp*`/`ipsec*` interface with an IPv4 or non-link-local IPv6 address; `.resolves` runs `getaddrinfo` with a 3s timeout off the main actor. Publishes path changes.
- [x] `Monitor.swift` `refresh`: evaluate conditions first; unmet → set `pausedReason` (`"VPN required"` or `"needs \(host)"`), skip fetch, keep cached alerts and `lastSuccess`. Met → clear `pausedReason`. Path change triggers `refresh()` (debounced 2s).
- [x] `Status.swift`: `paused` count; paused sources excluded from `offline` and from the healthy-source count; `Health.paused` when every source is paused (headline `Paused`, compact `‖`, detail `Paused · VPN required`). Mixed: detail adds `· 1 paused`.
- [x] `MenuView.swift`: paused rows show a hollow dot and `Paused · VPN`; `SourcePage` shows cached alerts dimmed under `Paused · last checked 2h ago`.
- [x] `SourceEditor.swift`: "Only check when" section — Always / Connected to a VPN / This host resolves [field, defaults to the source host].
- [x] `Render.swift`: paused source line `Corp Mimir  paused · VPN required`; waybar class `paused`; xbar row in gray.
- [x] `velto doctor`: paused reason per source.
- [x] `Checks/main.swift`: `checkPaused()` — paused not counted as offline, all-paused health, mixed detail text, a stale snapshot is still `stale` even when one source is paused, `NetworkCondition` round-trips, a config without `requires` loads.
- [x] `README.md`: "Work and home" section.

**Automated Verification**:
- [x] `swift run VeltoChecks` passes, including `checkPaused()`
- [x] `swift build` succeeds

**Manual Verification**:
- [ ] With a source set to "Connected to a VPN": disconnect VPN → `Paused · VPN required` within seconds, no offline warning; reconnect → checks resume without a manual refresh

### Phase 6: Local history and flapping

Dependencies: Phase 2

Show whether a problem keeps coming back.

**Tasks**:
- [x] New `Sources/VeltoCore/History.swift`: `HistoryEvent { at: Date; sourceID: UUID; source: String; alertID: String; name: String; target: String?; kind: fired|resolved }`; `History.append(_:)`, `History.load(since:)`, `History.prune(now:)` (7 days, 5,000 lines, atomic rewrite), `History.flapCount(alertID:events:now:) -> Int` (fired events in the last 60 minutes).
- [x] `Store.swift`: `historyURL`, 0600 permissions like the other files.
- [x] `Model.swift` `Alert`: `flapCount: Int?` (only set when ≥ 3).
- [x] `Monitor.swift` `apply`: append fired/resolved events from the merge result; prune once per hour; set `flapCount`.
- [x] `MenuView.swift` `AlertRow`: `⟳ 4× in 1h` chip when flapping.
- [x] `MainWindow.swift` Alerts page: "History" segment listing the last 24h of events, newest first, grouped by day.
- [x] `Sources/VeltoCLI/main.swift`: `velto history [--since 24h|7d] [--source NAME] [--json]`; reads `history.jsonl` only.
- [x] `Render.swift`: `history(_:)` text renderer; flapping marker in `alerts`.
- [x] `Checks/main.swift`: `checkHistory()` — append/load round-trip in a temp `VELTO_HOME`, prune by age and count, flap threshold at exactly 3, corrupt line skipped not fatal.
- [x] `README.md`: `velto history`.

**Automated Verification**:
- [x] `swift run VeltoChecks` passes, including `checkHistory()`
- [x] `swift run velto history --since 24h` exits 0 with an empty or populated history

### Phase 7: Alertmanager source and upstream silences

Dependencies: Phase 4 (snooze menu placement)

The most common alert router, plus the most-wanted action. Ships v0.3.0.

**Tasks**:
- [x] `Model.swift` `SourceKind`: add `.alertmanager` (label "Alertmanager").
- [x] `Fetch.swift` `alertsURL`: `.alertmanager` → `{base}/api/v2/alerts?active=true&silenced=false&inhibited=false`. Send `X-Scope-OrgID` for `.mimir` and `.alertmanager` when `orgID` is set.
- [x] `Fetch.swift`: rename `AlertParser.grafana` → `alertmanagerV2`; use it for `.grafana` and `.alertmanager`.
- [x] New `Sources/VeltoCore/Silence.swift`:
  ```swift
  public struct SilenceRequest { static func make(source: Source, alert: Alert, until: Date, now: Date, user: String) -> URLRequest? }
  // POST {silencesBase}/api/v2/silences, silencesBase = base (alertmanager) | base/api/alertmanager/grafana (grafana)
  // body: matchers = alert.labels → {name, value, isEqual: true, isRegex: false}, startsAt, endsAt, createdBy, comment
  public static func expire(source:id:) -> URLRequest? // DELETE {silencesBase}/api/v2/silence/{id}
  ```
  Auth headers reuse `Source.request(credentials:)` logic (extract a shared `authorize(_:credentials:)`).
- [x] `Monitor.swift`: `silence(_ alert:, in source:, until:) async -> Result<String, Error>` and `expireSilence(id:in:)`; refresh after success.
- [x] `MenuView.swift` `AlertRow`: for `.alertmanager`/`.grafana` sources, context menu "Silence upstream ▸ 1 hour / 4 hours / Until tomorrow 09:00"; after success an inline banner `Silenced until 13:00 · Undo` for 10s; errors use the existing short messages (403 → "403 Forbidden · check access for this tenant").
- [x] `SourceEditor.swift`: kind picker includes Alertmanager; URL help: `https://alertmanager.example.com` or `https://mimir.example.com/alertmanager`; tenant field shown for Mimir and Alertmanager.
- [x] `README.md` Sources table: add Alertmanager and Mimir Alertmanager; a "Also works" note — Loki ruler: use Grafana Mimir type with the Loki URL (`/prometheus/api/v1/alerts`); vmalert and Thanos Ruler: use Prometheus type. Update CLI usage tagline and `README` intro line.
- [x] `Checks/main.swift`: `checkAlertmanager()` — URL building with and without `/alertmanager`, tenant header for alertmanager, Grafana parser fixture still passes via the renamed function, silence request body (matchers, dates ISO8601, createdBy), Grafana silences path, expire path; vmalert and Loki fixture JSON parse with existing parsers.
- [x] `RELEASE_NOTES.md` (v0.3.0 section covering phases 5-7), `VERSION` → `0.3.0`.

**Automated Verification**:
- [x] `swift run VeltoChecks` passes, including `checkAlertmanager()`
- [x] `swift build -c release` succeeds

**Manual Verification**:
- [ ] Silence an alert from a real Alertmanager or Grafana source; it disappears on the next check, appears in the upstream silences list with `createdBy` = your user, and Undo brings it back

### Phase 8: Check model and pinned PromQL queries

Dependencies: None in code; ships after Phase 7

Watch a number without writing an alert rule.

**Tasks**:
- [x] `Model.swift`:
  ```swift
  public enum CheckState: String, Codable { case ok, warn, crit, unknown }
  public struct Check: Codable, Identifiable, Hashable { id: String; name: String; value: Double?; display: String; state: CheckState; message: String? }
  public struct PinnedQuery: Codable, Identifiable, Hashable {
      id: UUID; name: String; query: String; unit: Unit /* none|percent|bytes|seconds|days */
      direction: Direction /* above|below: which side is bad */; warn: Double?; crit: Double?
  }
  ```
  `Source.queries: [PinnedQuery]`, `SourceSnapshot.checks: [Check]`, all `decodeIfPresent`.
- [x] `Fetch.swift`: `SourceResult { alerts: [Alert]; checks: [Check] }`; `Fetcher.fetch(for:credentials:)` runs the alerts request and every query concurrently. Query URL `{base}/api/v1/query?query=` (Mimir: `/prometheus` prefix as for alerts). Parse `vector` (reduce to worst value by `direction`) and `scalar`; empty vector → `unknown`, display `no data`; HTTP or parse error → `unknown` with message; only the alerts request decides offline. Keep `Fetcher.alerts` as a thin wrapper for `Monitor.test`.
- [x] `Model.swift` `PinnedQuery.evaluate(_ value: Double?) -> (CheckState, String)` and unit formatting (`11 %`, `23 days`, `1.2 GB`, `340 ms`).
- [x] `Status.swift`: `firing` += checks in warn/crit; `worst` maps crit → critical, warn → warning; `unknown` adds `· 1 check no data` to detail but is not counted.
- [x] `Monitor.swift`: store `checks`; on failure keep previous checks (cached, like alerts).
- [x] `MenuView.swift` `SourcePage`: "Checks" section, one row per check (name, display value, ✓/!/× colored by state, `no data` in warning tone). Root row trailing count includes breached checks.
- [x] `SourceEditor.swift`: "Pinned queries" section for Prometheus/Mimir — list with add/remove, fields name, PromQL, unit, "bad when above/below", warn, crit, and a per-query "Test" showing the current value. Built-in presets menu: "Targets down" `count(up == 0) or vector(0)` (crit > 0), "Lowest disk free %", "Days until a certificate expires" (`min((probe_ssl_earliest_cert_expiry - time()) / 86400)`, below, warn 14, crit 7).
- [x] `Sources/VeltoCLI/main.swift`: `velto checks [--source NAME] [--json]`.
- [x] `Render.swift`: `checks(_:style:)`; `alerts` prints breached checks under the source; `xbar` adds a checks block; `waybar` tooltip includes checks.
- [x] `Snapshots.swift`: "checks" state matching the mockup.
- [x] `Checks/main.swift`: `checkQueries()` — vector/scalar/empty/error parsing, worst-value reduction both directions, thresholds at boundaries, unit formatting, Status counts warn/crit not unknown, failed source keeps cached checks, v0.3 snapshot without `checks` decodes.
- [x] `README.md`: "Pinned queries" section with the presets.

**Automated Verification**:
- [x] `swift run VeltoChecks` passes, including `checkQueries()`
- [x] `swift run velto checks --json` prints valid JSON
- [x] `VELTO_SNAPSHOTS=$TMPDIR/shots swift run VeltoApp` writes the `checks` PNG

**Manual Verification**:
- [ ] Add the "Targets down" preset to a real source, test it in the editor, and see it in the menu's Checks section

### Phase 9: Target health and built-in probes

Dependencies: Phase 8

"Green doesn't always mean healthy": watch scrape targets, and check services without any Prometheus. Ships v0.4.0.

**Tasks**:
- [x] `Model.swift` `Source.watchTargets: Bool`; `Fetch.swift`: when set on a `.prometheus` source, GET `{base}/api/v1/targets?state=active`, produce check `Targets up` with display `214/216`, warn when any target is down, crit when more than 10% are down; failure → `unknown`. Mimir sources get the "Targets down" query preset instead (no targets API); the toggle is hidden for them.
- [x] `Model.swift`: `SourceKind.probes` (label "Probes"); `Probe { id: UUID; name: String; type: http|tcp|tls|dns; target: String; expectStatus: ClosedRange<Int>?; warnDays: Int = 14; critDays: Int = 7 }`; `Source.probes: [Probe]`. `isComplete` for `.probes` = at least one probe with a non-empty target; `alertsURL()` stays nil-safe.
- [x] New `Sources/VeltoCore/Probe.swift`, `ProbeRunner.run(_ probe:, skipTLSVerify:) async -> Check`:
  - http: GET with 10s timeout; ok when status in `expectStatus ?? 200...399`; display `200 · 140 ms`
  - tcp: `NWConnection` to `host:port`, ready within 5s → ok; display `open · 22 ms`
  - tls: URLSession delegate captures `serverTrust`, `SecTrustCopyCertificateChain` → leaf `SecCertificateCopyValues` with `kSecOIDX509V1ValidityNotAfter`; days left vs `warnDays`/`critDays`; display `23 days`
  - dns: `getaddrinfo`, ok when any address; display first address
- [x] `Fetch.swift` `Fetcher.fetch`: `.probes` → run all probes concurrently, `alerts: []`; a probes source is never "offline" (each probe carries its own state).
- [x] `SourceEditor.swift`: for `.probes`, hide URL/auth and show a probe list editor (type picker, target with per-type placeholder `https://…`, `host:443`, `example.com`) with per-probe Test.
- [x] `MenuView.swift`/`MainWindow.swift`: probes source rows reuse the Checks section; root trailing shows breached count.
- [x] `Checks/main.swift`: `checkProbes()` — probe config round-trip, isComplete rules, TLS day thresholds, HTTP status range evaluation (pure functions), targets JSON parsing (all up, some down, >10% down), target toggle ignored for Mimir. Network-touching runners are exercised only against `127.0.0.1` listeners started inside the check (TCP open/closed).
- [x] `README.md`: Probes + target health sections; Sources table gains "Probes".
- [x] `RELEASE_NOTES.md` (v0.4.0 covering phases 8-9), `VERSION` → `0.4.0`.

**Automated Verification**:
- [x] `swift run VeltoChecks` passes, including `checkProbes()`
- [x] `swift build -c release` succeeds
- [x] `bash build-app.sh` builds and installs the app

**Manual Verification**:
- [ ] A Probes source with an HTTP probe, a TLS probe on a real site and a TCP probe on a closed port shows ok / days left / crit in the menu, and the closed port counts toward the badge

## Roadmap (separate plan, after validation)

Decisions already made for the follow-up plan, so it starts from here:

- **First step: introduce an `Integration` protocol** (`fetch(source, credentials) -> SourceResult`) and move the five kinds onto it.
- **Auth:** add `AuthMethod.apiKey` with configurable header and prefix (PagerDuty `Authorization: Token token=`, Opsgenie `Authorization: GenieKey`, Healthchecks.io `X-Api-Key`, Proxmox `Authorization: PVEAPIToken=`).
- **Incident:** PagerDuty (`/incidents?statuses[]=triggered&statuses[]=acknowledged`), Opsgenie (`/v2/alerts?query=status:open`).
- **Uptime (first, KumaBar audience):** Uptime Kuma, Healthchecks.io (`/api/v3/checks/`), Gatus (`/api/v1/endpoints/statuses`). Must handle hundreds of monitors (grouping from Phase 3 applies) and auth behind proxies such as Authelia (header auth).
- **CI:** GitLab (`/api/v4/projects/:id/pipelines?ref=<default>&per_page=1`), GitHub (`/repos/:o/:r/actions/runs?branch=<default>&per_page=1`).
- **Kubernetes:** native API with server URL, optional CA file, existing token command; "Import from kubeconfig" via `kubectl config view --minify --raw -o json` only when kubectl exists; NotReady nodes, CrashLoopBackOff pods, stuck rollouts as alerts; counts as checks.
- **Homelab:** Proxmox, TrueNAS, Home Assistant, UniFi; Docker/OrbStack via `docker ps -a --format json` through the login shell.
- **Raycast extension** on `velto status --format json` / `velto alerts --json`.
- **Gated on Xcode project + App Group + Developer ID signing:** WidgetKit widget, App Intents (Shortcuts), Focus filter.

## Implementation Notes

During implementation, document user feedback, problems, and decisions here.

- Research input: "What Reddit users actually want from monitoring tools", Nov 2026 (pasted in planning session). Thread links were not verifiable from the paste; treated as directional evidence. Validate the v0.2 features with real Prometheus/Grafana users before starting the roadmap plan.

## References

- `Sources/VeltoCore/Model.swift`, `Fetch.swift`, `Status.swift`, `Render.swift`, `Store.swift`
- `Sources/VeltoApp/Monitor.swift`, `MenuView.swift`, `MainWindow.swift`, `SourceEditor.swift`, `Notifier.swift`, `Snapshots.swift`
- `Sources/VeltoCLI/main.swift`, `Checks/main.swift`, `README.md`
- Prometheus HTTP API: `/api/v1/alerts`, `/api/v1/query`, `/api/v1/targets`
- Alertmanager API v2: `/api/v2/alerts`, `/api/v2/silences`, `/api/v2/silence/{id}`
- Grafana Alertmanager: `/api/alertmanager/grafana/api/v2/...`
- Mimir: `/prometheus/api/v1/...` ruler, `/alertmanager/api/v2/...`, `X-Scope-OrgID`
- Loki ruler: `/prometheus/api/v1/alerts`
