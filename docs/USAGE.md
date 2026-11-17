# Using Velto

## Getting started

1. Open Velto and click its icon in the macOS menu bar.
2. Open **Sources** and choose **Add Source**. Select the source type and enter its base URL and any required tenant or credentials. Velto saves your changes as you edit.
3. Choose **Check Now** to fetch alerts. Click a source to see its alerts and when it last checked in.

Allow Velto notifications in macOS System Settings if you want to be notified when an alert starts firing. Velto imports sources from `~/.config/pulse/config.toml` on first launch if you previously used Pulse.

## Sources

| Type | Endpoint Velto reads |
|---|---|
| Prometheus | `/api/v1/alerts` |
| Grafana Mimir | `/prometheus/api/v1/alerts` (tenant sent as `X-Scope-OrgID`) |
| Grafana Alerting | `/api/alertmanager/grafana/api/v2/alerts` |
| Alertmanager | `/api/v2/alerts` (standalone, e.g. `https://alertmanager.example.com`) |
| Mimir Alertmanager | type Alertmanager with `https://mimir.example.com/alertmanager`; tenant sent as `X-Scope-OrgID` |

**Also works:** the Loki ruler (type Grafana Mimir with the Loki URL; Velto reads `/prometheus/api/v1/alerts`), and vmalert or Thanos Ruler (type Prometheus).

**Silence upstream:** for Alertmanager and Grafana Alerting sources, right-click an alert → Silence Upstream (1 hour, 4 hours, until 09:00 tomorrow). The silence matches the alert's exact label set, is created by your macOS user name with the comment "Silenced from Velto", and can be undone for 10 seconds. Prometheus and Mimir rulers don't know which Alertmanager routes their alerts, so the action isn't offered there; use a local snooze instead.

Authentication can be a bearer token, a token command (for example `az account get-access-token --query accessToken -o tsv`, run in your login shell before each check), or username and password. Tokens and passwords are stored in your Keychain, never in the config file.

## Metric checks and probes

In a Prometheus or Grafana Mimir source, open **Pinned queries** and choose **Add Query** to run an instant PromQL query on every refresh. Set warning and critical thresholds. A breach counts as firing, and a missing result appears as **no data**.

Choose **Probes** as the source type to check services directly. Use **Add Probe** to configure each check. A failing probe counts as firing.

## Alert context

When an alert carries them, Velto shows the links people need during an incident, one click away in the menu, the window and `velto alerts`:

| Shown as | Read from |
|---|---|
| Runbook | annotation `runbook_url`, `runbook` or `playbook` (http and https links only) |
| Dashboard | annotation `dashboard_url` or `grafana_url`; otherwise Grafana's `__dashboardUid__` and `__panelId__`, opened on the source's dashboard link host (or a Grafana source's URL) |
| Owner | label `team`, `owner`, `squad` or `service_owner` |
| Environment | label `env`, `environment`, `cluster` or `tenant` |

## What changed

An alert Velto first saw in the last 10 minutes is marked **New**, in the menu, the window and `velto alerts`. The first check after installing doesn't mark everything new: alerts that were already firing keep their start time. Alerts that stopped firing in the last hour are listed under **Resolved** on the source's page. Settings has an option to get a notification when alerts resolve (off by default).

## Filters and grouping

The menu and the window filter by severity and environment; the menu remembers its filter. Same-name alerts in one source collapse into one row (`DiskSpaceLow ×3`) that expands on click. Grouping is display only: alerts with different labels stay separate alerts, so two incidents that share a name are never merged.

## Snooze and quiet hours

Right-click an alert to snooze it, or every alert with its name in that source, for 1 hour, 4 hours or until 09:00 tomorrow. Notifications have the same buttons. A snoozed alert stays in the list, dimmed, with `snoozed until 14:00`; it doesn't count toward the badge, and the status says how many are snoozed (`All clear · 1 snoozed`). Snoozes are local to Velto: nothing is silenced on your servers.

Quiet hours (Settings) pause notifications during a time window, optionally letting critical alerts through. Counts and status lines are unaffected.

## Work and home

A source can be set to check only on the corporate network (Source → Only check when): **Connected to a VPN** (any utun, ppp or ipsec tunnel with a routable address) or **This host resolves** (an internal name, the most reliable test with split DNS). When the condition isn't met, the source shows `Paused · VPN required`: it isn't polled, isn't counted as offline, and its cached alerts aren't counted or shown as current. Velto re-checks within seconds when the network changes.

## History and flapping

Velto keeps 7 days of fire and resolve events (at most 5,000) in `history.jsonl` next to the snapshot. An alert that started firing 3 or more times in the last hour is marked `⟳ 4× in 1h`. The window's Alerts page has a History tab for the last 24 hours; `velto history` prints it in the terminal.

## Pinned queries

Prometheus and Mimir sources can watch PromQL values without an alert rule (Source → Pinned queries). Each query has a unit, a side that is bad (above or below) and optional warn and crit thresholds; a value strictly past a threshold counts as firing. An empty result shows `no data` and is never treated as healthy. A broken query marks only its own check, not the whole source. `velto checks` lists every check, healthy ones too.

Presets:

| Name | Query | Bad when |
|---|---|---|
| Targets down | `count(up == 0) or vector(0)` | above 0 (crit) |
| Lowest disk free | `min(node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100` (tmpfs and overlay excluded) | below 15 % (warn), 5 % (crit) |
| Days until a certificate expires | `min((probe_ssl_earliest_cert_expiry - time()) / 86400)` | below 14 days (warn), 7 days (crit) |

## Command line

```bash
velto alerts                      # firing alerts, grouped by source
velto alerts --severity critical  # only critical
velto alerts --env prod           # only alerts labeled env, environment, cluster or tenant = prod
velto alerts --group              # fold same-name alerts: "DiskSpaceLow ×3  postgres-02, -03, -04"
velto status                      # "3 firing", "All clear", "2 firing · 1 offline" …
velto checks                      # pinned queries, target health and probes (also --source, --json)
velto history --since 7d          # what fired and resolved, newest first (also --source, --json)
velto refresh                     # ask the app to check now, then show the result
velto doctor                      # paths, sources and their last errors
```

`--json` and `--no-color` work where they make sense; `NO_COLOR` is honored.

### Starship

```toml
[custom.velto]
command = "velto status --format starship"
when = true
format = "[$output]($style) "
style = "bold #E66A56"
```

The segment is empty when everything is healthy, so it disappears.

### xbar or SwiftBar

Save as `velto.1m.sh` in your plugin folder and make it executable:

```bash
#!/bin/bash
exec /opt/homebrew/bin/velto status --format xbar
```

### Waybar

`velto status --format waybar` prints Waybar's JSON with `text`, `tooltip` and a `class` per state (`healthy`, `firing`, `partial`, `stale`, `offline`). The CLI is macOS-only for now.

## How it works

The app checks every source on an interval (30 seconds by default) and writes `~/Library/Application Support/co.varell.velto/snapshot.json`. Everything else reads that file. When a check fails, the last good alerts stay visible and are marked as cached.

## Troubleshooting

- If a source is offline, check its URL, credentials, and network access. Run `velto doctor` to see the last error for each source.
- If a source is paused, check its VPN or DNS requirement under **Only check when**.
- If the CLI says `? unavailable`, open Velto and run **Check Now** to create the first snapshot.
