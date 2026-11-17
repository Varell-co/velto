# Velto v0.3.0

## New

- Network-aware sources: check a source only on the VPN or when an internal host resolves; otherwise it shows as paused, not offline
- Local history of fires and resolves (7 days), `velto history`, and a History tab in the window
- Flapping alerts (3 or more starts in an hour) are marked `⟳ 4× in 1h`
- Alertmanager source, standalone or Mimir's, with tenant support
- Silence an alert upstream from the menu for Alertmanager and Grafana sources, with Undo
- Loki ruler, vmalert and Thanos Ruler documented as working with the existing types

---

# Velto v0.2.0

## New

- Alert context: runbook and dashboard links, one click from the menu, plus the owning team
- Alerts first seen in the last 10 minutes are marked New; alerts that resolved in the last hour are listed per source
- Optional notification when alerts resolve
- Filter the menu and window by severity and environment; same-name alerts fold into one expandable row
- `velto alerts --env NAME --group`
- Snooze an alert or an alert name locally for 1 hour, 4 hours or until tomorrow, from the menu or the notification
- Quiet hours pause notifications, optionally letting critical alerts through

---

# Velto v0.1.0

## New

- Menu bar app for Prometheus, Grafana Mimir and Grafana Alerting alerts, rebuilt in Swift from Pulse
- `velto` CLI with status, alerts, refresh and doctor, plus Starship, xbar and Waybar formats
- Sources and secrets managed in Settings, with tokens in the Keychain
- One-time import from Pulse

---

