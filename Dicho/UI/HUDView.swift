import SwiftUI

/// What the HUD card should render for one frame — decoupled from the live
/// `DictationCoordinator` so the card can be previewed and the mapping
/// unit-tested in every state without running the pipeline.
enum HUDPhase: Equatable {
    case recording(finalized: String, volatile: String, showTranscript: Bool, isRaw: Bool)
    case transcribing
    case cleaning
    case inserting
    case notice(DictationNotice)
}

/// Thin adapter: observes `DictationCoordinator` / `AppSettings`, maps them to a
/// pure `HUDPhase`, and renders the `HUDCard`. No visual logic lives here.
struct HUDView: View {

    let coordinator: DictationCoordinator
    let settings: AppSettings

    var body: some View {
        if let phase = Self.phase(
            state: coordinator.state,
            finalized: coordinator.finalizedTranscript,
            volatile: coordinator.volatileText,
            notice: coordinator.activeNotice,
            hudStyle: settings.hudStyle,
            isRawMode: settings.isRawMode
        ) {
            HUDCard(phase: phase)
        }
    }

    /// Pure mapping from coordinator + settings to the card's render phase.
    /// `nil` means there is nothing to show (idle with no active notice).
    static func phase(
        state: DictationState,
        finalized: String,
        volatile: String,
        notice: DictationNotice?,
        hudStyle: HUDStyle,
        isRawMode: Bool
    ) -> HUDPhase? {
        switch state {
        case .recording:
            return .recording(
                finalized: finalized,
                volatile: volatile,
                showTranscript: hudStyle == .fullTranscript,
                isRaw: isRawMode)
        case .transcribing: return .transcribing
        case .cleaning:     return .cleaning
        case .inserting:    return .inserting
        case .idle:         return notice.map(HUDPhase.notice)
        }
    }
}

/// The dark Liquid Glass card. Pure function of its `HUDPhase`.
struct HUDCard: View {

    let phase: HUDPhase

    /// Fixed width of the transcript column while recording, so every recording
    /// state (empty, short, long) keeps a consistent width and the pill doesn't
    /// resize as words stream. Only the pipeline/notice pills hug their content.
    private static let transcriptWidth: CGFloat = 340
    /// Transcript grows with content up to this many lines, then scrolls
    /// pinned to the newest text. One line is the resting size.
    private static let maxVisibleLines: CGFloat = 3
    private static let cornerRadius: CGFloat = 18
    /// Deep tint applied to the glass so it reads as its own dark surface.
    private static let glassTint = Color(.sRGB, red: 0.10, green: 0.11, blue: 0.18, opacity: 1)
    /// Fixed dark scrim drawn over the glass so the HUD renders dark on every
    /// frame independent of window appearance (forcing the panel appearance
    /// did not stick — the material followed the system appearance). Kept high
    /// enough that the glass's *variable* contribution (which changes as the
    /// material samples its backdrop on the first frames) is a small fraction
    /// of the card — otherwise the initial frosted-light frame flashes before
    /// settling dark, worst over dark backgrounds.
    private static let scrimOpacity: Double = 0.72
    /// The recording mic is deliberately larger — it signals "listening now".
    private static let micFont = Font.title
    /// All non-recording status glyphs share this size so only the mic stands out.
    private static let statusIconFont = Font.title2

    /// Measured height of a single transcript line, used to derive the scroll
    /// cap deterministically regardless of font metrics / Dynamic Type.
    @State private var lineHeight: CGFloat = 0
    /// Measured natural height of the current transcript content.
    @State private var contentHeight: CGFloat = 0

    private var transcriptFont: Font { .system(.body, design: .rounded) }
    private var labelFont: Font { .system(.body, design: .rounded) }

