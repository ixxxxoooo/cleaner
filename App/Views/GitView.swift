// Git 仓库专项：.git 体积膨胀分析，提示 gc / 清理废弃 worktree，而不是删除仓库
// @author ygw
import SwiftUI
import CleanerCore

struct GitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.gitRepos.isEmpty {
            ContentUnavailableView(
                model.phase == .scanning ? "正在扫描…" : "没有发现体积异常的 Git 仓库",
                systemImage: "arrow.triangle.branch",
                description: Text("仅列出 .git 目录超过 \(formatBytes(GitAnalyzer.reportThreshold)) 的仓库。这里只做 git gc 优化，不会删除仓库。"))
        } else {
            let maxBytes = model.gitRepos.map(\.gitBytes).max() ?? 1
            List {
                Section {
                    ForEach(model.gitRepos) { repo in
                        GitRepoRow(repo: repo, maxBytes: maxBytes)
                    }
                } footer: {
                    Text("提示：git gc 只会重新打包对象、清理不可达对象，不会改动你的工作区和提交历史。")
                }
            }
        }
    }
}

/// 单个仓库行：展开后可分析与优化
struct GitRepoRow: View {
    @Environment(AppModel.self) private var model
    let repo: GitRepoInfo
    let maxBytes: Int64
    @State private var expanded = false

    var body: some View {
        let state = model.gitStates[repo.path] ?? GitState()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.name).font(.headline)
                    Text((repo.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                SizeBar(bytes: repo.gitBytes, maxBytes: maxBytes, tint: .orange).frame(width: 220)
                Button(expanded ? "收起" : "分析") {
                    expanded.toggle()
                    if expanded, state.analysis == nil { model.analyzeGit(repo) }
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if state.busy { ProgressView().controlSize(.small) }
                    if let analysis = state.analysis { analysisView(analysis) }
                    if let error = state.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
                    if !state.log.isEmpty {
                        Text(state.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Button("运行 git gc") { model.gcGit(repo, aggressive: false) }
                        Button("深度 gc（较慢）") { model.gcGit(repo, aggressive: true) }
                        Button("清理废弃 worktree") { model.pruneWorktrees(repo) }
                            .disabled(state.analysis?.prunableWorktrees.isEmpty ?? true)
                        Button("在 Finder 中显示") { SystemActions.reveal(repo.path) }
                    }
                    .disabled(state.busy)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        }
        .padding(.vertical, 4)
    }

    private func analysisView(_ analysis: GitAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("松散对象 \(analysis.looseObjects) 个（\(formatBytes(analysis.looseBytes))）· 打包文件 \(analysis.packs) 个（\(formatBytes(analysis.packBytes))）")
            if analysis.garbageBytes > 0 {
                Text("垃圾文件 \(formatBytes(analysis.garbageBytes))").foregroundStyle(.orange)
            }
            if !analysis.prunableWorktrees.isEmpty {
                Text("废弃 worktree \(analysis.prunableWorktrees.count) 个：").foregroundStyle(.orange)
                ForEach(analysis.prunableWorktrees, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Label(analysis.shouldGC ? "建议执行 git gc" : "对象库状态良好，gc 收益有限", systemImage: analysis.shouldGC ? "wand.and.stars" : "checkmark.circle")
                .foregroundStyle(analysis.shouldGC ? .orange : .green)
        }
        .font(.callout)
    }
}
