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
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .recording:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text(coordinator.volatileText.isEmpty ? "Listening…" : coordinator.volatileText)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(3)
                    .frame(maxWidth: 280, alignment: .leading)
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
        case .idle:
            EmptyView()
        }
    }
}
