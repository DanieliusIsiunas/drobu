import SwiftUI

// MARK: - Chroma Sweep Border Modifier

/// A one-shot rainbow gradient border animation that sweeps diagonally across
/// the element then settles into a solid highlight color. Inspired by diabrowser.com.
///
/// Uses TimelineView for smooth frame-by-frame rendering — SwiftUI's built-in
/// animation system can't smoothly interpolate gradient stop positions.
struct ChromaSweepBorder: ViewModifier {
    let isActive: Bool
    let borderWidth: CGFloat
    let cornerRadius: CGFloat
    let duration: Double
    let restingColor: Color

    @State private var animationStart: Date? = nil
    @State private var showRestingBorder: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay { restingBorderView }
            .overlay { animatedBorderView }
            .onAppear {
                if isActive {
                    animationStart = Date()
                }
            }
            .onChange(of: isActive) { oldVal, newVal in
                if newVal && !oldVal {
                    showRestingBorder = false
                    animationStart = Date()
                } else if !newVal && oldVal {
                    animationStart = nil
                    showRestingBorder = false
                }
            }
    }

    // MARK: - Resting Border (solid color after sweep, with matching glow)

    private static let restingGlow: CGFloat = 1.5

    @ViewBuilder
    private var restingBorderView: some View {
        if showRestingBorder {
            Rectangle()
                .fill(restingColor)
                .mask {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(lineWidth: borderWidth + Self.restingGlow * 2)
                }
                .blur(radius: Self.restingGlow)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Animated Border (TimelineView driven)

    @ViewBuilder
    private var animatedBorderView: some View {
        if animationStart != nil {
            TimelineView(.animation(minimumInterval: nil, paused: false)) { context in
                let progress = currentProgress(at: context.date)
                if let progress {
                    gradientBorderView(progress: progress)
                }
            }
        }
    }

    /// Compute eased progress (0→1) from elapsed time, or nil if done.
    private func currentProgress(at now: Date) -> Double? {
        guard let start = animationStart else { return nil }
        let elapsed = now.timeIntervalSince(start)
        let linear = min(elapsed / duration, 1.0)

        if linear >= 1.0 {
            DispatchQueue.main.async {
                animationStart = nil
                if isActive { showRestingBorder = true }
            }
            // Return 1.0 (not nil) so the animated border still draws this frame,
            // overlapping seamlessly with the resting border on the next frame.
            return 1.0
        }

        // Ease-in-out curve: 3t² - 2t³
        return 3 * linear * linear - 2 * linear * linear * linear
    }

    private func gradientBorderView(progress: Double) -> some View {
        let glowAmount = Self.restingGlow

        return sweepGradient(progress: progress)
            .mask {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(lineWidth: borderWidth + CGFloat(glowAmount) * 2)
            }
            .blur(radius: CGFloat(glowAmount))
            .allowsHitTesting(false)
    }

    // MARK: - Diagonal Sweep Gradient (left-to-right from top-left)

    private func sweepGradient(progress: Double) -> LinearGradient {
        let startPoint = UnitPoint(
            x: -0.3 + progress * 1.6,
            y: -0.3 + progress * 1.6
        )
        let endPoint = UnitPoint(
            x: startPoint.x - 0.4,
            y: startPoint.y - 0.4
        )

        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .chromaBlue, location: 0.10),
                .init(color: .chromaLavender, location: 0.25),
                .init(color: .chromaAmber, location: 0.40),
                .init(color: .chromaRedOrange, location: 0.55),
                .init(color: .chromaPink, location: 0.70),
                .init(color: restingColor, location: 0.85),
                .init(color: restingColor, location: 1.0),
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }
}

// MARK: - Rainbow Palette Colors

extension Color {
    static let chromaPink = Color(red: 198/255, green: 121/255, blue: 196/255)
    static let chromaRedOrange = Color(red: 250/255, green: 61/255, blue: 29/255)
    static let chromaAmber = Color(red: 255/255, green: 176/255, blue: 5/255)
    static let chromaLavender = Color(red: 225/255, green: 225/255, blue: 254/255)
    static let chromaBlue = Color(red: 3/255, green: 88/255, blue: 247/255)
}

// MARK: - View Extension

extension View {
    func chromaSweepBorder(
        isActive: Bool,
        borderWidth: CGFloat = 2,
        cornerRadius: CGFloat = 4,
        duration: Double = 0.6,
        restingColor: Color = .accentColor
    ) -> some View {
        modifier(ChromaSweepBorder(
            isActive: isActive,
            borderWidth: borderWidth,
            cornerRadius: cornerRadius,
            duration: duration,
            restingColor: restingColor
        ))
    }
}
