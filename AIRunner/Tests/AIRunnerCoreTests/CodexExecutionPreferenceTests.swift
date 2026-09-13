import XCTest
@testable import AIRunnerCore

final class CodexExecutionPreferenceTests: XCTestCase {

    func testReasoningEffortOrderMatchesSixCodexSliderStops() {
        XCTAssertEqual(
            CodexReasoningEffort.allCases,
            [.low, .medium, .high, .xhigh, .max, .ultra]
        )
        XCTAssertEqual(CodexReasoningEffort.allCases.map(\.displayName),
                       ["轻度", "中", "高", "极高", "最高", "ultra"])
        XCTAssertEqual(CodexReasoningEffort.allCases.map(\.sliderIndex), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(CodexReasoningEffort.low.sliderFraction, 0)
        XCTAssertEqual(CodexReasoningEffort.ultra.sliderFraction, 1)
    }

    func testSliderFractionsRoundToTheNearestDiscreteStop() {
        XCTAssertEqual(CodexReasoningEffort.fromSliderFraction(-1), .low)
        XCTAssertEqual(CodexReasoningEffort.fromSliderFraction(0), .low)
        XCTAssertEqual(CodexReasoningEffort.fromSliderFraction(0.2), .medium)
        XCTAssertEqual(CodexReasoningEffort.fromSliderFraction(0.4), .high)
        XCTAssertEqual(CodexReasoningEffort.fromSliderFraction(0.6), .xhigh)
        XCTAssertEqual(CodexReasoningEffort.fromSliderFraction(0.8), .max)
        XCTAssertEqual(CodexReasoningEffort.fromSliderFraction(1), .ultra)
        XCTAssertEqual(CodexReasoningEffort.fromSliderFraction(2), .ultra)
    }

    func testAXSliderValuesMapAcrossArbitraryMinAndMax() {
        XCTAssertEqual(
            CodexReasoningEffort.fromSliderValue(0, min: 0, max: 5), .low
        )
        XCTAssertEqual(
            CodexReasoningEffort.fromSliderValue(2, min: 0, max: 5), .high
        )
        XCTAssertEqual(
            CodexReasoningEffort.fromSliderValue(18, min: 10, max: 20), .max
        )
        XCTAssertEqual(
            CodexReasoningEffort.fromSliderValue(20, min: 10, max: 20), .ultra
        )
        XCTAssertNil(CodexReasoningEffort.fromSliderValue(1, min: 1, max: 1))
    }

    func testUILabelAliasesAreUnambiguousForHighestAndUltra() {
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("轻度"), .low)
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("Low"), .low)
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("极高"), .xhigh)
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("最高"), .max)
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("Ultra"), .ultra)
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("GPT-5.6 Sol · 高"), .high)
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("GPT-6 Astra 极高"), .xhigh)
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("选择强度：ultra"), .ultra)
        XCTAssertEqual(CodexReasoningEffort.fromUILabel("GPT-5.6 Sol 极高"), .xhigh)
        XCTAssertNil(CodexReasoningEffort.fromUILabel("选择强度"))
    }

    func testSelectionAcceptsSeparatorsAndKeepsUltraDistinct() {
        let high = CodexExecutionPreference(modelID: "gpt-5.6-sol", reasoningEffort: .high)
        XCTAssertTrue(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol · 高").matches(high))

        let maximum = CodexExecutionPreference(modelID: "gpt-5.6-sol", reasoningEffort: .max)
        let ultra = CodexExecutionPreference(modelID: "gpt-5.6-sol", reasoningEffort: .ultra)
        XCTAssertTrue(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol · 最高").matches(maximum))
        XCTAssertFalse(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol · Ultra").matches(maximum))
        XCTAssertTrue(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol · Ultra").matches(ultra))
    }
}
