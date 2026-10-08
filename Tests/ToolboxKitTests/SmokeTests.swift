import Testing
@testable import ToolboxKit

@Test func moduleIsVisibleToTests() {
    #expect(ToolboxKit.moduleName == "ToolboxKit")
}
