// 清理历史：查看与还原
// @author ygw
import SwiftUI
import CleanerCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView("暂无清理记录", systemImage: "clock.arrow.circlepath", description: Text("清理后的项目会记录在这里，移入废纸篓的项目可以还原。"))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("共 \(model.history.count) 条记录 · 累计 \(formatBytes(model.history.reduce(0) { $0 + $1.sizeBytes }))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开废纸篓") { SystemActions.openTrash() }
                    Button("清空记录", role: .destructive) { model.clearHistory() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                List(model.history) { record in
                    HStack(spacing: 12) {
                        Image(systemName: record.mode == .trash ? "trash" : "flame")
                            .foregroundStyle(record.mode == .trash ? Color.secondary : Color.red)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.title)
                            Text((record.originalPath as NSString).abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatBytes(record.sizeBytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        if record.restored {
                            Text("已还原").font(.caption).foregroundStyle(.green).frame(width: 60)
                        } else if record.mode == .trash {
                            Button("还原") { model.restore(record) }.frame(width: 60)
                        } else {
                            Text("已删除").font(.caption).foregroundStyle(.secondary).frame(width: 60)
                        }
                    }
                }
            }
        }
    }
}
