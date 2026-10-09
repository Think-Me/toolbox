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
                Button("同步远程") { Task { await hosts.syncAllRemotes() } }.controlSize(.small)
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
                HostsEditorTextView(
                    text: Binding(
                        get: { HostsContentResolver.content(of: rule) },
                        set: { hosts.updateContent($0) }),
                    isReadOnly: !HostsContentResolver.isEditable(rule))
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
