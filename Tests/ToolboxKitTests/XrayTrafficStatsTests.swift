import Foundation
import Testing
@testable import ToolboxKit

private func data(_ s: String) -> Data { Data(s.utf8) }

@Test func trafficSumsProxyInboundsAndSkipsAPI() {
    let json = """
    { "stat": [
      { "name": "inbound>>>socks-in>>>traffic>>>uplink",   "value": "100" },
      { "name": "inbound>>>socks-in>>>traffic>>>downlink", "value": "200" },
      { "name": "inbound>>>http-in>>>traffic>>>uplink",    "value": "50" },
      { "name": "inbound>>>http-in>>>traffic>>>downlink",  "value": "400" },
      { "name": "inbound>>>api>>>traffic>>>uplink",        "value": "999" },
      { "name": "outbound>>>proxy>>>traffic>>>uplink",     "value": "1" }
    ] }
    """
    #expect(XrayStatsParser.traffic(from: data(json)) == TrafficCounters(up: 150, down: 600))
}

@Test func trafficAcceptsNumericValues() {
    let json = #"{ "stat": [ { "name": "inbound>>>http-in>>>traffic>>>downlink", "value": 1234 } ] }"#
    #expect(XrayStatsParser.traffic(from: data(json)) == TrafficCounters(up: 0, down: 1234))
}

@Test func trafficRejectsMalformedJSON() {
    #expect(XrayStatsParser.traffic(from: data("not json")) == nil)
    #expect(XrayStatsParser.traffic(from: data("{}")) == nil)
}

@Test func trafficTreatsMissingValueAsZero() {
    // 真实 xray 输出里，计数为 0 的项会省略 value 字段
    let json = #"{ "stat": [ { "name": "inbound>>>http-in>>>traffic>>>uplink" } ] }"#
    #expect(XrayStatsParser.traffic(from: data(json)) == TrafficCounters(up: 0, down: 0))
}

@Test func rateComputesPerSecondAndRejectsCounterReset() {
    let prev = TrafficCounters(up: 1000, down: 2000)
    let cur = TrafficCounters(up: 3048, down: 4048)
    #expect(TrafficSample.rate(from: prev, to: cur, elapsed: 1)
            == TrafficSample(upPerSecond: 2048, downPerSecond: 2048))
    // 计数回退（内核重启清零）→ 不可计算
    #expect(TrafficSample.rate(from: cur, to: prev, elapsed: 1) == nil)
    #expect(TrafficSample.rate(from: prev, to: cur, elapsed: 0) == nil)
}

@Test func rateFormatterUsesBinaryUnits() {
    #expect(TrafficRateFormatter.string(0) == "0 B/s")
    #expect(TrafficRateFormatter.string(-5) == "0 B/s")
    #expect(TrafficRateFormatter.string(512) == "512 B/s")
    #expect(TrafficRateFormatter.string(1024) == "1.0 KB/s")
    #expect(TrafficRateFormatter.string(1024 * 1024 * 1.5) == "1.5 MB/s")
}

@Test func allocatedPortIsInValidRange() {
    if let port = LocalFreePort.allocate() {
        #expect(port > 0 && port < 65536)
    }
}
