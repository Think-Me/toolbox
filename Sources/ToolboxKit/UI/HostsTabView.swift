import AppKit
import SwiftUI

/// 设置窗里的 Hosts 页：左树 + 右编辑器 + 工具条 + 冲突告警。
struct HostsTabView: View {
    @ObservedObject var hosts: HostsViewModel
    @State private var query = ""
    @FocusState private var editorFocused: Bool

    private var filteredGroups: [RuleGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return hosts.library.groups }
        return hosts.library.groups.compactMap { g in
            let rules = g.rules.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || HostsContentResolver.content(of: $0).localizedCaseInsensitiveContains(q)
            }
            return rules.isEmpty ? nil : RuleGroup(id: g.id, name: g.name,
                                                   collapsed: g.collapsed, rules: rules)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("Hosts 托管", isOn: Binding(
                    get: { hosts.library.managementOn },
                    set: { on in Task { await hosts.setManagementOn(on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                TextField("搜索规则", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Spacer()
                Button("新建规则") { hosts.addRule() }.controlSize(.small)
                Button("同步全部远程") { Task { await hosts.syncAllRemotes(force: true) } }
                    .controlSize(.small)
                Button("还原原始 hosts") { Task { await hosts.restoreOriginal() } }
                    .controlSize(.small)
            }
            .padding(10)

            if !hosts.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("域名冲突（实际解析取第一条，请自行确认）")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(hosts.conflicts.prefix(4), id: \.domain) { c in
                        Text("· \(c.domain) → " + c.mappings.map { "\($0.ruleName):\($0.ip)" }
                            .joined(separator: "  "))
                            .font(.system(size: 11))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
            }

            HSplitView {
                ruleList.frame(minWidth: 190)
                editor.frame(minWidth: 300)
            }

            HStack {
                Text(hosts.statusMessage ?? " ")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if hosts.busy { ProgressView().controlSize(.small) }
            }
            .padding(8)
        }
    }

    private var ruleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(filteredGroups) { group in
                    Text(group.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                    ForEach(group.rules) { rule in
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { _ in Task { await hosts.toggle(rule.id) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                TextField("规则名", text: Binding(
                                    get: { rule.name },
                                    set: { hosts.rename(rule.id, to: $0) }))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                Text(rule.kind.displayName)
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                Task { await hosts.delete(rule.id) }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(hosts.selectedRuleID == rule.id
                                    ? Color.accentColor.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { hosts.selectedRuleID = rule.id }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let rule = hosts.selectedRule {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule.name).font(.system(size: 11, weight: .medium))
                    Spacer()
                    if !HostsContentResolver.isEditable(rule) {
                        Text("只读（内容来自外部）").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Button("保存并应用") { Task { await hosts.commitContent() } }
                        .controlSize(.small)
                        .disabled(!hosts.hasUnsavedContent)
                }
                // 规则类型。没有这一段，"远程同步"就是个没有配置入口的死功能
                // （用户实测问："同步远程是同步哪里的？"）
                HStack(spacing: 6) {
                    Text("类型").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { rule.kind.kindTag },
                        set: { tag in
                            // 业务规则放在 ViewModel 里，视图只做转发
                            hosts.switchKind(rule.id, to: tag == .inline ? .inline : .remote)
                        })) {
                        Text("内联").tag(RuleKindTag.inline)
                        Text("远程 URL").tag(RuleKindTag.remote)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    if case .remote(let url, let cached) = rule.kind {
                        TextField("https://example.com/hosts.txt", text: Binding(
                            get: { url },
                            set: { hosts.setKind(rule.id, kind: .remote(url: $0, cachedContent: cached)) }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button("同步此条") { Task { await hosts.syncOne(rule.id) } }
                            .controlSize(.small)
                            .disabled(url.isEmpty)
                    }
                }
                if case .remote = rule.kind {
                    HStack(spacing: 6) {
                        Text("自动").font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { rule.syncInterval ?? 0 },
                            set: { hosts.setSyncInterval(rule.id, seconds: $0 == 0 ? nil : $0) })) {
                            Text("关闭").tag(TimeInterval(0))
                            Text("每小时").tag(TimeInterval(3600))
                            Text("每天").tag(TimeInterval(86400))
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 90)
                        if let last = rule.lastSyncAt {
                            Text("上次同步 \(RelativeTime.short(last))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if let err = rule.lastError {
                            Text(err).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                }
                if case .localFile(let path) = rule.kind {
                    Text("只读，内容来自 \(path)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HostsEditorTextView(
                    text: Binding(
                        get: { HostsContentResolver.content(of: rule) },
                        set: { hosts.updateContent($0) }),
                    isReadOnly: !HostsContentResolver.isEditable(rule),
                    onTextChange: { hosts.updateContent($0) })
                    .focused($editorFocused)
            }
            .padding(8)
        } else {
            VStack {
                Text("选择或新建一条规则")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
    }
}


/// 类型选择器用的标签。RuleKind 本身带关联值，不能直接当 Picker 的 selection。
enum RuleKindTag: Hashable {
    case inline, remote
}

extension RuleKind {
    var kindTag: RuleKindTag {
        switch self {
        case .inline, .localFile: return .inline
        case .remote: return .remote
        }
    }
}
