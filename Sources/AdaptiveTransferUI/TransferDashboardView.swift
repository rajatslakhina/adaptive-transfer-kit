#if canImport(SwiftUI)
import Foundation
import SwiftUI
import AdaptiveTransfer

/// Drives the comparison.
///
/// Every decision it makes lives in `TransferProfile`, in the core module,
/// where the test target can reach it — see that type's note on why. This class
/// is glue: it holds the slider's value and republishes.
@MainActor
public final class TransferDashboardModel: ObservableObject {

    @Published public private(set) var comparison: CapacityExperiment.Comparison
    @Published public private(set) var invariantReport: LimiterInvariantCheck.Report

    /// Capacity the server drops to. Bound to the slider.
    @Published public var degradedCapacity: Int {
        didSet {
            guard degradedCapacity != oldValue else { return }
            comparison = profile.compare(degradedCapacity: degradedCapacity)
        }
    }

    public let profile: TransferProfile

    public init(profile: TransferProfile = .photoUpload) {
        self.profile = profile
        let initialCapacity = profile.defaultDegradedCapacity
        self.degradedCapacity = initialCapacity
        // Computed eagerly, so the first frame already has real numbers rather
        // than an empty state that fills in later.
        self.comparison = profile.compare(degradedCapacity: initialCapacity)
        self.invariantReport = LimiterInvariantCheck.run(GradientLimiter())
    }

    public var verdict: TransferProfile.Verdict { profile.verdict(for: comparison) }
}

/// Side-by-side: a fixed concurrency limit against a discovered one, on
/// identical conditions.
public struct TransferDashboardView: View {

    @StateObject private var model: TransferDashboardModel

    public init(profile: TransferProfile = .photoUpload) {
        _model = StateObject(wrappedValue: TransferDashboardModel(profile: profile))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    strategyCards
                    verdictCard
                    capacityControl
                    invariantSection
                }
                .padding(20)
            }
            .navigationTitle("Adaptive Transfer")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.profile.chunkCount) chunks · server capacity \(model.profile.serverCapacity), dropping to \(model.degradedCapacity) at \(model.profile.degradeAtMilliseconds) ms")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("The client is told nothing about the drop.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var strategyCards: some View {
        VStack(spacing: 12) {
            card(
                title: "Fixed limit of \(model.comparison.fixedLimit)",
                subtitle: "A number someone picked",
                result: model.comparison.fixed,
                tint: model.verdict == .fixedGuessHappenedToBeRight ? .green : .red
            )
            card(
                title: "Gradient limiter",
                subtitle: "Capacity discovered from latency",
                result: model.comparison.adaptive,
                tint: model.verdict == .fixedGuessHappenedToBeRight ? .orange : .green
            )
        }
    }

    private func card(
        title: String,
        subtitle: String,
        result: CapacityExperiment.Result,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                metric("p50", "\(result.medianLatencyMilliseconds) ms")
                metric("p95", "\(result.p95LatencyMilliseconds) ms")
                metric("p99", "\(result.p99LatencyMilliseconds) ms")
            }
            HStack(spacing: 14) {
                metric("completed", "\(result.completedChunks)/\(model.profile.chunkCount)")
                metric("shed", "\(result.droppedRequests)")
                metric("final limit", "\(result.finalLimit)")
            }
            latencyBar(result: result, tint: tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func latencyBar(result: CapacityExperiment.Result, tint: Color) -> some View {
        let worst = max(
            model.comparison.fixed.p95LatencyMilliseconds,
            model.comparison.adaptive.p95LatencyMilliseconds
        )
        // Guarded rather than divided: both p95s are zero whenever nothing
        // completed, and a NaN width is a crash inside SwiftUI's layout pass.
        let fraction = worst > 0
            ? Double(result.p95LatencyMilliseconds) / Double(worst)
            : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule().fill(tint).frame(width: max(2, geometry.size.width * fraction))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("p95 latency \(result.p95LatencyMilliseconds) milliseconds")
    }

    /// The honest reading, including the case where the guess wins.
    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.verdict {
            case .fixedLimitCollapsed:
                Text("The fixed limit never finished.").font(.subheadline).bold()
                Text("\(model.comparison.fixed.completedChunks) of \(model.profile.chunkCount) chunks landed, and \(model.comparison.fixed.droppedRequests) requests were shed doing it. Past the server's shedding threshold, over-guessing stops costing latency and starts costing the transfer.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .adaptiveWins:
                Text(String(format: "Fixed limit p95 is %.2f× the adaptive one.", model.comparison.p95Ratio))
                    .font(.subheadline).bold()
                Text(String(format: "It buys %.0f%% of the adaptive throughput for that.", model.comparison.throughputRatio * 100))
                    .font(.footnote).foregroundStyle(.secondary)
            case .fixedGuessHappenedToBeRight:
                Text("At this severity, the fixed guess wins.").font(.subheadline).bold()
                Text(String(format: "Its p95 is %.2f× the controller's, because the controller pays for probing and a guess that is already close does not. This is the honest half of the argument: a fixed limit is not always worse — it is unknowably wrong, and drag the slider left to see what the other side of that looks like.", model.comparison.p95Ratio))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var capacityControl: some View {
        let range = model.profile.degradedCapacityRange
        let bounds = Double(range.lowerBound)...Double(range.upperBound)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Degraded capacity: \(model.degradedCapacity)").font(.subheadline)
            Slider(
                value: Binding(
                    get: { Double(model.degradedCapacity) },
                    set: { model.degradedCapacity = Int($0.rounded()) }
                ),
                in: bounds,
                step: 1
            )
            .accessibilityLabel("Degraded server capacity")
            Text("Drag to change how hard the server degrades. Both strategies re-run against identical conditions on every change.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var invariantSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                model.invariantReport.passed ? "Limiter invariants hold" : "Limiter invariants violated",
                systemImage: model.invariantReport.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .font(.subheadline).bold()
            .foregroundStyle(model.invariantReport.passed ? .green : .red)

            Text("limit before congestion \(model.invariantReport.limitBeforeCongestion) → during \(model.invariantReport.limitDuringCongestion) → recovered \(model.invariantReport.limitAfterRecovery) → after a drop \(model.invariantReport.limitAfterDrop)")
                .font(.caption).foregroundStyle(.secondary)

            if !model.invariantReport.failures.isEmpty {
                Text("failed: " + model.invariantReport.failures.map(\.rawValue).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    TransferDashboardView()
}
#endif
