import XCTest
@testable import SumibiIME

final class ConversionResultVerifierTests: XCTestCase {
    @MainActor
    func testImmediatelyMatchingResultNeedsOnlyOneRead() {
        let feedback = ConversionFeedback()
        let verifier = ConversionResultVerifier(feedback: feedback)
        var reads = 0
        verifier.start(sourceCharacters: 101, sourceUTF16: 101, expectedUTF16: 60) {
            reads += 1; return .matching
        }
        XCTAssertEqual(reads, 1)
        XCTAssertNil(feedback.notice)
    }

    @MainActor
    func testDelayedResultCanMatchWithoutPrematureFailure() async throws {
        let feedback = ConversionFeedback()
        let verifier = ConversionResultVerifier(feedback: feedback)
        var reads = 0
        verifier.start(sourceCharacters: 101, sourceUTF16: 101, expectedUTF16: 60) {
            reads += 1; return reads == 3 ? .matching : .lengthMismatch(101)
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(reads, 3)
        XCTAssertNil(feedback.notice)
    }

    @MainActor
    func testTimedOutReadbackDistinguishesReadFailureAndLengthOrContentMismatch() async throws {
        for failure in [ConversionResultReadback.unavailable, .lengthMismatch(100), .mismatch] {
            let feedback = ConversionFeedback()
            let verifier = ConversionResultVerifier(feedback: feedback)
            var reads = 0
            verifier.start(sourceCharacters: 201, sourceUTF16: 201, expectedUTF16: 110) {
                reads += 1; return failure
            }
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertEqual(reads, 6) // One immediate check and five bounded polls.
            XCTAssertEqual(feedback.notice, .resultConfirmation(failure,
                sourceCharacters: 201, sourceUTF16: 201, expectedUTF16: 110))
        }
    }

    @MainActor
    func testNewInputTargetChangeAndNewVerificationCancelOldChecksSilently() async throws {
        for scenario in 0..<3 {
            let feedback = ConversionFeedback()
            let verifier = ConversionResultVerifier(feedback: feedback)
            var valid = true
            var oldReads = 0
            verifier.start(sourceCharacters: 101, sourceUTF16: 101, expectedUTF16: 60) {
                oldReads += 1; return valid ? .unavailable : nil
            }
            if scenario == 0 { verifier.cancel() }
            if scenario == 1 { valid = false }
            if scenario == 2 {
                verifier.start(sourceCharacters: 3, sourceUTF16: 3, expectedUTF16: 1) { .matching }
            }
            try await Task.sleep(nanoseconds: 650_000_000)
            XCTAssertEqual(oldReads, scenario == 1 ? 2 : 1)
            XCTAssertNil(feedback.notice)
        }
    }
}
