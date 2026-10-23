#if CORE_STANDALONE
import Foundation
import Darwin

// The CLT-only environment has no XCTest runtime. This small assertion harness
// executes the SAME twelve scenario methods. It does not claim to run XCTest.
class StandaloneTestCase { func tearDown() {} }
private enum AssertionState { static var failures: [String] = [] }
private struct CheckFailure: Error { let message: String }
func XCTFail(_ message: String = "Failure", file: StaticString = #filePath, line: UInt = #line) {
    AssertionState.failures.append("\(file):\(line): \(message)")
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { let a = try lhs(); let b = try rhs(); if a != b { XCTFail("\(a) != \(b)", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() == rhs() { XCTFail("Values unexpectedly equal", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { XCTFail("Expected true", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { XCTFail("Expected false", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { XCTFail("Expected nil", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() == nil { XCTFail("Expected a value", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { XCTFail("Missing value", file: file, line: line); throw CheckFailure(message: "Missing value") }
    return value
}
func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line, _ handler: ((Error) -> Void)? = nil) {
    do { _ = try expression(); XCTFail("Expected an error", file: file, line: line) }
    catch { handler?(error) }
}

@main struct StandaloneCoreChecks {
    static func main() {
        let scenarios: [(String, (LedgerStoreTests) -> () throws -> Void)] = [
            ("frozen source and explicit commit", LedgerStoreTests.testFrozenSourceAndExplicitCommitBoundary),
            ("tamper and key substitution", LedgerStoreTests.testTamperedPayloadAndPublicKeyAreRejectedEvenWithRecomputedID),
            ("duplicate import", LedgerStoreTests.testDuplicateImportIsIdempotent),
            ("withdrawal before original", LedgerStoreTests.testWithdrawalBeforeOriginalPreservesHistoryAndAppliesOnlyToTarget),
            ("foreign withdrawal cannot preempt", LedgerStoreTests.testForeignWithdrawalCannotSuppressOrPreemptOriginal),
            ("persistence and exact URL", LedgerStoreTests.testPersistenceReloadAndExactSourceURLFilter),
            ("atomic invalid import and unknown schema", LedgerStoreTests.testBadArchiveIsAtomicAndUnknownSchemaIsRejected),
            ("duplicate unknown and deep JSON fields", LedgerStoreTests.testDuplicateUnknownAndDeepJSONFieldsAreRejected),
            ("typed fields and reasonless hold", LedgerStoreTests.testTypedFieldsAndReasonlessHold),
            ("file source and exact record targets", LedgerStoreTests.testLocalFileSourceAndExactAnswerEvaluationTargets),
            ("key failure without identity reset", LedgerStoreTests.testKeychainFailureAndMissingExistingKeyNeverFallbackOrReset),
            ("RFC8032 and protocol vector", LedgerStoreTests.testKnownEd25519AndCanonicalInteroperabilityVector)
        ]
        for (name, scenario) in scenarios {
            let instance = LedgerStoreTests()
            let before = AssertionState.failures.count
            do { try scenario(instance)() } catch { XCTFail("\(name): \(error)") }
            instance.tearDown()
            print("\(AssertionState.failures.count == before ? "PASS" : "FAIL") \(name)")
        }
        for failure in AssertionState.failures { fputs(failure + "\n", stderr) }
        print("Standalone scenarios: \(scenarios.count); failed assertions: \(AssertionState.failures.count)")
        exit(AssertionState.failures.isEmpty ? 0 : 1)
    }
}
#endif
