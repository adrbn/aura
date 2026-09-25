import ActivityKit
import SwiftUI
import WidgetKit

/// A release being fetched: which step it's at, and how far along — on the Lock Screen and in
/// the Dynamic Island.
struct ReleaseFetchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReleaseFetchAttributes.self) { context in
            lockScreen(context)
                .padding(16)
                .background(.ultraThinMaterial)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    stepIcon(context.state.step)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(context.state.headline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    progress(context.state)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
            } compactLeading: {
                stepIcon(context.state.step)
            } compactTrailing: {
                compactValue(context.state)
            } minimal: {
                stepIcon(context.state.step)
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<ReleaseFetchAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                stepIcon(context.state.step)
                    .font(.title2)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(context.attributes.title) · \(context.attributes.artist)")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(context.state.headline)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    // Frozen figures once the app sleeps; the countdown beside them runs on.
                    if context.isStale {
                        Text("Open Aura for the latest")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !context.state.detail.isEmpty {
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let end = context.state.waitEnd, end > .now {
                    Text(timerInterval: Date.now...end, countsDown: true)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56, alignment: .trailing)
                }
            }
            steps(context.state)
        }
    }

    /// The four steps as a segmented bar: done ones full, the current one filling.
    private func steps(_ state: ReleaseFetchAttributes.ContentState) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<ReleaseFetchAttributes.steps, id: \.self) { index in
                Group {
                    if state.step < 0 {
                        Capsule().fill(Color.red.opacity(index == 0 ? 0.8 : 0.25))
                    } else if index < state.step || state.step == ReleaseFetchAttributes.steps - 1 {
                        Capsule().fill(Color.pink)
                    } else if index == state.step {
                        progress(state)
                    } else {
                        Capsule().fill(Color.primary.opacity(0.15))
                    }
                }
                .frame(height: 5)
            }
        }
    }

    /// The current step's own bar: the download's share, or the server's expected wait —
    /// which runs on by itself, so it keeps moving while the app sleeps.
    @ViewBuilder
    private func progress(_ state: ReleaseFetchAttributes.ContentState) -> some View {
        if let start = state.waitStart, let end = state.waitEnd, end > start {
            ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(.pink)
        } else if let value = state.progress {
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .tint(.pink)
        } else {
            Capsule().fill(Color.pink.opacity(0.45))
        }
    }

    /// Time left while there's an estimate, since it keeps running with the app asleep; the
    /// download's share when there isn't one yet.
    @ViewBuilder
    private func compactValue(_ state: ReleaseFetchAttributes.ContentState) -> some View {
        if state.step == 1 || state.step == 2, let end = state.waitEnd, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true)
                .font(.caption2.monospacedDigit())
                .frame(maxWidth: 44)
        } else if state.step == 1, let value = state.progress {
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.caption2.monospacedDigit())
        } else {
            Image(systemName: state.step == 3 ? "checkmark" : "ellipsis")
                .font(.caption2)
        }
    }

    private func stepIcon(_ step: Int) -> some View {
        let name: String = switch step {
        case 0: "magnifyingglass"
        case 1: "arrow.down.circle"
        case 2: "tray.and.arrow.down"
        case 3: "checkmark.circle.fill"
        default: "exclamationmark.triangle"
        }
        return Image(systemName: name)
            .foregroundStyle(step < 0 ? Color.orange : Color.pink)
    }
}
