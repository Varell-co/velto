import AppKit
import SwiftUI
import VeltoCore

/// Velto brand colors (Brand Identity Kit v1.0). Surfaces come from the system so the app looks native.
enum Theme {
    static let iris = Color(hex: 0x8E93F2)
    static let violet = Color(hex: 0x6259C6)
    /// The mark's upper stroke is a touch brighter than Iris in the kit's SVGs.
    static let markIris = Color(hex: 0x999CFF)
    // Status colors are the system ones, so dots read like those in Control Center and adapt to
    // Increase Contrast. The brand's semantic tokens (#E66A56 etc.) stay in the CLI and the docs.
    static let critical = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let success = Color(nsColor: .systemGreen)
    static let info = Color(nsColor: .systemBlue)
    static let neutral = Color(nsColor: .systemGray)

    static func color(for severity: Severity) -> Color {
        switch severity {
        case .critical: critical
        case .warning: warning
        case .info: info
        case .none: neutral
        }
    }

    static func color(for status: Status) -> Color {
        switch status.health {
        case .healthy: success
        case .firing, .partial: status.worst == .none ? critical : color(for: status.worst)
        case .stale, .offline: warning
        case .loading, .unconfigured, .unavailable, .paused: neutral
        }
    }

    /// The full-color mark for the status item, as in the product concept. Not a template, so macOS
    /// leaves its colors alone; Iris and Violet read on both light and dark menu bars.
    static let menuBarColorImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            for (path, color) in zip(markPaths(in: rect), [NSColor(Theme.markIris), NSColor(Theme.violet)]) {
                color.setStroke()
                path.stroke()
            }
            return true
        }
        image.accessibilityDescription = "Velto"
        return image
    }()

    /// The two strokes from the kit's 64×64 artboard: M11 42 L41 12 and M31 52 L51 32, width 14, round caps.
    static func markPaths(in rect: NSRect) -> [NSBezierPath] {
        let s = rect.width / 64
        return [((11, 42), (41, 12)), ((31, 52), (51, 32))].map { a, b in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + a.0 * s, y: rect.minY + a.1 * s))
            path.line(to: NSPoint(x: rect.minX + b.0 * s, y: rect.minY + b.1 * s))
            path.lineWidth = 14 * s
            path.lineCapStyle = .round
            return path
        }
    }
}

/// The full-color mark: Iris over Violet.
struct VeltoMark: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 64
            func stroke(_ a: CGPoint, _ b: CGPoint, _ color: Color) {
                var path = Path()
                path.move(to: CGPoint(x: a.x * s, y: a.y * s))
                path.addLine(to: CGPoint(x: b.x * s, y: b.y * s))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 14 * s, lineCap: .round))
            }
            stroke(CGPoint(x: 11, y: 42), CGPoint(x: 41, y: 12), Theme.markIris)
            stroke(CGPoint(x: 31, y: 52), CGPoint(x: 51, y: 32), Theme.violet)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

}

/// SwiftUI has its own `Alert`; inside the app, the name means a firing alert.
typealias Alert = VeltoCore.Alert
