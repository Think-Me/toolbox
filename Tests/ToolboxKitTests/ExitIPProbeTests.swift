import Foundation
import Testing
@testable import ToolboxKit

private func data(_ s: String) -> Data { Data(s.utf8) }

@Test func parsesJSONIPField() {
    #expect(ExitIPProbe.parse(data(#"{"ip":"1.2.3.4"}"#)) == "1.2.3.4")
}

@Test func parsesChinesePlainText() {
    #expect(ExitIPProbe.parse(data("当前 IP：203.0.113.7  来自于：中国")) == "203.0.113.7")
}

@Test func parsesPlainIPv4() {
    #expect(ExitIPProbe.parse(data("8.8.4.4")) == "8.8.4.4")
}

@Test func parsesCompressedIPv6() {
    #expect(ExitIPProbe.parse(data("2606:4700:4700::1111")) == "2606:4700:4700::1111")
}

@Test func ignoresTextWithoutIP() {
    #expect(ExitIPProbe.parse(data("no address here")) == nil)
    #expect(ExitIPProbe.parse(data("999.1.1.1")) == nil)
}

@Test func validatesAddresses() {
    #expect(ExitIPProbe.isIPAddress("1.2.3.4"))
    #expect(ExitIPProbe.isIPAddress("::1"))
    #expect(!ExitIPProbe.isIPAddress("999.1.1.1"))
    #expect(!ExitIPProbe.isIPAddress("hello"))
}
