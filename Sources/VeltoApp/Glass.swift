import AppKit
import SwiftUI
import VeltoCore

/// The main window's dark glass look (after Linory): frosted charcoal, soft white edges, Iris accents.
/// The menu-bar popover stays a plain system popover.
enum Glass {
    static let ink = Color(hex: 0x111319)
    static let surface = Color(hex: 0x1B1D25)
    static let muted = Color(hex: 0xB8BBC8)
    static let cardRadius: CGFloat = 18
    static let fieldRadius: CGFloat = 10

    // The kit's status colors, tuned for dark surfaces. The popover keeps the system ones.
    static let critical = Color(hex: 0xE66A56)
    static let warning = Color(hex: 0xE8AD61)
    static let healthy = Color(hex: 0x6EBFA5)
    static let info = Color(hex: 0x78A6D8)

    static func color(for severity: Severity) -> Color {
        switch severity {
        case .critical, .none: critical
        case .warning: warning
        case .info: info
        }
    }

    static func color(for source: SourceSnapshot?) -> Color {
        guard let source, source.lastAttempt != nil, !source.isPaused else { return muted.opacity(0.6) }
        if source.error != nil { return warning }
        return source.attention() == 0 ? healthy : color(for: source.worst())
    }

    static func color(for status: Status) -> Color {
        switch status.health {
        case .healthy: healthy
        case .firing, .partial: color(for: status.worst)
        case .stale, .offline: warning
        case .loading, .unconfigured, .unavailable, .paused: muted.opacity(0.6)
        }
    }

    /// Strong ease-out, the brand's motion curve: quick to respond, calm to settle.
    static func easeOut(_ duration: Double = 0.24) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }

    /// Sets up a window for the glass look: content under a transparent title bar, always dark.
    static func configure(_ window: NSWindow) {
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
    }
}

/// Behind-window blur with the brand's charcoal over it and a faint Iris glow up top.
struct WindowGlass: View {
    var body: some View {
        ZStack {
            BehindWindowBlur()
            LinearGradient(colors: [Color(hex: 0x1A1C26), Glass.ink], startPoint: .top, endPoint: .bottom)
                .opacity(0.82)
            RadialGradient(colors: [Theme.violet.opacity(0.28), .clear], center: UnitPoint(x: 0.82, y: -0.05), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.iris.opacity(0.10), .clear], center: UnitPoint(x: 0.25, y: 0), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// A frosted card: a faint white fill and an edge that catches light at the top.
    func glassCard(radius: CGFloat = Glass.cardRadius, padding: CGFloat? = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .padding(padding ?? 0)
            .background(shape.fill(.white.opacity(0.045)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)))
    }

    /// The text-field look used across the window's forms.
    func glassField() -> some View {
        let shape = RoundedRectangle(cornerRadius: Glass.fieldRadius, style: .continuous)
        return self
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(shape.fill(.black.opacity(0.25)))
            .overlay(shape.strokeBorder(.white.opacity(0.10)))
    }
}

/// Pill buttons. `prominent` fills with Violet for the one main action on a page.
struct GlassButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let destructive: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(destructive ? Glass.critical : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0.18 : 0.10)))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Glass.easeOut(0.14), value: configuration.isPressed)
            .animation(Glass.easeOut(0.12), value: hovered)
            .onHover { hovered = $0 }
    }

    private var fill: AnyShapeStyle {
        if prominent { return AnyShapeStyle(Theme.violet.opacity(hovered ? 1 : 0.88)) }
        return AnyShapeStyle(Color.white.opacity(hovered ? 0.12 : 0.07))
    }
}

/// A round icon-only glass button, for toolbar-like actions in page headers.
struct GlassIconLabel: View {
    let systemImage: String
    @State private var hovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 30, height: 30)
            .background(Circle().fill(.white.opacity(hovered ? 0.12 : 0.07)))
            .overlay(Circle().strokeBorder(.white.opacity(0.10)))
            .contentShape(Circle())
            .onHover { hovered = $0 }
            .animation(Glass.easeOut(0.12), value: hovered)
    }
}

/// Segmented control drawn as glass pills, with the selection gliding between options.
struct GlassSegments<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { title, value in
                Button { withAnimation(Glass.easeOut()) { selection = value } } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == value ? .white : Glass.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if selection == value {
                                Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.25)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }
}

/// A small tinted capsule for counts and states ("Critical", "Unreachable").
struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// A status dot with a soft halo, so color reads at a glance on dark glass.
struct GlowDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.25)).frame(width: size * 2.2, height: size * 2.2))
            .accessibilityHidden(true)
    }
}

/// A titled card of settings rows, separated by hairlines.
struct GlassSection<Content: View>: View {
    let title: String?
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Glass.muted.opacity(0.8))
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                _VariadicView.Tree(DividedLayout()) { content }
            }
            .glassCard(padding: nil)
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Glass.muted.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Puts a hairline between a section's rows, like a grouped list.
private struct DividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child.padding(.horizontal, 16).padding(.vertical, 11)
            if child.id != last {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 16)
            }
        }
    }
}

/// One settings row: a label on the left, its control on the right.
struct GlassRow<Control: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(Glass.muted.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
    }
}
