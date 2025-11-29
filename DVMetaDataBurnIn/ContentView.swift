import SwiftUI

struct ContentView: View {
    // UI state
    @State private var inputPath: String = ""
    @State private var mode: String = "single"      // "single" or "batch"
    @State private var layout: String = "stacked"   // "stacked" or "single"
    @State private var format: String = "mov"       // "mov" or "mp4"
    @State private var logText: String = ""
    @State private var isRunning: Bool = false
    @State private var showingAbout: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DV Metadata Date/Time Burn-In")
                .font(.title2)
                .bold()

            // Input picker
            HStack {
                Text("Input:")
                TextField("File or folder path", text: $inputPath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button("Choose…") {
                    chooseInput()
                }
            }

            // Mode: single vs batch
            HStack {
                Text("Mode:")
                Picker("", selection: $mode) {
                    Text("Single file").tag("single")
                    Text("Batch folder").tag("batch")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 240)
            }

            // Layout: stacked vs single bar
            HStack {
                Text("Layout:")
                Picker("", selection: $layout) {
                    Text("Stacked (date over time)").tag("stacked")
                    Text("Single line").tag("single")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 320)
            }

            // Format: mov vs mp4
            HStack {
                Text("Format:")
                Picker("", selection: $format) {
                    Text("MOV (DV, recommended)").tag("mov")
                    Text("MP4 (H.264)").tag("mp4")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 320)
            }

            // Run button
            HStack {
                Spacer()
                Button(isRunning ? "Running…" : "Run Burn-In") {
                    runBurn()
                }
                .disabled(isRunning || inputPath.isEmpty)
            }

            // Log output
            Text("Log:")
                .bold()

            ScrollView {
                Text(logText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .border(Color.gray.opacity(0.4))

            // About & Licenses button
            HStack {
                Spacer()
                Button("About & Licenses") {
                    showingAbout = true
                }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
    }

    // MARK: - File / folder picker

    private func chooseInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            inputPath = url.path
            if url.hasDirectoryPath {
                mode = "batch"
            } else {
                mode = "single"
            }
        }
    }

    // MARK: - Run script

    private func runBurn() {
        logText = ""
        isRunning = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try self.invokeScript()
                DispatchQueue.main.async {
                    self.logText = output
                    self.isRunning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.logText = "Error: \(error.localizedDescription)"
                    self.isRunning = false
                }
            }
        }
    }

    private func invokeScript() throws -> String {
        guard !inputPath.isEmpty else {
            return "No input path set."
        }

        guard let bundleRoot = Bundle.main.resourceURL else {
            return "Could not locate app resources (Bundle.main.resourceURL is nil)."
        }

        let fm = FileManager.default

        func findResource(named name: String) -> URL? {
            guard let enumerator = fm.enumerator(at: bundleRoot,
                                                 includingPropertiesForKeys: nil)
            else { return nil }

            for case let url as URL in enumerator {
                if url.lastPathComponent == name {
                    return url
                }
            }
            return nil
        }

        func findScriptURL() -> URL? {
            if let u = findResource(named: "dvmetaburn.zsh") {
                return u
            }
            if let u = findResource(named: "dvmetaburn") {
                return u
            }
            return nil
        }

        guard let bundledScriptURL = findScriptURL() else {
            return "ERROR: Could not find dvmetaburn(.zsh) in app bundle (root: \(bundleRoot.path))."
        }

        guard let ffmpegURL = findResource(named: "ffmpeg") else {
            return "ERROR: Could not find ffmpeg in app bundle."
        }

        guard let dvrescueURL = findResource(named: "dvrescue") else {
            return "ERROR: Could not find dvrescue in app bundle."
        }

        guard let fontURL = findResource(named: "UAV-OSD-Mono.ttf") else {
            return "ERROR: Could not find UAV-OSD-Mono.ttf in app bundle."
        }

        // --- Copy script to a writable temp location ---
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempScriptURL = tempDir.appendingPathComponent("dvmetaburn_run.zsh")

        // Remove any previous copy
        _ = try? fm.removeItem(at: tempScriptURL)
        try fm.copyItem(at: bundledScriptURL, to: tempScriptURL)

        // Make sure it's executable
        let attrs: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o755))
        ]
        try fm.setAttributes(attrs, ofItemAtPath: tempScriptURL.path)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        process.arguments = [
            tempScriptURL.path,
            "--mode=\(mode)",
            "--layout=\(layout)",
            "--format=\(format)",
            "--fontfile=\(fontURL.path)",
            "--ffmpeg=\(ffmpegURL.path)",
            "--dvrescue=\(dvrescueURL.path)",
            "--",
            inputPath
        ]

        // Use the same temp dir for the child
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = tempDir.path
        process.environment = env
        process.currentDirectoryURL = tempDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let status = process.terminationStatus
        let combined = text + "\n\n[process exit status: \(status)]"
        return combined
        
    }


}

