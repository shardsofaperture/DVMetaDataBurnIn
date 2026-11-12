import Foundation
import Darwin

// Shared workspace contract with cleanup.zsh: a unique run directory and an
// owner marker. The CLI removes scratch according to its cleanup policy;
// Swift removes only its copied launch files after the subprocess has exited.
struct RunWorkspace {
    let url: URL
    let token: String

    static func create(scratchDirectory: String?) throws -> RunWorkspace {
        let fm = FileManager.default
        let base: URL
        if let scratchDirectory, !scratchDirectory.isEmpty {
            base = URL(fileURLWithPath: scratchDirectory, isDirectory: true)
                .appendingPathComponent("DVMetaDataBurnIn", isDirectory: true)
        } else {
            base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DVMeta", isDirectory: true)
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let token = UUID().uuidString
        var template = Array(base.resolvingSymlinksInPath()
            .appendingPathComponent("run.XXXXXXXX").path.utf8CString)
        let directoryPath = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let pointer = buffer.baseAddress, let created = mkdtemp(pointer) else { return nil }
            return String(cString: created)
        }
        guard let directoryPath else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let url = URL(fileURLWithPath: directoryPath, isDirectory: true)
        do {
            try Data(token.utf8).write(to: url.appendingPathComponent(".dvmeta-owner"), options: .withoutOverwriting)
        } catch {
            // Only the directory just created here is eligible for removal.
            try? fm.removeItem(at: url)
            throw error
        }
        return RunWorkspace(url: url, token: token)
    }

    private var isOwned: Bool {
        let marker = url.appendingPathComponent(".dvmeta-owner")
        guard url.resolvingSymlinksInPath().path == url.path,
              (try? marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let data = try? Data(contentsOf: marker) else { return false }
        return data == Data(token.utf8)
    }

    func discardBeforeLaunch() {
        guard isOwned else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func removeLaunchFiles() {
        guard isOwned else { return }
        for name in ["dvmetaburn_run.zsh", "lib"] {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
        }
    }
}
