import SwiftUI

/// Thin SwiftUI view rendered inside the floating HUD panel.
/// Reads directly from `DictationCoordinator` and `AppSettings` — no business logic here.
struct HUDView: View {

    let coordinator: DictationCoordinator
    let settings: AppSettings

    /// Max height of the scrolling transcript region while recording. Content
    /// taller than this scrolls, pinned to the newest text (M11, 11.3).
    private static let transcriptMaxHeight: CGFloat = 140

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(recordingAccentBorder)
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            // Top-anchored: the card drops down from just below the screen's
            // top edge, where the panel is positioned (M11, 11.2).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.15), value: coordinator.state)
            .animation(.easeInOut(duration: 0.15), value: coordinator.activeNotice)
    }

    /// A high-contrast accent border around the card while recording so an
    /// active dictation is unmistakable at a glance (M11, 11.1). Paired with
    /// the pulsing mic glyph inside the card.
    @ViewBuilder
    private var recordingAccentBorder: some View {
        if coordinator.state == .recording {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.red, lineWidth: 3)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .recording:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)

                if settings.hudStyle == .fullTranscript {
                    recordingTranscript
                        .font(.system(.title3, design: .rounded))
                        .frame(maxWidth: 460, alignment: .leading)
                        .frame(maxHeight: Self.transcriptMaxHeight)
                }

                if settings.isRawMode { rawBadge }
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Transcribing…")
                    .font(.system(.body, design: .rounded))
            }
        case .cleaning:
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Cleaning up…")
                    .font(.system(.body, design: .rounded))
            }
        case .inserting:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Inserting…")
                    .font(.system(.body, design: .rounded))
            }
        case .idle: idleContent
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

    /// Live transcript while recording: finalized text at full opacity, volatile
    /// (provisional) text rendered with `.secondary` foreground for the dimmed
    /// effect spec'd in PRODUCT_SPEC. Falls back to "Listening…" when both empty.
    ///
    /// Wrapped in a bottom-anchored `ScrollView`: as segments arrive and the
    /// content grows past `transcriptMaxHeight`, `defaultScrollAnchor(.bottom)`
    /// repositions to the newest text instead of sticking at the top (M11, 11.3).
    private var recordingTranscript: some View {
        let finalized = coordinator.finalizedTranscript
        let volatile  = coordinator.volatileText
        return ScrollView {
            transcriptText(finalized: finalized, volatile: volatile)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func transcriptText(finalized: String, volatile: String) -> some View {
        if finalized.isEmpty && volatile.isEmpty {
            Text("Listening…")
                .foregroundStyle(.secondary)
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
            f.foregroundColor = .primary
            result.append(f)
        }
        if !finalized.isEmpty && !volatile.isEmpty {
            result.append(AttributedString(" "))
        }
        if !volatile.isEmpty {
            var v = AttributedString(volatile)
            v.foregroundColor = .secondary
            result.append(v)
        }
        return result
    }

    @ViewBuilder
    private var idleContent: some View {
        if let notice = coordinator.activeNotice {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                Text(notice.displayText)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        } else {
            EmptyView()
        }
    }
}
