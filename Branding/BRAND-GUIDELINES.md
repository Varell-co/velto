# velto — Brand guidelines

**Edition:** Concept v1.0 · **Parent studio:** Varell

## 01. Brand idea

Velto is a lightweight, local-first alert companion for Prometheus and Grafana Mimir. It shows the *signal* without pulling a user into a dashboard. It's designed for developers, SREs, sysadmins, and homelab operators who want ambient awareness during real work.

**Promise:** Your infrastructure, at a glance.  
**Supporting line:** Know when something needs attention. Stay focused when it doesn't.  
**Positioning:** A small, reliable place to see firing alerts and understand which source needs attention.  
**Not:** A full observability dashboard, a tracing platform, an incident system, or a pager replacement.

## 02. Personality and tone

- **Quiet:** No theatrical panic, flashing UI, or needless animations.
- **Precise:** Exact counts, alert names, sources, freshness and severity.
- **Dependable:** Clearly distinguish healthy from unknown and stale.
- **Accessible:** Simple language, color plus words/icons for status.
- **Developer-native:** Plain CLI, predictable configuration, keyboard shortcuts.

Do say: “3 firing”, “Last checked 12 seconds ago”, “Cannot reach homelab”, “Showing cached results”.  
Avoid: “Your infrastructure is on fire!”, “All systems operational” when sources are unreachable, or “AI-powered everything”.

## 03. Logo and icon

### Concept
The mark consists of **two parallel diagonal rounded strokes**. It conveys a signal, a passing trace, and activity without a literal heartbeat line. The first stroke is iris-light `#999CFF`, and the second is violet `#6259C6`. A single-color version is supplied for system menus, printing, and small dimensions.

The brand name is always **`velto` in lowercase**. Do not manually capitalize it into `Velto` in display lockups. Capitalize at the start of a normal sentence only if grammar requires it.

### Usage rules
- Prefer primary light on off-white; primary dark on charcoal.
- Use wordmark-only where a system app icon already identifies the app.
- Use the symbol alone for icons, favicons, menu bar, and tiny statuses.
- Reserve at least **1 stroke width** around the symbol and equivalent padding around full lockups.
- Target **24px minimum icon width** for multi-color displays; use monochrome at **16px or smaller** where needed.
- Target **140px minimum lockup width** for regular UI; prefer the symbol alone below that size.
- Avoid gradients, glows, shadows, rotations, stretched proportions, outlines, badges over the mark, or miscolored strokes.
- The logo must remain independent of alert severity; never turn the logo red during incidents.

### Construction
Source grid 64×64 units. Two lines with round caps, width 14 units:
- Stroke A from `(11, 42)` to `(41, 12)`
- Stroke B from `(31, 52)` to `(51, 32)`

Diagonal direction is northwest–southeast in conventional coordinates and visually rises left-to-right. Geometry should not be redrawn differently across assets.

## 04. Color

| Role | Hex | Usage |
|---|---|---|
| Charcoal | `#111319` | Main text, dark surfaces, logo backgrounds |
| Off-white | `#F5F6F2` | Primary light canvas |
| Iris | `#8E93F2` | Links, focus and brand accent |
| Iris-light | `#999CFF` | First logo stroke, dark-mode highlights |
| Violet | `#6259C6` | Second logo stroke, stronger accents |
| Critical | `#E66A56` | Critical alert indicators |
| Warning | `#E8AD61` | Warning alerts, stale data |
| Healthy | `#6EBFA5` | Successfully refreshed, no firing alerts |
| Informational | `#78A6D8` | Non-urgent information |
| Dark surface | `#1B1D25` | Dark popovers/cards |
| Dark border | `#343744` | Dark dividers |
| Light border | `#E3E4E8` | Subtle light separators |

**Semantic rule:** Brand accent is not the critical color. Alert condition never relies on hue alone: include a text label, icon, or count. Check actual foreground/background combinations for WCAG AA (4.5:1 normal text, 3:1 large text) before production. Colors assigned to compact dots are not necessarily appropriate for small text; use stronger pairings as needed.

## 05. Typography

- **Brand wordmark:** custom artwork exported as outlined SVG; built from Inter Display Bold, with manual character spacing.
- **Headlines:** Geist or Inter Display, 600–750; lowercase only for the brand name, not normal headings.
- **Body/UI:** Geist or Inter, 400–600, 14–16px desktop.
- **Telemetry and commands:** Geist Mono, JetBrains Mono or system monospace.
- **Numbers:** tabular numeral feature in status tables where supported (`font-variant-numeric: tabular-nums`).

Recommended type scale (desktop): Display 64/1.04, H1 48/1.08, H2 32/1.15, H3 24/1.2, Body 16/1.5, Small 14/1.45, Micro 12/1.4. Use responsive scaling for website headings.

Do not distribute font binaries in the brand ZIP. Install fonts separately from their authorized sources if desired.

## 06. Layout and components

- **Spacing scale:** 4px base; typical 8/12/16/24/32/48/64.
- **Border radii:** 8px tiny; 12px controls; 18px cards; 24px large hero/menu panels. App icon uses rounded-square silhouette.
- **Stroke:** 1px light/dark dividers, low contrast but discernible.
- **Shadows:** Sparse, soft; rely primarily on hierarchy and surface contrast.
- **Controls:** Compact, keyboard-friendly, clear hover/focus rings.
- **Density:** Alert menus can be compact, while marketing retains ample whitespace.
- **Alignment:** Left-align almost all UI text. Right-align severity, timestamps or counts when useful.

## 07. Motion

- Hover/focus 120ms; standard UI transitions 180ms; reveal 240ms maximum.
- Ease-out; avoid springy menu popovers or bouncing symbols.
- No continuously animated heartbeat. Respect `prefers-reduced-motion`.
- Freshness updates should change content without moving the whole layout.

## 08. Photography and illustration

Favor real, restrained interface screenshots and carefully simplified product diagrams over abstract stock photos. Ambient geometric illustrations can reference the two diagonal strokes. Avoid generic server racks, neon data tunnels and intense red backgrounds.

## 09. Brand architecture

**Name:** velto  
**Endorsement:** by Varell  
**Writing:** “velto by Varell” in small attribution, not a permanent part of all UI lockups.  
**Distribution identity:** `velto` for the CLI only if the package/binary name is actually available and cleared.

## 10. Do / don't

**Do:** small surface, clear states, low noise, monochrome compatibility, accurate alert labels, consistent icon strokes.  
**Don't:** turn it into a Grafana clone, imply data is fresh when cached, use brand iris as the emergency color, alter mark proportions, cram graphs into the menu, or use uppercase VELTO as the display logo.

## 11. Legal / naming

This work is a **design concept**. The proposed name `velto` has not been trademark-cleared; previous preliminary searches indicated existing EU registrations covering software-related fields. Verify in EUIPO/TMview, review exact goods/services and overlapping software brands, and consult qualified trademark counsel before public launch or commercial use.
