import SwiftUI

/// "JARVIS ● READY" — always visible.
struct StatusBadge: View {
    let status: JarvisStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.color(for: status))
                .frame(width: 10, height: 10)
                .shadow(color: Theme.color(for: status), radius: 6)
            Text("JARVIS").font(.system(.subheadline, design: .monospaced).weight(.bold)).foregroundStyle(Theme.textSecondary)
            Text(status.label).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.color(for: status))
            if let detail = status.detail {
                Text("· \(detail)").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.color(for: status).opacity(0.4)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("JARVIS status: \(status.label)")
    }
}

struct EmergencyStopButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("STOP", systemImage: "stop.circle.fill")
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Theme.danger, in: Capsule())
                .shadow(color: Theme.danger.opacity(0.6), radius: 8)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: .command)
        .accessibilityLabel("Emergency stop")
        .accessibilityHint("Stops speech and cancels everything JARVIS is doing")
    }
}

/// The animated rings at the centre of the home panel.
struct ReactorView: View {
    let status: JarvisStatus
    var size: CGFloat = 240

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: status == .ready)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let color = Theme.color(for: status)
            let speed = Self.speed(for: status)
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 1).frame(width: size, height: size)
                Circle()
                    .trim(from: 0.0, to: 0.72)
                    .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 10, lineCap: .butt, dash: [2, 5]))
                    .frame(width: size * 0.88, height: size * 0.88)
                    .rotationEffect(.degrees(t * 40 * speed))
                Circle()
                    .trim(from: 0.1, to: 0.45)
                    .stroke(Theme.amber.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: size * 0.74, height: size * 0.74)
                    .rotationEffect(.degrees(-t * 60 * speed))
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 2)
                    .frame(width: size * 0.6, height: size * 0.6)
                    .scaleEffect(status == .listening || status == .speaking ? 1 + 0.04 * sin(t * 6) : 1)
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: size * 0.3))
                    .frame(width: size * 0.6, height: size * 0.6)
                Text("J.A.R.V.I.S.")
                    .font(.system(size: size * 0.08, weight: .semibold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .shadow(color: color, radius: 8)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func speed(for status: JarvisStatus) -> Double {
        switch status {
        case .thinking, .working: 1.6
        case .listening, .speaking: 1.0
        default: 0.25
        }
    }
}
