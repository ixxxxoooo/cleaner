// 完全磁盘访问权限引导横幅（非阻塞、单行紧凑）
// @author ygw
import SwiftUI

struct FDABanner: View {
    @Binding var dismissed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text("未授予「完全磁盘访问权限」，部分受保护目录无法统计")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("去授权") { SystemActions.openFullDiskAccessSettings() }
                .help("系统设置 → 隐私与安全性 → 完全磁盘访问权限，勾选本 App 后点击「重新启动」")
            Button("重新启动") { SystemActions.relaunch() }
                .help("授权后需要重启本 App 才会生效")
            Button {
                dismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("忽略")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}
