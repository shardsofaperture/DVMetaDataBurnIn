import Foundation
import Combine

final class DVProcessor: ObservableObject {
    // What the UI shows
    @Published var visibleLog: String = ""
    @Published var isRunning: Bool = false

    private var task: Process?

    // Full backing log for saving / debugging
    private var fullLog: String = ""

    // Expose read-only view so ContentView can save it
    var fullLogText: String { fullLog }

    // Helper: reset log
    func resetLog(_ header: String = "") {
        fullLog = header
        visibleLog = header
    }

    // Helper: append while keeping only tail visible
    func appendToLog(_ chunk: String) {
        fullLog.append(chunk)

        let maxVisibleChars = 200_000   // tweak as needed
        if fullLog.count > maxVisibleChars {
            let start = fullLog.index(fullLog.endIndex,
                                      offsetBy: -maxVisibleChars)
            visibleLog = String(fullLog[start...])
        } else {
            visibleLog = fullLog
        }
    }

    func clearLog() {
        fullLog = ""
        visibleLog = ""
    }

    func cancel() {
        task?.terminate()
        isRunning = false
    }
}