    /// Squircle used for the glass material, the rim-light hairline, and the
    /// shadow so they stay aligned. `.continuous` matches Apple's corners.
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .foregroundStyle(.white)   // light text/symbols on the dark card
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            // Dark scrim over the glass → guaranteed-dark surface; the glass
            // material behind it supplies the blur/refraction.
            .background(Color.black.opacity(Self.scrimOpacity), in: cardShape)
            .glassEffect(.regular.tint(Self.glassTint), in: cardShape)
            .overlay(rimHighlight)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            // Top-anchored: the card drops down from just below the screen's
            // top edge, where the panel is positioned (M11, 11.2).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // No cross-fade between phases: animating the card across state
            // changes re-composited the glass mid-transition, reading as a
            // light→dark flicker. State changes now snap.
    }

    /// A thin gradient stroke — bright along the top edge fading to clear, with
    /// a soft backlight along the bottom — simulating light on a glass rim.
    private var rimHighlight: some View {
        cardShape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.55), location: 0.0),
                    .init(color: .white.opacity(0.12), location: 0.35),
                    .init(color: .clear,               location: 0.6),
                    .init(color: .white.opacity(0.22), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 1
        )
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case let .recording(finalized, volatile, showTranscript, isRaw):
            HStack(alignment: .top, spacing: 10) {
                // Pulsing red mic is the at-a-glance recording affordance (M11, 11.1).
                Image(systemName: "mic.fill")
                    .font(Self.micFont)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)

                if showTranscript {
                    recordingTranscript(finalized: finalized, volatile: volatile)
                }

                if isRaw { rawBadge }
            }
        case .transcribing:
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble")   // speech → text (transcription)
                    .font(Self.statusIconFont)
                    .foregroundStyle(.white)
                Text("Transcribing…").font(labelFont)
            }
        case .cleaning:
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(Self.statusIconFont)
                    .foregroundStyle(.white)   // neutral in-progress; color reserved for outcomes
                Text("Cleaning up…").font(labelFont)
            }
        case .inserting:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(Self.statusIconFont)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)   // checkmark, circle — success
                Text("Inserting…").font(labelFont)
            }
        case let .notice(notice):
            // Same shape as the pipeline states: icon + single-line label, the
            // pill hugging its content and centered (no fixed width).
            HStack(spacing: 10) {
                noticeIcon(for: notice)
                    .font(Self.statusIconFont)
                Text(notice.displayText)
                    .font(labelFont)
                    .lineLimit(1)
            }
        }
    }

    private var rawBadge: some View {
        Text("RAW")
            .font(.system(.caption2, design: .monospaced).bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.orange, in: Capsule())
    }

    /// Notice icon, in amber to read as "attention." Two notices get a
    /// dedicated glyph that tells their story; the rest share a generic info
    /// badge. Palette rendering keeps the inner glyph of `.fill` symbols
    /// visible on the dark card.
    @ViewBuilder
    private func noticeIcon(for notice: DictationNotice) -> some View {
        switch notice {
        case .nothingHeard:
            Image(systemName: "waveform.slash")   // no speech captured
                .foregroundStyle(.orange)
        case .insertionFailed:
            Image(systemName: "doc.on.clipboard.fill")   // on the clipboard — paste manually
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .orange)
        default:
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .orange)
        }
    }

    /// Live transcript while recording: finalized text at full opacity, volatile
    /// (provisional) text dimmed. Falls back to "Listening…" when both empty.
    ///
    /// The scroll region grows with the content from one line up to
    /// `maxVisibleLines`; past that it stays fixed and `defaultScrollAnchor(.bottom)`
    /// keeps the newest text visible (M11, 11.3). `min(contentHeight, cap)` is
    /// what makes the box hug short text instead of floating it in a tall frame.
    private func recordingTranscript(finalized: String, volatile: String) -> some View {
        let unit = lineHeight > 0 ? lineHeight : 18   // sane default before first measure
        let cappedHeight = min(max(contentHeight, unit), unit * Self.maxVisibleLines)
        return ScrollView {
            transcriptText(finalized: finalized, volatile: volatile)
                .font(transcriptFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(width: Self.transcriptWidth, height: cappedHeight)
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.never)
        .background(lineHeightSizer)
    }

    /// Invisible single-line probe whose measured height drives the scroll cap.
    /// Lives in a `background` with `fixedSize` so it never influences layout.
    private var lineHeightSizer: some View {
        Text("Ag")
            .font(transcriptFont)
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
    }

    @ViewBuilder
    private func transcriptText(finalized: String, volatile: String) -> some View {
        if finalized.isEmpty && volatile.isEmpty {
            Text("Listening…")
                .foregroundStyle(.white.opacity(0.6))
        } else {
            Text(transcriptAttributed(finalized: finalized, volatile: volatile))
        }
    }

    /// Builds the two-toned transcript string. `AttributedString` is used (in
    /// place of `Text + Text`, which is deprecated in macOS 26) so the two
    /// segments wrap as a single block of text.
    private func transcriptAttributed(finalized: String, volatile: String) -> AttributedString {
        var result = AttributedString()
        if !finalized.isEmpty {
            var f = AttributedString(finalized)
            f.foregroundColor = .white
            result.append(f)
        }
        if !finalized.isEmpty && !volatile.isEmpty {
            result.append(AttributedString(" "))
        }
        if !volatile.isEmpty {
            var v = AttributedString(volatile)
            v.foregroundColor = .white.opacity(0.55)
            result.append(v)
        }
        return result
    }
}

