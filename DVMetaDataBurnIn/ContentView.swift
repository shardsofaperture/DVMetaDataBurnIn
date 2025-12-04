import SwiftUI
import UniformTypeIdentifiers   // for logoutput to txt
import CoreText
// MARK: - Mode enums

enum BurnMode: String, CaseIterable, Identifiable {
    case burnin
    case passthrough
    case subtitleTrack

    var id: String { rawValue }
}

enum MissingMetaMode: String, CaseIterable, Identifiable {
    case error              // stop on missing metadata
    case skipBurninConvert  // still convert file, no burn-in
    case skipFile           // skip that file, continue batch

    var id: String { rawValue }
}

// MARK: - Main view

struct ContentView: View {
    // UI state
    @State private var inputPath: String = ""
    @State private var mode: String = "single"      // "single" or "batch"
    @State private var layout: String = "stacked"   // "stacked" or "single"
    @State private var format: String = "mov"       // "mov" or "mp4"
    @State private var logText: String = ""
    @State private var isRunning: Bool = false
    @State private var showingAbout: Bool = false
    @State private var currentProcess: Process?
    @State private var fullLogText: String = ""

    // NEW OPTIONS
    @State private var burnMode: BurnMode = .burnin
    @State private var missingMetaMode: MissingMetaMode = .skipBurninConvert
    @State private var availableFonts: [SubtitleFontOption] = []
    @State private var selectedFontPath: String?
    @State private var debugMode: Bool = false

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
                    .help("Enter a single DV file or a folder of DV files to process.")

