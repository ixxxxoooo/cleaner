// 主窗口：边缘延伸侧边栏 + 主内容 + 右侧详情（inspector），统一工具栏
// @author ygw
import SwiftUI
import CleanerCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("fdaBannerDismissed") private var fdaDismissed = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detailContent
                // 最小尺寸只加在详情区，避免与 inspector 叠加导致约束更新循环
                .frame(minWidth: 560, minHeight: 520)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !model.hasFullDiskAccess && !fdaDismissed {
                        FDABanner(dismissed: $fdaDismissed)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CleanBar()
                }
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar { toolbarContent }
        .onChange(of: model.hasFullDiskAccess) { _, granted in
            // 授权后重置「忽略」状态，若之后权限被撤销可再次提示
            if granted { fdaDismissed = false }
        }
        .modifier(CleanDialogs())
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// 主内容区
    @ViewBuilder
    private var detailContent: some View {
        switch model.section {
        case .dashboard: DashboardView()
        case .projects: ItemsView(scope: .project)
        case .global: ItemsView(scope: .global)
        case .git: GitView()
        case .history: HistoryView()
        }
    }

    private var title: String {
        switch model.section {
        case .dashboard: "仪表盘"
        case .projects: "项目级产物"
        case .global: "全局依赖缓存"
        case .git: "Git 仓库优化"
        case .history: "清理历史"
        }
    }

    /// 副标题：扫描状态或汇总
    private var subtitle: String {
        switch model.phase {
        case .scanning:
            let p = model.progress
            return "扫描中 · 已发现 \(model.scanFound) 项 · 已访问 \(p?.visitedDirectories ?? 0) 个目录"
        case .finished:
            if let s = model.summary { return "共 \(model.items.count) 项 · \(formatBytes(model.totalBytes)) · 用时 \(String(format: "%.1f", s.duration)) 秒" }
            return ""
        case .idle:
            return model.items.isEmpty ? "" : "缓存结果 · \(formatBytes(model.totalBytes))"
        }
    }

    /// 统一工具栏
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.toggleScan()
            } label: {
                if model.phase == .scanning {
                    Label("取消扫描", systemImage: "stop.fill")
                } else {
                    Label("开始扫描", systemImage: "arrow.clockwise")
                }
            }
            .labelStyle(.titleAndIcon)
            .help(model.phase == .scanning ? "取消扫描（⌘.）" : "开始扫描（⌘R）")
            .buttonStyle(.glassProminent)
        }
        ToolbarItem(placement: .primaryAction) {
            ToolbarSearchField()
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("详情", systemImage: "sidebar.trailing")
            }
            .help("显示/隐藏详情")
        }
    }
}

/// 侧边栏
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            Section("总览") {
                Label("仪表盘", systemImage: "chart.pie").tag(SidebarSection.dashboard)
            }
            Section("清理") {
                Label("项目级产物", systemImage: "folder.badge.gearshape")
                    .badge(model.projectCount)
                    .tag(SidebarSection.projects)
                Label("全局依赖缓存", systemImage: "externaldrive.badge.icloud")
                    .badge(model.globalCount)
                    .tag(SidebarSection.global)
                Label("Git 仓库优化", systemImage: "arrow.triangle.branch")
                    .badge(model.gitRepos.count)
                    .tag(SidebarSection.git)
            }
            Section("记录") {
                Label("清理历史", systemImage: "clock.arrow.circlepath").tag(SidebarSection.history)
            }
        }
        .listStyle(.sidebar)
    }
}


/// 工具栏紧凑搜索框（固定宽度，⌘F 聚焦）
struct ToolbarSearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 110)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // 隐藏按钮：提供 ⌘F 快捷键
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help("搜索名称、路径、技术栈（⌘F）")
    }
}