// MARK: - Previews

/// Renders the card in every state over a light backdrop (glass needs content
/// behind it). Use the preview tool / Xcode canvas to iterate without running
/// the app or the hotkey pipeline.
#Preview("HUD — all states") {
    let phases: [(String, HUDPhase)] = [
        ("Recording — empty",   .recording(finalized: "", volatile: "", showTranscript: true, isRaw: false)),
        ("Recording — text",    .recording(finalized: "Let's meet on Friday", volatile: " and grab", showTranscript: true, isRaw: false)),
        ("Recording — long",    .recording(finalized: "Compound interest is simpler than people make it sound; you earn interest on your interest and the curve gets steep over time.", volatile: " honestly", showTranscript: true, isRaw: true)),
        ("Recording — icon only", .recording(finalized: "", volatile: "", showTranscript: false, isRaw: false)),
        ("Transcribing",        .transcribing),
        ("Cleaning",            .cleaning),
        ("Inserting",           .inserting),
        ("Nothing heard",       .notice(.nothingHeard)),
        ("Insertion failed",    .notice(.insertionFailed)),
        ("Generic notice",      .notice(.cleanupUnavailable))
    ]
    return VStack(spacing: 14) {
        ForEach(phases, id: \.0) { label, phase in
            HStack(spacing: 12) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .trailing)
                HUDCard(phase: phase)
                    .frame(width: 560, height: 84, alignment: .top)
            }
        }
    }
    .padding(40)
    .frame(width: 780, height: 1060)
    .background(
        LinearGradient(colors: [.white, Color(.sRGB, red: 0.86, green: 0.88, blue: 0.92, opacity: 1)],
                       startPoint: .top, endPoint: .bottom)
    )
}

/// Simulates the real 600×240 panel canvas (red border) so the card's
/// horizontal centering within the panel can be verified — the actual on-screen
/// placement is the panel origin (HUDPresenter), which previews can't exercise.
#Preview("HUD — panel centering") {
    VStack(spacing: 24) {
        ForEach(["recording-empty", "notice", "transcribing"], id: \.self) { kind in
            let phase: HUDPhase = switch kind {
                case "recording-empty": .recording(finalized: "", volatile: "", showTranscript: true, isRaw: false)
                case "notice":          .notice(.nothingHeard)
                default:                .transcribing
            }
            HUDCard(phase: phase)
                .frame(width: 600, height: 240)   // exact panel size
                .border(.red)
        }
    }
    .padding(30)
    .frame(width: 660, height: 840)
    .background(Color(.sRGB, red: 0.10, green: 0.11, blue: 0.13, opacity: 1))   // dark bg
}
