import AppKit
import SwiftUI

enum OnboardingMotion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func duration(_ duration: Double) -> Double {
        reduceMotion ? 0 : duration
    }
}

struct OnboardingBackground: View {
    var body: some View {
        NinoPalette.ink.ignoresSafeArea()
    }
}

struct OnboardingGoldBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 40 : 1.0 / 30.0)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 40) / 40
            let drift = CGFloat(sin(phase * .pi * 2) * 42)

            ZStack {
                NinoPalette.ink
                RadialGradient(
                    colors: [NinoPalette.gold.opacity(0.72), NinoPalette.gold.opacity(0)],
                    center: .center,
                    startRadius: 20,
                    endRadius: 430
                )
                .scaleEffect(1.25)
                .offset(x: drift, y: -110)
                .blur(radius: 75)
                LinearGradient(
                    colors: [NinoPalette.goldDim.opacity(0.38), NinoPalette.ink.opacity(0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

extension AnyTransition {
    static let ninoOnboardingStep = AnyTransition.opacity.combined(with: .offset(y: 8))
}

enum OnboardingLayout {
    static let chromeMaxWidth: CGFloat = 560
    static let horizontalPadding: CGFloat = 48
    static let headerTopPadding: CGFloat = 52
    static let bottomPadding: CGFloat = 28
}

struct OnboardingHeroHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(NinoPalette.gold2)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(NinoPalette.surface2)
                )

            VStack(spacing: 8) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(NinoPalette.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 14))
                    .foregroundColor(NinoPalette.creamDim)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OnboardingProgressBadge: View {
    let currentStep: Int
    let totalSteps: Int

    private var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStep) / Double(totalSteps)
    }

    var body: some View {
        SegmentedProgressRing(
            totalSegments: totalSteps,
            filledSegments: currentStep,
            progress: progress
        )
    }
}

enum OnboardingBottomBarPlacement {
    case split
    case centered
}

struct OnboardingBottomBar: View {
    let leadingTitle: String?
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    var placement: OnboardingBottomBarPlacement = .split
    let onLeading: (() -> Void)?
    let onPrimary: () -> Void

    private enum Metrics {
        static let controlButtonWidth: CGFloat = 132
        static let buttonHeight: CGFloat = 42
        static let primaryButtonHorizontalPadding: CGFloat = 20
    }

    var body: some View {
        HStack(spacing: 0) {
            switch placement {
            case .split:
                leadingSlot
                Spacer(minLength: 0)
            case .centered:
                Spacer(minLength: 0)
            }

            primaryButton

            if case .centered = placement {
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if let leadingTitle, let onLeading {
            Button(action: onLeading) {
                Text(LocalizedStringKey(leadingTitle))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(NinoPalette.cream)
                    .frame(width: Metrics.controlButtonWidth, height: Metrics.buttonHeight)
                    .background(NinoPalette.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            NinoPalette.ink.opacity(0)
                .frame(width: Metrics.controlButtonWidth, height: Metrics.buttonHeight)
                .accessibilityHidden(true)
        }
    }

    private var primaryButton: some View {
        Button(action: onPrimary) {
            Text(LocalizedStringKey(primaryTitle))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(NinoPalette.ink)
                .padding(.horizontal, Metrics.primaryButtonHorizontalPadding)
                .frame(minWidth: Metrics.controlButtonWidth, minHeight: Metrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(isPrimaryEnabled ? NinoPalette.gold2 : NinoPalette.goldDim)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isPrimaryEnabled)
    }
}

struct OnboardingStepScreen<Content: View, BottomBar: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let contentMaxWidth: CGFloat
    let showsHeader: Bool
    let contentYOffset: CGFloat
    let content: Content
    let bottomBar: BottomBar

    init(
        stage: OnboardingStage,
        contentMaxWidth: CGFloat,
        showsHeader: Bool = true,
        contentYOffset: CGFloat = 0,
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottomBar: () -> BottomBar
    ) {
        self.systemImage = stage.systemImage
        self.title = stage.title
        self.subtitle = stage.subtitle
        self.contentMaxWidth = contentMaxWidth
        self.showsHeader = showsHeader
        self.contentYOffset = contentYOffset
        self.content = content()
        self.bottomBar = bottomBar()
    }

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        contentMaxWidth: CGFloat,
        showsHeader: Bool = true,
        contentYOffset: CGFloat = 0,
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottomBar: () -> BottomBar
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.contentMaxWidth = contentMaxWidth
        self.showsHeader = showsHeader
        self.contentYOffset = contentYOffset
        self.content = content()
        self.bottomBar = bottomBar()
    }

    var body: some View {
        if showsHeader {
            VStack(spacing: 0) {
                OnboardingHeroHeader(
                    systemImage: systemImage,
                    title: title,
                    subtitle: subtitle
                )
                .frame(maxWidth: OnboardingLayout.chromeMaxWidth)
                .padding(.top, OnboardingLayout.headerTopPadding)

                Spacer(minLength: 0)

                content
                    .frame(maxWidth: contentMaxWidth)
                    .offset(y: contentYOffset)

                Spacer(minLength: 0)

                bottomBar
                    .frame(maxWidth: OnboardingLayout.chromeMaxWidth)
                    .padding(.bottom, OnboardingLayout.bottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, OnboardingLayout.horizontalPadding)
        } else {
            ZStack {
                content
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .offset(y: contentYOffset)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    bottomBar
                        .frame(maxWidth: OnboardingLayout.chromeMaxWidth)
                }
                .padding(.bottom, OnboardingLayout.bottomPadding)
            }
            .padding(.horizontal, OnboardingLayout.horizontalPadding)
        }
    }
}

private struct SegmentedProgressRing: View {
    let totalSegments: Int
    let filledSegments: Int
    let progress: Double

    private let segmentGap: Double = 0.035
    private let lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            ForEach(0..<totalSegments, id: \.self) { index in
                Circle()
                    .trim(from: segmentStart(index), to: segmentEnd(index))
                    .stroke(
                        index < filledSegments ? NinoPalette.gold : NinoPalette.surface3,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            Text(progress, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NinoPalette.cream)
        }
        .frame(width: 46, height: 46)
    }

    private func segmentStart(_ index: Int) -> CGFloat {
        guard totalSegments > 0 else { return 0 }
        return CGFloat(Double(index) / Double(totalSegments) + segmentGap / 2)
    }

    private func segmentEnd(_ index: Int) -> CGFloat {
        guard totalSegments > 0 else { return 0 }
        return CGFloat(Double(index + 1) / Double(totalSegments) - segmentGap / 2)
    }
}

struct NinoPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(NinoPalette.ink)
            .padding(.horizontal, 22)
            .frame(height: 42)
            .background(NinoPalette.gold2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct NinoChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isSelected ? NinoPalette.ink : NinoPalette.cream)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(isSelected ? NinoPalette.gold2 : NinoPalette.surface3, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
