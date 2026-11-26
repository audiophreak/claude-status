import Darwin
import Foundation

/// Installs the hook and control helpers from an app bundle (or build directory) to the
/// stable location `~/Library/Application Support/ClaudeStatus/bin`, which does not depend on
/// where the app or a source checkout lives.
///
/// Files are written as new files (read source bytes, write temp file, fsync, rename), never
/// via an in-place overwrite, so a hook running concurrently always sees a complete binary.
public enum HelperInstaller {
    public static let helperNames = ["claude-status-hook", "claude-status-ctl"]
    public static let maxHelperBytes = 64 * 1024 * 1024

    public enum Outcome: Equatable, Sendable {
        case installed([String])   // names written
        case upToDate
    }

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case missingSource(String)
        case invalidSource(String)
        case writeFailed(String)
        public var description: String {
            switch self {
            case .missingSource(let s): return "helper not found: \(s)"
            case .invalidSource(let s): return "helper is not a regular file: \(s)"
            case .writeFailed(let s): return "could not install helper: \(s)"
            }
        }
    }

    /// Helpers directory inside the running app bundle, if present.
    public static func bundledHelpersDirectory(bundle: Bundle = .main) -> URL? {
        let dir = bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let hook = dir.appendingPathComponent("claude-status-hook")
        return FileManager.default.isExecutableFile(atPath: hook.path) ? dir : nil
    }

    /// True when every installed helper exists and is byte-identical to the source.
    public static func isUpToDate(from source: URL, paths: StatusPaths) -> Bool {
        helperNames.allSatisfy { name in
            guard let a = try? read(source.appendingPathComponent(name)),
                  let b = try? read(paths.binDir.appendingPathComponent(name)) else { return false }
            return a == b
        }
    }

    @discardableResult
    public static func install(from source: URL, paths: StatusPaths) throws -> Outcome {
        if isUpToDate(from: source, paths: paths) { return .upToDate }
        let fm = FileManager.default
        for dir in [paths.root, paths.binDir] where !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { throw InstallError.writeFailed("\(dir.path): \(error)") }
        }
        var written: [String] = []
        for name in helperNames {
            let src = source.appendingPathComponent(name)
            let data = try read(src)
            do {
                try SessionStore.atomicWrite(data, to: paths.binDir.appendingPathComponent(name), mode: 0o755)
            } catch { throw InstallError.writeFailed("\(name): \(error)") }
            written.append(name)
        }
        return .installed(written)
    }

    static func read(_ url: URL) throws -> Data {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw InstallError.missingSource(url.path) }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size <= maxHelperBytes else {
            throw InstallError.invalidSource(url.path)
        }
        guard let d = FileManager.default.contents(atPath: url.path) else { throw InstallError.missingSource(url.path) }
        return d
    }
}
