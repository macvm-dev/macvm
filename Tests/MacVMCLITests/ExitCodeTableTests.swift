import MacVMModel
import Testing

struct ExitCodeTableTests {
    @Test func everyErrorHasSummary() {
        for error in MacVMError.catalog {
            #expect(!error.summary.isEmpty)
        }
    }
}
