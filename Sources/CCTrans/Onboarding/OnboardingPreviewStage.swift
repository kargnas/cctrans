import SwiftUI

// Right-hand preview stage: a dark, self-playing dramatization of ⌘C C →
// translation toast. This is the one onboarding-only exception to DESIGN.md's
// "no decorative gradients/motion" rule (the mock's confirmed dark stage), so the
// gradient and highlight colors are hardcoded here rather than tokenized.

// MARK: - Shared keycap (also used by the step 3 hint)

struct KeyCapView: View {
    let label: String
    var pressed: Bool = false
    var compact: Bool = false

    private var side: CGFloat { compact ? 22 : 34 }
    private var radius: CGFloat { compact ? 6 : 10 }
    private var lipDepth: CGFloat { compact ? 2 : 3 }

    var body: some View {
        ZStack {
            // The bottom "lip" gives the cap depth; it thins as the key presses down.
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.black.opacity(0.28))
                .offset(y: pressed ? 1 : lipDepth)
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.96), Color(white: 0.82)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                )
                .overlay(
                    Text(label)
                        .font(.system(size: compact ? 11 : 15, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.75))
                )
                .offset(y: pressed ? lipDepth : 0)
        }
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.1), value: pressed)
    }
}

// MARK: - One-shot confetti

struct ConfettiView: View {
    @State private var start = Date()
    private let count = 6
    private let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .yellow]

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            Canvas { ctx, size in
                guard elapsed <= 0.8 else { return }
                let progress = elapsed / 0.8
                for index in 0 ..< count {
                    let spread = (Double(index) - Double(count - 1) / 2) * 16
                    let x = size.width / 2 + spread * (0.4 + progress)
                    let lift = size.height * 0.9 * sin(progress * .pi / 2)
                    let gravity = 34 * progress * progress
                    let y = size.height - lift + gravity
                    let rect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                    ctx.opacity = 1 - progress
                    ctx.fill(Path(ellipseIn: rect), with: .color(palette[index % palette.count]))
                }
            }
        }
    }
}

// MARK: - Preview stage

struct OnboardingPreviewStage: View {
    @ObservedObject var model: OnboardingFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x0e1420), Color(hex: 0x1a2233), Color(hex: 0x232c45)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            stageContent
                .padding(24)

            VStack {
                Spacer()
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .id(model.step)
                    .transition(.opacity)
                    .padding(.bottom, 18)
            }
        }
        .frame(width: 340)
        .animation(.easeInOut(duration: 0.4), value: model.step)
    }

    @ViewBuilder
    private var stageContent: some View {
        if model.step == .tryIt {
            TryTurnView(succeeded: model.hasTranslated, reduceMotion: reduceMotion)
                .transition(.opacity)
        } else if reduceMotion {
            // Static completed frame instead of the loop.
            PreviewScene(phase: .completed, providerTitle: model.selectedProvider.title)
                .transition(.opacity)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(startDate)
                    .truncatingRemainder(dividingBy: 7)
                PreviewScene(phase: .at(t), providerTitle: model.selectedProvider.title)
            }
            .transition(.opacity)
        }
    }

    private var caption: String {
        switch model.step {
        case .permissions: "This is what you're unlocking"
        case .model: "Preview uses your selected model"
        case .tryIt: "Now it's your turn — try it below"
        }
    }
}

// MARK: - Simulated scene

/// Every transform in the loop, computed from the loop time `t` (or fixed for the
/// reduced-motion / completed frame). Keeping them in one value lets the animated
/// and static paths render the exact same subtree.
private struct PreviewPhase {
    var highlight: Double
    var cmdPressed: Bool
    var c1Pressed: Bool
    var c2Pressed: Bool
    var toastOffsetY: Double
    var toastScale: Double
    var toastOpacity: Double
    var typeProgress: Double

    static let completed = PreviewPhase(
        highlight: 1, cmdPressed: false, c1Pressed: false, c2Pressed: false,
        toastOffsetY: 0, toastScale: 1, toastOpacity: 1, typeProgress: 1
    )

