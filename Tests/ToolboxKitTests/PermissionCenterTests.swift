import Testing
@testable import ToolboxKit

private func fake(_ ax: Bool, _ screen: Bool, _ hosts: Bool, _ dns: Bool) -> PermissionProbes {
    PermissionProbes(accessibility: { ax }, screenRecording: { screen },
                     hostsWritable: { hosts }, dnsFlush: { dns })
}

@Test func allGrantedShowsNoActions() {
    let rows = PermissionCenter(probes: fake(true, true, true, true)).snapshot()
    #expect(rows.count == Permission.allCases.count)
    #expect(rows.allSatisfy { $0.state == .granted })
    #expect(rows.allSatisfy { $0.actionTitle == nil })
}

@Test func screenRecordingRequiresRestartHint() {
    let rows = PermissionCenter(probes: fake(true, false, true, true)).snapshot()
    let sr = rows.first { $0.permission == .screenRecording }!
    #expect(sr.state == .denied)
    #expect(sr.actionTitle == "去授权")
    #expect(sr.detail.contains("重启"))     // 授权后必须重启才生效，文案不许漏
}

@Test func hostsDeniedExplainsProvisionCommand() {
    let rows = PermissionCenter(probes: fake(true, true, false, false)).snapshot()
    let hosts = rows.first { $0.permission == .hostsWritable }!
    #expect(hosts.detail.contains("/etc/hosts"))
    #expect(hosts.detail.contains("chown"))
    #expect(rows.first { $0.permission == .dnsFlush }!.actionTitle != nil)
}

@Test func unknownIsDistinctFromDenied() {
    let nilProbes = PermissionProbes(accessibility: { nil }, screenRecording: { nil },
                                     hostsWritable: { nil }, dnsFlush: { nil })
    let rows = PermissionCenter(probes: nilProbes).snapshot()
    #expect(rows.allSatisfy { $0.state == .unknown })
    // 探测本身失败 ≠ 被拒绝：文案不许诱导用户去"重新授权"一件没发生的事
    #expect(rows.allSatisfy { $0.actionTitle == "重试探测" })
}

@Test func everyPermissionHasChineseGuidance() {
    for p in Permission.allCases {
        #expect(!PermissionCenter.detail(for: p).isEmpty)
    }
}
