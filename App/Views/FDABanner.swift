// 完全磁盘访问权限引导横幅（非阻塞）
// @author ygw
import SwiftUI

struct FDABanner: View {
    @Environment(AppModel.self) private var model
    @Binding var dismissed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("建议授予「完全磁盘访问权限」")
                    .font(.headline)
                Text("未授权也能扫描大部分目录，但 Docker 等受保护目录将无法统计。前往 系统设置 → 隐私与安全性 → 完全磁盘访问权限，勾选本 App，然后点击「重新启动」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 12)
            Button("打开系统设置") { SystemActions.openFullDiskAccessSettings() }
            Button("重新启动") { SystemActions.relaunch() }
            Button("忽略") { dismissed = true }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}
