import XCTest
@testable import AdaptiveTransfer

/// These exist because the first cut of this package shipped a dashboard whose
/// slider did nothing and whose default state argued *against* the library —
/// and no test could have caught it, because the type that made those decisions
/// lived in a SwiftUI-only module the test target could not see. Moving
/// `TransferProfile` into the core module was the fix; this file is what makes
/// the fix mean something.
final class TransferProfileTests: XCTestCase {

    /// The defect, stated as a test: two different slider positions must
    /// produce two different comparisons. A profile whose degradation lands
    /// after the transfer has already finished passes every other test in this
    /// package and renders a control that changes nothing.
    func testDifferentDegradedCapacitiesProduceDifferentResults() {
        let profile = TransferProfile.photoUpload
        let severe = profile.compare(degradedCapacity: 1)
        let mild = profile.compare(degradedCapacity: 8)

        XCTAssertNotEqual(
            severe.fixed, mild.fixed,
            "the degraded-capacity control has no effect on the fixed strategy"
        )
        XCTAssertNotEqual(
            severe.adaptive, mild.adaptive,
            "the degraded-capacity control has no effect on the adaptive strategy"
        )
    }

    /// Every reachable slider position must move the outcome. Asserting only
    /// that the endpoints differ would miss a control that is live at one end
    /// and dead across the middle.
    func testEveryReachableSliderPositionChangesSomething() {
        let profile = TransferProfile.photoUpload
        let results = profile.degradedCapacityRange.map {
            profile.compare(degradedCapacity: $0).fixed
        }
        XCTAssertEqual(
            Set(results.map(\.completionMilliseconds)).count,
            results.count,
            "two slider positions produced identical completion times: \(results.map(\.completionMilliseconds))"
        )
    }

    /// The degradation has to land while the transfer is still running, or the
    /// whole scenario is a no-op. This is the specific bug, guarded directly.
    func testDegradationHappensBeforeTheTransferCouldFinish() {
        let profile = TransferProfile.photoUpload
        let comparison = profile.compare(degradedCapacity: profile.defaultDegradedCapacity)
        XCTAssertLessThan(
            profile.degradeAtMilliseconds,
            comparison.fixed.completionMilliseconds,
            "the server degrades after the fixed strategy has already finished"
        )
        XCTAssertLessThan(
            profile.degradeAtMilliseconds,
            comparison.adaptive.completionMilliseconds,
            "the server degrades after the adaptive strategy has already finished"
        )
    }

    /// The default the dashboard opens on must show the argument the READMEs
    /// make, or the first frame a reviewer sees contradicts the pitch.
    func testTheDefaultStateDemonstratesTheArgument() {
        let profile = TransferProfile.photoUpload
        let comparison = profile.compare(degradedCapacity: profile.defaultDegradedCapacity)
        XCTAssertNotEqual(
            profile.verdict(for: comparison),
            .fixedGuessHappenedToBeRight,
            "the dashboard opens on a state where the fixed limit wins"
        )
    }

    /// And the honest other half: at mild degradation the fixed guess really
    /// does win, the verdict says so rather than spinning it, and the UI has a
    /// branch for it. A demo that could not reach this state would be a sales
    /// pitch.
    func testMildDegradationIsReportedAsAWinForTheFixedGuess() {
        let profile = TransferProfile.photoUpload
        let comparison = profile.compare(degradedCapacity: profile.serverCapacity)
        XCTAssertEqual(
            profile.verdict(for: comparison),
            .fixedGuessHappenedToBeRight
        )
    }

    func testSevereDegradationCollapsesTheFixedLimit() {
        let profile = TransferProfile(
            name: "over-guessed",
            chunkCount: 300,
            fixedLimit: 16,
            serverCapacity: 8,
            serviceTimeMilliseconds: 40,
            degradeAtMilliseconds: 200
        )
        let comparison = profile.compare(degradedCapacity: 2)
        XCTAssertEqual(profile.verdict(for: comparison), .fixedLimitCollapsed)
        XCTAssertLessThan(comparison.fixed.completedChunks, profile.chunkCount)
        XCTAssertEqual(comparison.adaptive.completedChunks, profile.chunkCount)
    }

    func testConfigurationIsSanitised() {
        let profile = TransferProfile(
            name: "nonsense",
            chunkCount: 0,
            fixedLimit: -4,
            serverCapacity: 0,
            serviceTimeMilliseconds: -1,
            degradeAtMilliseconds: -5
        )
        XCTAssertEqual(profile.chunkCount, 1)
        XCTAssertEqual(profile.fixedLimit, 1)
        XCTAssertEqual(profile.serverCapacity, 1)
        XCTAssertEqual(profile.serviceTimeMilliseconds, 1)
        XCTAssertEqual(profile.degradeAtMilliseconds, 0)
        // A capacity of 1 would give an empty slider range; it is widened.
        XCTAssertEqual(profile.degradedCapacityRange, 1...2)
    }

    func testCompareClampsAnOutOfRangeCapacity() {
        let profile = TransferProfile.photoUpload
        XCTAssertEqual(
            profile.compare(degradedCapacity: -100),
            profile.compare(degradedCapacity: profile.degradedCapacityRange.lowerBound)
        )
        XCTAssertEqual(
            profile.compare(degradedCapacity: Int.max),
            profile.compare(degradedCapacity: profile.degradedCapacityRange.upperBound)
        )
    }
}
