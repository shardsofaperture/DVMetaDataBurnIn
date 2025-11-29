import Foundation
import Combine

final class DVProcessor: ObservableObject {
    @Published var logText: String = ""
    @Published var isRunning: Bool = false

    private var task: Process?

    func runDVRescue(on url: URL) {
        isRunning = true
        logText = ""
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/local/bin/dvrescue")
        task.arguments = [url.path]

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
