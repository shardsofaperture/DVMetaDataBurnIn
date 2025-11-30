import Foundation
import Combine

final class DVProcessor: ObservableObject {
    @Published var logText: String = ""
    @Published var isRunning: Bool = false

    private var task: Process?
    
    

    func runDVMetaBurn(
        mode: String,
        layout: String,
        format: String,
        burnMode: String,
        missingMeta: String,
        fontFile: String?,
        inputURL: URL,
        ffmpegPath: String,
        dvrescuePath: String
    ) {
        isRunning = true
        logText = ""

        let task = Process()

        // dvmetaburn script inside your bundle:
        guard let scriptURL = Bundle.main.url(
            forResource: "dvmetaburn",
            withExtension: nil,
            subdirectory: "scripts"
        ) else {
            logText = "Error: dvmetaburn script not found in bundle.\n"
            return
        }

        task.executableURL = scriptURL

        var args: [String] = []

        args.append("--mode=\(mode)")          // "single" or "batch"
        args.append("--layout=\(layout)")      // "stacked" or "single"
        args.append("--format=\(format)")      // "mov" or "mp4"

        args.append("--burn-mode=\(burnMode)") // "burnin" or "passthrough"
        args.append("--missing-meta=\(missingMeta)") // "error" | "skip_burnin_convert" | "skip_file"

        args.append("--ffmpeg=\(ffmpegPath)")      // e.g. bundled ffmpeg
        args.append("--dvrescue=\(dvrescuePath)")  // e.g. bundled dvrescue

        if let fontFile {
            args.append("--fontfile=\(fontFile)")
        }

        // Single file path OR folder path (for batch)
        args.append(inputURL.path)

        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.logText.append(chunk)
            }
        }

        self.task = task

        DispatchQueue.global().async {
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.logText.append("\nError: \(error.localizedDescription)\n")
                }
            }

            DispatchQueue.main.async {
                self.isRunning = false
                handle.readabilityHandler = nil
            }
        }
    }

    func cancel() {
        task?.terminate()
        isRunning = false
    }
}
