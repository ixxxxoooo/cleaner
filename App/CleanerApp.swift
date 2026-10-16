// 应用入口：单窗口，关闭最后一个窗口即退出（不常驻后台）
// @author ygw
import SwiftUI
import AppKit

/// 应用代理：关闭最后一个窗口时退出
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// 窗口超出屏幕可视区域时收缩到合理尺寸并居中（内容的理想高度可能很大）
@MainActor
func fitWindowToScreen() {
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
          let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
    let frame = window.frame
    guard frame.width > visible.width - 20 || frame.height > visible.height - 20 else { return }
    let width = min(max(1180, visible.width * 0.62), visible.width - 40)
    let height = min(max(720, visible.height * 0.78), visible.height - 40)
    window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: true, animate: false)
}

@main
struct CleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("开发者清理", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    try? await Task.sleep(for: .milliseconds(400))
                    fitWindowToScreen()
                    // 启动即扫描（缓存结果已先行展示）
                    model.startScan()
                }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("开始扫描") { model.startScan() }.keyboardShortcut("r", modifiers: .command)
                Button("取消扫描") { model.cancelScan() }.keyboardShortcut(".", modifiers: .command)
            }
            CommandMenu("清理") {
                Button("勾选所有「极力推荐」") { model.selectRecommended() }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("取消全部勾选") { model.clearSelection() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("清理所选…") { model.requestClean() }.keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("显示/隐藏详情") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("打开废纸篓") { SystemActions.openTrash() }
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

