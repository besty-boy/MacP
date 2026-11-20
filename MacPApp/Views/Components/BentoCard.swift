import SwiftUI

/// Reusable Apple HIG "Liquid Glass" Bento card container.
/// Uses native macOS 26+ `.glassEffect` when available, with an adaptive `.regularMaterial`
/// + specular glass rim fallback on macOS 14–15.
struct BentoCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let tint: Color?
    private let content: Content

    init(
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 14,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        let base = content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)

        if #available(macOS 26.0, *) {
            base
                .background {
                    if let tint {
                        shape.fill(tint.opacity(0.08))
                    }
                }
                .glassEffect(.regular, in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.22 : 0.65),
                                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.16)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
        } else {
            base
                .background(.regularMaterial, in: shape)
                .background {
                    if let tint {
                        shape.fill(tint.opacity(0.08))
                    }
                }
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.18 : 0.65),
                                Color.white.opacity(colorScheme == .dark ? 0.05 : 0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06),
                    radius: 8,
                    x: 0,
                    y: 3
                )
        }
    }
}

/// Animated circular telemetry ring for live CPU, RAM, Battery, and Disk gauges.
struct TelemetryRingView: View {
    let progress: Double // 0.0 ... 1.0
    let color: Color
    let centerText: String
    var diameter: CGFloat = 38

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: 4.5)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    color.gradient,
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.45), value: clamped)

            Text(centerText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(width: diameter, height: diameter)
    }
}
