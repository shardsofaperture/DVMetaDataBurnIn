import Foundation

// Compile alongside DVProcessor.swift with the project's Xcode toolchain.
@main
struct RunWorkspaceChecks {
    static func main() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("DVMeta workspace checks \(UUID().uuidString) Owner's 漢字")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else {
                throw NSError(domain: "RunWorkspaceChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: name])
            }
            passed += 1
            print("[PASS] \(name)")
        }

        let first = try RunWorkspace.create(scratchDirectory: scratch.path)
        let second = try RunWorkspace.create(scratchDirectory: scratch.path)
        try check(first.url != second.url && first.token != second.token, "runs get independent workspaces")
        let marker = first.url.appendingPathComponent(".dvmeta-owner")
        let writtenToken = try String(contentsOf: marker, encoding: .utf8)
        try check(writtenToken == first.token, "ownership token is written literally")

        let artifacts = first.url.appendingPathComponent("artifacts")
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let sentinel = artifacts.appendingPathComponent("keep.txt")
        try "diagnostic".write(to: sentinel, atomically: true, encoding: .utf8)
        let script = first.url.appendingPathComponent("dvmetaburn_run.zsh")
        try "script".write(to: script, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: first.url.appendingPathComponent("lib"), withIntermediateDirectories: true)
        first.removeLaunchFiles()
        try check(!fm.fileExists(atPath: script.path) && fm.fileExists(atPath: sentinel.path), "launch cleanup preserves diagnostic artifacts")

        second.discardBeforeLaunch()
        try check(!fm.fileExists(atPath: second.url.path) && fm.fileExists(atPath: sentinel.path), "failed launch cleanup affects only its own run")
        try "changed".write(to: marker, atomically: true, encoding: .utf8)
        first.discardBeforeLaunch()
        try check(fm.fileExists(atPath: sentinel.path), "changed ownership blocks recursive cleanup")

        let linkedParent = scratch.appendingPathComponent("linked scratch")
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: scratch)
        let linked = try RunWorkspace.create(scratchDirectory: linkedParent.path)
        try check(linked.url.path == linked.url.resolvingSymlinksInPath().path, "workspace resolves scratch parent symlinks")
        linked.discardBeforeLaunch()
        print("\(passed) Swift workspace checks passed")
    }
}
