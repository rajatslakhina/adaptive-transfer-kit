#if canImport(SwiftUI)
import SwiftUI
import AdaptiveTransfer

/// The compiled-in defaults an app owns.
///
/// The library does not decide these; the app does, because chunk size and
/// concurrency ceiling are product decisions (how much of a metered connection
/// am I willing to spend, how long may a preemption take) rather than library
/// ones. The demo app constructs one of these and hands it in, which is also
/// the reason the app imports `AdaptiveTransfer` and not only this module.
public struct TransferProfile: Sendable, Equatable {
    public let name: String
    public let chunkCount: Int
    public let fixedLimit: Int
    public let serverCapacity: Int
    public let serviceTimeMilliseconds: Int

    public init(
        name: String,
        chunkCount: Int = 200,
        fixedLimit: Int = 8,
        serverCapacity: Int = 8,
        serviceTimeMilliseconds: Int = 40
    ) {
        self.name = name
        self.chunkCount = max(1, chunkCount)
        self.fixedLimit = max(1, fixedLimit)
        self.serverCapacity = max(1, serverCapacity)
        self.serviceTimeMilliseconds = max(1, serviceTimeMilliseconds)
    }

    public static let photoUpload = TransferProfile(name: "Photo upload")
}

/// Drives the comparison. `@Observable` would be the modern choice; this is an
/// `ObservableObject` so the view works unchanged on iOS 17 without a
/// per-property availability dance.
@MainActor
public final class TransferDashboardModel: ObservableObject {

    @Published public private(set) var comparison: CapacityExperiment.Comparison
    @Published public private(set) var invariantReport: LimiterInvariantCheck.Report
    /// Capacity the server drops to two seconds in. Bound to the slider.
    @Published public var degradedCapacity: Int {
        didSet { if degradedCapacity != oldValue { recompute() } }
    }

    public let profile: TransferProfile

    public init(profile: TransferProfile = .photoUpload) {
        self.profile = profile
        self.degradedCapacity = max(1, profile.serverCapacity / 2 - 1)
        // Computed eagerly in `init`, so the view has real numbers on its very
        // first render rather than an empty state that fills in later.
        self.comparison = Self.compare(
            profile: profile,
            degradedCapacity: max(1, profile.serverCapacity / 2 - 1)
        )
        self.invariantReport = LimiterInvariantCheck.run(GradientLimiter())
    }

    public func recompute() {
        comparison = Self.compare(profile: profile, degradedCapacity: degradedCapacity)
    }

    private static func compare(
        profile: TransferProfile,
        degradedCapacity: Int
    ) -> CapacityExperiment.Comparison {
        CapacityExperiment.compare(
            scenario: CapacityExperiment.Scenario(
                chunkCount: profile.chunkCount,
                server: SimulatedServer(
                    initialCapacity: profile.serverCapacity,
                    serviceTimeMilliseconds: profile.serviceTimeMilliseconds,
                    capacityChanges: [
                        .init(atMilliseconds: 2_000, capacity: max(1, degradedCapacity))
                    ]
                )
            ),
            fixedLimit: profile.fixedLimit
        )
    }
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
                    verdict
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
            Text("\(model.profile.chunkCount) chunks · server capacity \(model.profile.serverCapacity), dropping to \(model.degradedCapacity) at 2.0s")
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
                tint: .red
            )
            card(
                title: "Gradient limiter",
                subtitle: "Capacity discovered from latency",
                result: model.comparison.adaptive,
                tint: .green
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
                metric("p95", "\(result.p95LatencyMilliseconds) ms")
                metric("median", "\(result.medianLatencyMilliseconds) ms")
                metric("done", "\(result.completionMilliseconds) ms")
            }
            HStack(spacing: 14) {
                metric("peak in-flight", "\(result.peakInFlight)")
                metric("dropped", "\(result.droppedRequests)")
                metric("final limit", "\(result.finalLimit)")
            }
            latencyBar(result: result, tint: tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35))
        )
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A bar whose width is this strategy's p95 as a fraction of the worse of
    /// the two, so the comparison is legible at a glance.
    private func latencyBar(result: CapacityExperiment.Result, tint: Color) -> some View {
        let worst = max(
            model.comparison.fixed.p95LatencyMilliseconds,
            model.comparison.adaptive.p95LatencyMilliseconds
        )
        // Guarded rather than divided: a scenario in which both p95s are zero
        // is reachable (chunkCount of 0 through a future edit) and would
        // otherwise produce a NaN width, which SwiftUI resolves as a crash in
        // layout.
        let fraction = worst > 0
            ? Double(result.p95LatencyMilliseconds) / Double(worst)
            : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geometry.size.width * fraction))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("p95 latency \(result.p95LatencyMilliseconds) milliseconds")
    }

    private var verdict: some View {
        let ratio = model.comparison.p95Ratio
        let throughput = model.comparison.throughputRatio
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "Fixed limit p95 is %.2f× the adaptive one.", ratio))
                .font(.subheadline).bold()
            Text(String(
                format: "It buys %.0f%% of the adaptive throughput for that.",
                throughput * 100
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var capacityControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Degraded capacity: \(model.degradedCapacity)")
                .font(.subheadline)
            Slider(
                value: Binding(
                    get: { Double(model.degradedCapacity) },
                    set: { model.degradedCapacity = max(1, Int($0.rounded())) }
                ),
                in: 1...Double(max(2, model.profile.serverCapacity)),
                step: 1
            )
            .accessibilityLabel("Degraded server capacity")
            Text("Drag to change how hard the server degrades, then watch both strategies re-run.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var invariantSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                model.invariantReport.passed
                    ? "Limiter invariants hold"
                    : "Limiter invariants violated",
                systemImage: model.invariantReport.passed
                    ? "checkmark.seal.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.subheadline).bold()
            .foregroundStyle(model.invariantReport.passed ? .green : .red)

            Text("limit before congestion \(model.invariantReport.limitBeforeCongestion) → during \(model.invariantReport.limitDuringCongestion) → recovered \(model.invariantReport.limitAfterRecovery) → after a drop \(model.invariantReport.limitAfterDrop)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.invariantReport.failures.isEmpty {
                Text(
                    "failed: "
                        + model.invariantReport.failures.map(\.rawValue).joined(separator: ", ")
                )
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
