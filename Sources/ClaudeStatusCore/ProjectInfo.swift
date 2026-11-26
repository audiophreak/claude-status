import Foundation

/// Git repository identity derived from a working directory, worktree-aware.
public struct ProjectInfo: Equatable, Sendable {
    public var repoRoot: String
    public var repoName: String
    public var worktreeName: String?

    public init(repoRoot: String, repoName: String, worktreeName: String?) {
        self.repoRoot = repoRoot; self.repoName = repoName; self.worktreeName = worktreeName
    }

    /// Walk up from `path` (max 64 levels) looking for `.git`. A `.git` *file* indicates a
    /// linked worktree: `gitdir: <main>/.git/worktrees/<name>`. Reads at most 1 KiB.
    public static func detect(from path: String, fileManager fm: FileManager = .default) -> ProjectInfo? {
        guard Validate.absolutePath(path) else { return nil }
        var url = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<64 {
            let git = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return ProjectInfo(repoRoot: url.path, repoName: url.lastPathComponent, worktreeName: nil)
                }
                if let main = worktreeMainRepo(gitFile: git) {
                    return ProjectInfo(repoRoot: url.path, repoName: main.repo, worktreeName: main.worktree ?? url.lastPathComponent)
                }
                return ProjectInfo(repoRoot: url.path, repoName: url.lastPathComponent, worktreeName: nil)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    static func worktreeMainRepo(gitFile: URL) -> (repo: String, worktree: String?)? {
        guard let h = try? FileHandle(forReadingFrom: gitFile) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 1024), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let marker = "/.git/worktrees/"
        guard let r = gitdir.range(of: marker) else { return nil }
        let mainRoot = String(gitdir[..<r.lowerBound])
        let wt = String(gitdir[r.upperBound...]).split(separator: "/").first.map(String.init)
        let repo = (mainRoot as NSString).lastPathComponent
        guard !repo.isEmpty else { return nil }
        return (repo, wt)
    }
}
