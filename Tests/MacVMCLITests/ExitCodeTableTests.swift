import MacVMModel
import Testing

struct ExitCodeTableTests {
    @Test func everyErrorHasSummary() {
        for error in MacVMError.catalog {
            #expect(!error.summary.isEmpty)
        }
    }

    @Test func publishedCodesAreStable() {
        let table = Dictionary(uniqueKeysWithValues: MacVMError.catalog.map { ($0.code, $0.exitCode) })
        #expect(table["template_not_found"] == 21 && table["permission_denied"] == 22)
        #expect(Set(MacVMError.catalog.map(\.exitCode)).count == MacVMError.catalog.count)
    }
}