    // Timing table lifted straight from the design spec (§6).
    static func at(_ t: Double) -> PreviewPhase {
        let entrance = easeOutBack(clamp01((t - 2.1) / 0.4))   // 2.1–2.5 spring-in
        let exit = pow(clamp01((t - 6.2) / 0.4), 2)            // 6.2–6.6 ease-in out
        return PreviewPhase(
            highlight: smoothstep(0.4, 1.1, t),
            cmdPressed: t >= 1.4 && t <= 2.35,
            c1Pressed: t >= 1.55 && t <= 1.70,
            c2Pressed: t >= 1.85 && t <= 2.00,
            toastOffsetY: 90 * (1 - entrance) + 90 * exit,
            toastScale: 0.92 + 0.08 * entrance,
            toastOpacity: entrance * (1 - exit),
            typeProgress: clamp01((t - 2.5) / 1.1)             // 2.5–3.6 typing reveal
        )
    }
}

private struct PreviewScene: View {
    let phase: PreviewPhase
    let providerTitle: String

    var body: some View {
        VStack(spacing: 20) {
            // Source line with the highlight sweep behind it.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: 0x007aff).opacity(0.35))
                    .scaleEffect(x: phase.highlight, anchor: .leading)
                Text("The quick brown fox…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 4)
            }
            .fixedSize()

            // ⌘ + C C — the confirmed mock reading: hold ⌘, tap C twice.
            HStack(spacing: 6) {
                KeyCapView(label: "⌘", pressed: phase.cmdPressed)
                Text("+")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
                KeyCapView(label: "C", pressed: phase.c1Pressed)
                KeyCapView(label: "C", pressed: phase.c2Pressed)
            }

            simulatedToast
                .offset(y: phase.toastOffsetY)
                .scaleEffect(phase.toastScale)
                .opacity(phase.toastOpacity)
        }
    }

    private var simulatedToast: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The quick brown fox jumps over the lazy dog")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Text("빠른 갈색 여우가 게으른 개를 뛰어넘는다")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                // Left-to-right typing reveal.
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle().frame(width: geo.size.width * phase.typeProgress)
                    }
                }
            HStack(spacing: 6) {
                MiniPill(text: "EN → KO")
                MiniPill(text: providerTitle)
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

private struct MiniPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }
}

// MARK: - Step 3 "your turn" state

private struct TryTurnView: View {
    let succeeded: Bool
    let reduceMotion: Bool
    @State private var pulseStart = Date()

    var body: some View {
        ZStack {
            if succeeded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else if reduceMotion {
                staticRing
            } else {
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSince(pulseStart)
                    // 2.4s ease-out pulse: a ring that expands and fades, repeating.
                    let cycle = elapsed.truncatingRemainder(dividingBy: 2.4) / 2.4
                    pulsingRing(progress: cycle)
                }
            }
            VStack {
                Spacer()
                Text(succeeded ? "Nice!" : "Your turn")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 70)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: succeeded)
    }

    private var staticRing: some View {
        Circle()
            .stroke(Color(hex: 0x007aff).opacity(0.5), lineWidth: 3)
            .frame(width: 90, height: 90)
    }

    private func pulsingRing(progress: Double) -> some View {
        let eased = 1 - pow(1 - progress, 2) // ease-out
        return ZStack {
            Circle()
                .stroke(Color(hex: 0x007aff), lineWidth: 3)
                .frame(width: 60, height: 60)
            Circle()
                .stroke(Color(hex: 0x007aff).opacity(1 - eased), lineWidth: 2)
                .frame(width: 60 + 60 * eased, height: 60 + 60 * eased)
        }
    }
}

// MARK: - Local hex color (onboarding stage only)

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

// MARK: - Easing helpers

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

private func easeOutBack(_ x: Double) -> Double {
    let c1 = 1.70158
    let c3 = c1 + 1
    let t = clamp01(x)
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
}