                Button("Choose…") {
                    chooseInput()
                }
                .help("Browse for a DV file or folder.")
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
                .help("Choose whether to process one file or every DV file in a folder.")
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
                .help("Select how the burned-in date and time are arranged on screen.")
            }
            
            // Format: mov vs mp4
            HStack {
                Text("Format:")
                Picker("", selection: $format) {
                    Text("MOV (DV, recommended)").tag("mov")
                    Text("MP4 (MPEG-4)").tag("mp4")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 320)
                .help("Pick the container format for the output file.")
            }
            
            // NEW: Output mode (burn-in vs convert only)
            VStack(alignment: .leading, spacing: 4) {
                Text("Output mode:")
                Picker("Burn-in output mode", selection: $burnMode) {
                    Text("Burn in metadata").tag(BurnMode.burnin)
                    Text("Convert only (no burn-in)").tag(BurnMode.passthrough)
                    Text("Embed subtitle track (soft subs)").tag(BurnMode.subtitleTrack)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: .infinity)
                .help("Choose between burning metadata into the image, keeping video unchanged, or adding a subtitle track.")
            }
            
            // Subtitle font selector
            VStack(alignment: .leading, spacing: 4) {
                Text("Subtitle font:")
                Picker("Subtitle font selection", selection: Binding(
                    get: { selectedFontPath ?? availableFonts.first?.path ?? "" },
                    set: { selectedFontPath = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(availableFonts) { option in
                        Text(option.displayName).tag(option.path)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: 320)
                .disabled(availableFonts.isEmpty)
                .labelsHidden()
                .help("Pick the font used for the burned-in or subtitle text.")

                if availableFonts.isEmpty {
                    Text("No subtitle fonts found in app bundle or system.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            // NEW: Missing metadata behavior
            VStack(alignment: .leading) {
                Text("If DV date/time is missing:")
                Picker("", selection: $missingMetaMode) {
                    Text("Stop with error").tag(MissingMetaMode.error)
                    Text("Convert without burn-in").tag(MissingMetaMode.skipBurninConvert)
                    Text("Skip file").tag(MissingMetaMode.skipFile)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 420)
                .help("Pick what to do when a clip is missing DV metadata.")
            }

            // Debug logging toggle to help capture more details
            Toggle("Enable debug logging", isOn: $debugMode)
                .help("Adds extra diagnostic output before and during processing to help troubleshoot failures.")

            // Run + dvrescue debug + Stop + Clear / Save buttons
            HStack {
                Button("Clear Log") {
                    logText = ""
                    fullLogText = ""
                }
                .help("Remove all log output from the window.")

                Button("Save Log…") {
                    saveLogToFile()
                }
                .help("Save the full session log to a text file.")

                Spacer()

                Button("dvrescue debug only") {
                    runDVRescueDebug()
                }
                .disabled(isRunning)
                .help("Run dvrescue to inspect metadata without creating output.")

                Button("Stop") {
                    stopCurrentProcess()
                }
                .disabled(!isRunning || currentProcess == nil)
                .help("Terminate the current process.")

                Button(isRunning ? "Running…" : "Run Burn-In") {
                    runBurn()
                }
                .disabled(isRunning || inputPath.isEmpty)
                .help("Start processing with the selected options.")
            }


            // Log output
            Text("Log:")
                .bold()

            ScrollView {
                Text(logText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)   // allow copy/paste
            }
            .border(Color.gray.opacity(0.4))
            .help("Live output from dvrescue, ffmpeg, and script diagnostics.")

            // About & Licenses button
            HStack {
                Spacer()
                Button("About & Licenses") {
                    showingAbout = true
                }
                .help("View app version info and license details.")
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .onAppear(perform: loadAvailableFonts)
    }   // <-- this closes var body
    
    // MARK: - Save log

    private func saveLogToFile() {
        let panel = NSSavePanel()
        panel.title = "Save Log"
        panel.nameFieldStringValue = "DVMetaLog.txt"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]   // modern API

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try fullLogText.data(using: .utf8)?.write(to: url)
            } catch {
                appendToLog("\n\n[ERROR saving log: \(error.localizedDescription)]\n", capped: true)
            }
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

    // MARK: - dvrescue debug only

    private func runDVRescueDebug() {
        let fm = FileManager.default
        var debugURL: URL?

        if !inputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fm.fileExists(atPath: inputPath) {
            let url = URL(fileURLWithPath: inputPath)
            if !url.hasDirectoryPath {
                // Use the already-selected file in the top bar
                debugURL = url
            }
        }

        // If we still don't have a file (no input or it was a folder) → ask the user
        if debugURL == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false

            if panel.runModal() == .OK, let url = panel.url {
                debugURL = url
                // also reflect it in the UI input field
                inputPath = url.path
                mode = "single"
            }
        }

        guard let url = debugURL else { return }

        logText = ""
        fullLogText = ""
        isRunning = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bundleRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
                let fm = FileManager.default

                var dvrescueURL: URL? = nil
                if let enumerator = fm.enumerator(at: bundleRoot, includingPropertiesForKeys: nil) {
                    for case let candidate as URL in enumerator {
                        if candidate.lastPathComponent == "dvrescue" {
                            dvrescueURL = candidate
                            break
                        }
                    }
                }

                guard let dvURL = dvrescueURL else {
                    throw NSError(
                        domain: "DVMeta",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey:
                                   "ERROR: Could not find dvrescue in app bundle for debug run."]
                    )
                }

                let process = Process()
                process.executableURL = dvURL
                process.arguments = [url.path]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    if data.isEmpty {
                        fh.readabilityHandler = nil
                        return
                    }
                    if let chunk = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self.appendToLog(chunk, capped: false)
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.currentProcess = process
                }

                try process.run()
                process.waitUntilExit()
                let status = process.terminationStatus

                DispatchQueue.main.async {
                    self.isRunning = false
                    self.appendToLog("\n\n[dvrescue debug exit status: \(status)]")
                    self.currentProcess = nil
                }

            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.appendToLog(
                        "\n\nERROR running dvrescue debug: \(error.localizedDescription)\n",
                        capped: false
                    )
                    self.currentProcess = nil
                }
            }
        }
    }

    // MARK: - Log helper

    private func appendToLog(_ chunk: String, capped: Bool = true) {
        // Always keep the full log
        fullLogText.append(chunk)

        // If we don't want capping (dvrescue debug), just mirror fullLogText
        guard capped else {
            logText = fullLogText
            return
        }

        // Normal path: append & cap what the UI shows
        logText.append(chunk)

        let maxChars = 50_000  // tweak if you want
        if logText.count > maxChars {
            let overflow = logText.count - maxChars
            let idx = logText.index(logText.startIndex, offsetBy: overflow)
            logText.removeSubrange(logText.startIndex..<idx)
        }
    }
    // MARK: - Stop current process

    private func stopCurrentProcess() {
        if let proc = currentProcess {
            proc.terminate()
            logText.append("\n\n[process terminated by user]")
            currentProcess = nil
        }
        isRunning = false
    }
    // MARK: - Run script

    private func runBurn() {
        guard !inputPath.isEmpty else {
            logText = "Please choose an input file or folder first."
            return
        }

        logText = ""
        fullLogText = ""
        isRunning = true

        // Capture a detailed snapshot of inputs when debug logging is enabled
        if debugMode {
            appendToLog(debugSnapshot(), capped: false)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (process, pipe) = try self.makeProcess()

                DispatchQueue.main.async {
                    self.currentProcess = process
                }

                let handle = pipe.fileHandleForReading

                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    if data.isEmpty {
                        fh.readabilityHandler = nil
                        return
                    }
                    if let chunk = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self.appendToLog(chunk)
                        }
                    }
                }

                try process.run()
                process.waitUntilExit()
                let status = process.terminationStatus

                DispatchQueue.main.async {
                    self.isRunning = false
                    self.appendToLog("\n\n[process exit status: \(status)]")
                    handle.readabilityHandler = nil
                    self.currentProcess = nil
                }

            } catch {
                DispatchQueue.main.async {
                    self.logText = "Error: \(error.localizedDescription)"
                    self.isRunning = false
                    self.currentProcess = nil
                }
            }
        }
    }

    // MARK: - Process builder

    private func makeProcess() throws -> (Process, Pipe) {
        // Use resourceURL if available, otherwise fall back to bundleURL
        let bundleRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL

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
            throw NSError(domain: "DVMeta", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "ERROR: Could not find dvmetaburn(.zsh) in app bundle (root: \(bundleRoot.path))."])
        }

        guard let ffmpegURL = findResource(named: "ffmpeg") else {
            throw NSError(domain: "DVMeta", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "ERROR: Could not find ffmpeg in app bundle."])
        }

        guard let dvrescueURL = findResource(named: "dvrescue") else {
            throw NSError(domain: "DVMeta", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "ERROR: Could not find dvrescue in app bundle."])
        }

        guard let jqURL = findResource(named: "jq") else {
            throw NSError(domain: "DVMeta", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "ERROR: Could not find jq in app bundle."])
        }

        guard let fontURL = findResource(named: "UAV-OSD-Mono.ttf") else {
            throw NSError(domain: "DVMeta", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "ERROR: Could not find UAV-OSD-Mono.ttf in app bundle."])
        }
        _ = fontURL

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

        // Map MissingMetaMode to the strings the script expects
        let missingMetaArg: String
        switch missingMetaMode {
        case .error:
            missingMetaArg = "error"
        case .skipBurninConvert:
            missingMetaArg = "skip_burnin_convert"
        case .skipFile:
            missingMetaArg = "skip_file"
        }

        var args: [String] = [
            tempScriptURL.path,
            "--mode=\(mode)",
            "--layout=\(layout)",
            "--format=\(format)",
            "--burn-mode=\(burnMode.rawValue)",   // burnin / passthrough / subtitleTrack
            "--missing-meta=\(missingMetaArg)",   // error / skip_burnin_convert / skip_file
            "--fontfile=\(resolvedFontPath())",
            "--fontname=\(resolvedFontName())",
            "--ffmpeg=\(ffmpegURL.path)",
            "--dvrescue=\(dvrescueURL.path)"
        ]

        if debugMode {
            args.append("--debug")
        }

        args.append(contentsOf: ["--", inputPath])

        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = tempDir.path
        env["DVMETABURN_JQ"] = jqURL.path
        process.environment = env
        process.currentDirectoryURL = tempDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return (process, pipe)
    }

    // MARK: - Font discovery

    private struct SubtitleFontOption: Identifiable {
        let id = UUID()
        let displayName: String
        let path: String
    }

    private func loadAvailableFonts() {
        var results: [SubtitleFontOption] = []
        let fm = FileManager.default
        let resourceRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL

        let bundleFontDirs = [
            resourceRoot.appendingPathComponent("fonts"),
            resourceRoot.appendingPathComponent("scripts/fonts")
        ]

        let systemFontDirs = [
            URL(fileURLWithPath: "/System/Library/Fonts"),
            URL(fileURLWithPath: "/Library/Fonts"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts"),
            URL(fileURLWithPath: "/usr/share/fonts"),
            URL(fileURLWithPath: "/usr/local/share/fonts")
        ]

        let searchDirs = bundleFontDirs + systemFontDirs
        let extensions = ["ttf", "otf", "ttc"]

        for dir in searchDirs {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in contents where extensions.contains(file.pathExtension.lowercased()) {
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor]
                let descriptor = descriptors?.first
                let displayName = (descriptor.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontDisplayNameAttribute) as? String })
                    ?? file.deletingPathExtension().lastPathComponent

                if !results.contains(where: { $0.path == file.path }) {
                    results.append(SubtitleFontOption(displayName: displayName, path: file.path))
                }
            }
        }

        results.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        availableFonts = results
        if selectedFontPath == nil {
            if let uavFont = results.first(where: { $0.path.localizedCaseInsensitiveContains("uav-osd-mono") }) {
                selectedFontPath = uavFont.path
            } else {
                selectedFontPath = results.first?.path
            }
        }
    }

    private func resolvedFontPath() -> String {
        let fm = FileManager.default
        if let selected = selectedFontPath, fm.fileExists(atPath: selected) {
            return selected
        }

        // Fallback to bundled font
        let bundleRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let bundledFont = bundleRoot.appendingPathComponent("fonts/UAV-OSD-Mono.ttf")
        return bundledFont.path
    }

    private func resolvedFontName() -> String {
        if let match = availableFonts.first(where: { $0.path == selectedFontPath }) {
            return match.displayName
        }
        return "UAV-OSD-Mono"
    }

    // MARK: - Debug helpers

    /// Build a human-readable snapshot of the current settings to aid debugging.
    private func debugSnapshot() -> String {
        var lines: [String] = []
        let fm = FileManager.default
        lines.append("[DEBUG] Input path: \(inputPath)")
        lines.append("[DEBUG] Input exists: \(fm.fileExists(atPath: inputPath) ? "yes" : "no")")
        lines.append("[DEBUG] Mode: \(mode) | Layout: \(layout) | Format: \(format)")
        lines.append("[DEBUG] Burn mode: \(burnMode.rawValue) | Missing metadata handling: \(missingMetaMode.rawValue)")
        lines.append("[DEBUG] Font path: \(resolvedFontPath()) | Font name: \(resolvedFontName())")
        lines.append("[DEBUG] Debug flag passed to script: on")
        return lines.joined(separator: "\n") + "\n\n"
    }
}
