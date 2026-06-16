import SwiftUI

/// Thin SwiftUI view rendered inside the floating HUD panel.
/// Reads directly from `DictationCoordinator` — no business logic here.
struct HUDView: View {

    let coordinator: DictationCoordinator

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .animation(.easeInOut(duration: 0.15), value: coordinator.state)
            .animation(.easeInOut(duration: 0.15), value: coordinator.activeNotice)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .recording:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                recordingTranscript
                    .font(.system(.body, design: .rounded))
                    .lineLimit(3)
                    .frame(maxWidth: 320, alignment: .leading)
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

    /// Live transcript while recording: finalized text at full opacity, volatile
    /// (provisional) text rendered with `.secondary` foreground for the dimmed
    /// effect spec'd in PRODUCT_SPEC. Falls back to "Listening…" when both empty.
    @ViewBuilder
    private var recordingTranscript: some View {
        let finalized = coordinator.finalizedTranscript
        let volatile = coordinator.volatileText
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
