// 设置面板：白名单、休眠阈值、自定义规则
// @author ygw
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CleanerCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            WhitelistSettings()
                .tabItem { Label("白名单", systemImage: "hand.raised") }
            RulesSettings()
                .tabItem { Label("自定义规则", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 640, height: 460)
    }
}

/// 通用设置
private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("休眠项目判定") {
                Stepper(value: $model.dormantDays, in: 14...730, step: 15) {
                    Text("源码超过 \(model.dormantDays) 天未修改，视为休眠项目")
                }
                Text("休眠项目的构建产物会被标记为「极力推荐」。修改后重新扫描生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("清理方式") {
                Picker("默认清理方式", selection: $model.cleanMode) {
                    Text("移入废纸篓（可还原）").tag(CleanMode.trash)
                    Text("永久删除（不可恢复）").tag(CleanMode.permanent)
                }
            }
            Section("完全磁盘访问权限") {
                HStack {
                    Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                    Text(model.hasFullDiskAccess ? "已授权" : "未授权（Docker 等受保护目录无法统计）")
                    Spacer()
                    Button("打开系统设置") { SystemActions.openFullDiskAccessSettings() }
                    Button("重新检测") { model.refreshPermission() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 白名单设置
private struct WhitelistSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("白名单中的目录（及其子目录）不会被扫描，也不会被清理。").foregroundStyle(.secondary)
            List {
                if model.whitelist.isEmpty {
                    Text("暂无自定义白名单").foregroundStyle(.secondary)
                }
                ForEach(model.whitelist, id: \.self) { path in
                    HStack {
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("移除") { model.removeWhitelist(path) }.buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button("添加目录…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { panel.urls.forEach { model.addToWhitelist($0.path) } }
                }
                Spacer()
                Text("系统目录（/System 等）始终被保护，无需添加。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

/// 自定义规则设置
private struct RulesSettings: View {
    @Environment(AppModel.self) private var model

    private static let template = """
    [
      {
        "id": "my-zig-cache",
        "name": "Zig 缓存",
        "stack": "other",
        "scope": "project",
        "markers": ["build.zig"],
        "targets": ["zig-cache", ".zig-cache"],
        "level": 1,
        "expandChildren": false,
        "requiresNetwork": false,
        "regenNote": "下次 zig build 时自动重新生成"
      }
    ]
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("通过 JSON 文件扩展扫描规则。level：1=安全，2=需谨慎，3=仅展示。项目级 targets 为目录名，全局级 targets 为相对 ~ 的路径。")
                .foregroundStyle(.secondary)
                .font(.callout)
            List {
                if model.customRules.isEmpty { Text("暂无自定义规则").foregroundStyle(.secondary) }
                ForEach(model.customRules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rule.name)
                            Text("\(rule.scope == .project ? "项目级" : "全局级") · \(rule.targets.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("删除") { model.removeCustomRule(rule.id) }.buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button("导入规则文件…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { model.importRules(from: url) }
                }
                Button("导出规则模板…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "cleaner-rules.json"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? Self.template.write(to: url, atomically: true, encoding: .utf8)
                    }
                }
                Spacer()
                Text("导入后重新扫描生效").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}
