import SwiftUI
import AppKit
import UniformTypeIdentifiers   // for logoutput to txt
import CoreText

// MARK: - Mode enums

enum BurnMode: String, CaseIterable, Identifiable {
    case burnin
    case off
    case subtitleTrack

    var id: String { rawValue }
}

enum SubtitleMode: String, CaseIterable, Identifiable {
    case perClip = "per-clip"
    case continuous

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
    @State private var format: String = "mov"       // "mov", "mp4", or "mkv"
    @State private var mp4Preset: String = ""
    @State private var logText: String = ""
    @State private var isRunning: Bool = false
    @State private var showingAbout: Bool = false
    @State private var currentProcess: Process?
    @State private var fullLogText: String = ""
    @State private var stitchMode: String = "none"   // "none" or "stitch"

    // NEW OPTIONS
    @State private var burnMode: BurnMode = .burnin
    @State private var missingMetaMode: MissingMetaMode = .skipBurninConvert
    @State private var subtitleMode: SubtitleMode?
    @State private var camcorderFonts: [SubtitleFontOption] = []
    @State private var systemFonts: [SubtitleFontOption] = []
    @State private var selectedFontPath: String?
    @State private var includeSystemFonts: Bool = false
    @State private var hoveredFontPreviewName: String?
    @State private var hoveredLayoutPreviewName: String?
    @State private var outputToLocationFolder: Bool = false
    @State private var scratchDirectory: String =
        UserDefaults.standard.string(forKey: "DVMetaScratchDirectory") ?? ""
    @State private var debugMode: Bool = false
    @State private var selectedOutputFolder: String? =
        UserDefaults.standard.string(forKey: "DVMetaLastOutputFolder")
    @State private var defaultOutputFolder: String? =
        UserDefaults.standard.string(forKey: "DVMetaDefaultOutputFolder")

    private var shouldBlockStart: Bool {
        burnMode == .subtitleTrack && subtitleMode == nil
    }

    //font preview handling
    private var activeFontPreviewName: String? {
        if let hover = hoveredFontPreviewName {
            return hover
        }
        if let selected = displayedFonts.first(where: { $0.path == selectedFontPath }) {
            return selected.previewAssetName
        }
        return nil
    }
    
    private func registerFontIfNeeded(at path: String) {
        let url = URL(fileURLWithPath: path)
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok {
            _ = error?.takeRetainedValue()
        }
    }

    private var previewFontName: String? {
        if let selected = displayedFonts.first(where: { $0.path == selectedFontPath }) {
            return selected.fontName ?? selected.displayName
        }
        return nil
    }
    
    private var activeLayoutPreviewName: String? {
        if let hover = hoveredLayoutPreviewName {
            return hover
        }
        switch layout {
        case "stacked":
            return "OverlayPreview_Stacked"
        case "single":
            return "OverlayPreview_Bar"
        default:
            return nil
        }
    }
    
    private var displayedFonts: [SubtitleFontOption] {
        camcorderFonts + (includeSystemFonts ? systemFonts : [])
    }

    private let camcorderFontPreviews: [String: String] = [
        "UAV-OSD-Mono.ttf": "FontPreview_UAVOSDMono",
        "UAV-OSD-Sans-Mono.ttf": "FontPreview_UAVOSDSANS",
        "VCR_OSD_MONO.ttf": "FontPreview_VCROSDMONO"
    ]

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
            // Stitch / string clips together (only meaningful for batch + burnin/subtitleTrack)
            if mode == "batch" && burnMode != .off {
                HStack(spacing: 12) {
                    Text("Stitch:")
                        .frame(width: 110, alignment: .leading)

                    Picker("", selection: $stitchMode) {
                        Text("No").tag("none")
                        Text("Yes (one output file)").tag("stitch")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 320)
                    .help("When enabled in batch mode, concatenates clips before burn-in/subtitle generation to produce one output file.")
                }
            } else {
                // keep state sane if user flips modes
                // (optional but prevents stale stitch selection)
                EmptyView()
                    .onAppear { stitchMode = "none" }
            }

            
            // Layout: stacked vs single bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Layout:")

                    Picker("", selection: $layout) {
                        Text("Stacked (date over time)")
                            .tag("stacked")
                            .onHover { hovering in
                                hoveredLayoutPreviewName = hovering ? "OverlayPreview_Stacked" : nil
                            }

                        Text("Single line")
                            .tag("single")
                            .onHover { hovering in
                                hoveredLayoutPreviewName = hovering ? "OverlayPreview_Bar" : nil
                            }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 320)
                    .help("Select how the burned-in date and time are arranged on screen.")
                }

                if let preview = activeLayoutPreviewName {
                    HStack {
                        Spacer().frame(width: 72)
                        Image(preview)
                            .resizable()
                            .aspectRatio(4/3, contentMode: .fit)
                            .frame(width: 260, height: 150)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .transition(.opacity)
                }
            }

            if burnMode == .subtitleTrack {
                HStack(spacing: 12) {
                    Text("Subtitle timing:")
                        .frame(width: 110, alignment: .leading)

                    Picker("", selection: $subtitleMode) {
                        Text("Per clip").tag(SubtitleMode.perClip as SubtitleMode?)
                        Text("Continuous").tag(SubtitleMode.continuous as SubtitleMode?)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 320)
                    .help("Choose whether subtitle metadata restarts per clip or flows continuously across files.")
                }
                .padding(.top, 2)
                .onChange(of: burnMode) { newMode in
                    if newMode == .subtitleTrack {
                        if subtitleMode == nil { subtitleMode = .perClip }
                        // subtitleTrack forces mkv (optional UI-side convenience)
                        if format != "mkv" { format = "mkv" }
                    } else {
                        subtitleMode = nil
                    }
                }
            }
             

            // Format + preset area (kept together so it never overlaps subtitle timing)
            VStack(alignment: .leading, spacing: 10) {

                HStack(spacing: 12) {
                    Text("Format:")
                        .frame(width: 110, alignment: .leading)

                    Picker("", selection: $format) {
                        Text("MOV (DV, Passthrough)").tag("mov")
                        Text("MP4 (MPEG-4, Transcode)").tag("mp4")
                        Text("MKV (Matroska)").tag("mkv")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 420)
                    .help("Pick the container format for the output file.")
                }

                if format == "mp4" {
                    HStack(spacing: 12) {
                        Text("MP4 preset:")
                            .frame(width: 110, alignment: .leading)

                        Picker("", selection: $mp4Preset) {
                            Text("Best quality").tag("best-quality")
                            Text("Default").tag("default")
                            Text("Audio only").tag("audio-only")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 420)
                        .help("Choose an encoding preset for MP4 outputs.")
                    }
                }
            }
            .onChange(of: format) { newValue in
                if newValue == "mp4" {
                    if mp4Preset.isEmpty { mp4Preset = "default" }
                } else {
                    mp4Preset = ""
                }
            }


            // Output location toggle (stays up here)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Choose output folder before processing",
                       isOn: $outputToLocationFolder)
                    .help("When enabled, ask where to save all outputs instead of using the source folder.")

                HStack(spacing: 12) {
                    Text("Scratch Disk:")
                        .frame(width: 150, alignment: .leading)

                    TextField("Optional scratch directory", text: $scratchDirectory)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .help("Overrides temporary + artifact storage. Leave blank for default or set DVMETA_SCRATCH_DIR.")

                    Button("Choose…") {
                        chooseScratchDirectory()
                    }
                    .help("Pick a folder to use for scratch/temp files.")
                }
            }
            .padding(.top, 4)

            // Output mode (burn-in vs convert only vs subs)
            VStack(alignment: .leading, spacing: 4) {
                Picker("Burn-in output mode", selection: $burnMode) {
                    Text("Burn in metadata").tag(BurnMode.burnin)
                    Text("Transcode only (no burn-in)").tag(BurnMode.off)
                    Text("Embed subtitle track (soft subs in MKV)").tag(BurnMode.subtitleTrack)
                }
                .pickerStyle(.menu)
                .frame(width: 340, alignment: .leading)
                .help("Choose between burning metadata into the image, keeping video unchanged, or adding a subtitle track.")
            }
            
            // Subtitle font selector
            HStack(alignment: .top, spacing: 24) {
                // Left column: label + picker + toggle
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Subtitle font:")

                        Menu {
                            Section("Camcorder fonts") {
                                ForEach(camcorderFonts) { option in
                                    fontMenuItem(option)
                                }
                            }

                            if includeSystemFonts {
                                Section("System fonts") {
                                    ForEach(systemFonts) { option in
                                        fontMenuItem(option)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(currentFontSelectionName())
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 4)

                                Image(systemName: "chevron.down")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.2))
                            )
                        }
                        .frame(width: 220, alignment: .leading)
                        .disabled(displayedFonts.isEmpty)
                    }

                    Toggle("Include system fonts", isOn: $includeSystemFonts)
                        .onChange(of: includeSystemFonts) { _ in
                            normalizeSelectedFont()
                        }
                }

                // Right column: live font preview box
                if let fontName = previewFontName {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )

                        Text("12/22/2025\n08:29:35")
                            .font(.custom(fontName, size: 24))
                            .monospacedDigit()
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.9), radius: 2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 260, height: 90)
                }

                Spacer(minLength: 0)
            }

            // Controls: log buttons on left, run controls on right
            HStack(alignment: .top) {
                // Left: Clear / dvrescue, Open temp / Save log
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Clear Log") {
                            logText = ""
                            fullLogText = ""
                        }
                        .help("Remove all log output from the window.")

                        Button("dvrescue debug only") {
                            runDVRescueDebug()
                        }
                        .disabled(isRunning)
                        .help("Run dvrescue to inspect metadata without creating output.")
                    }

                    HStack {
                        Button("Open temp folder") {
                            openTempFolder()
                        }
                        .help("Open the DVMeta log/artifact folder in Finder.")

                        Button("Save Log…") {
                            saveLogToFile()
                        }
                        .help("Save the full session log to a text file.")
                    }
                }

                Spacer()

                // Right: Stop / Start, then choose output folder button under them
                VStack(alignment: .trailing, spacing: 4) {

                    HStack(spacing: 8) {
                        let coneOrange = Color(red: 1.0, green: 0.4, blue: 0.0)

                        // START button — cone orange
                        Button(action: { runBurn() }) {
                            Text(isRunning ? "Running…" : "Start Burn/Encode")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(width: 150, height: 22)   // FIXED HEIGHT
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill((isRunning || inputPath.isEmpty || shouldBlockStart)
                                              ? coneOrange.opacity(0.45)
                                              : coneOrange)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunning || inputPath.isEmpty || shouldBlockStart)

                        // STOP button — match *same height + corner radius*
                        Button(action: { stopCurrentProcess() }) {
                            Text("Stop")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .frame(width: 70, height: 22)   // EXACT SAME HEIGHT
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isRunning ? Color.red : Color.gray.opacity(0.5))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isRunning || currentProcess == nil)
                    }

                    // existing button – leave this as-is
                    Button("Choose output folder…") {
                        if promptForOutputFolder() {
                            outputToLocationFolder = true
                        }
                    }
                    .disabled(isRunning)
                    .help("Pick a destination folder for processed files.")
                }
            }

            // Enhanced debug toggle lives near the log now
            Toggle("Enhanced debug logging", isOn: $debugMode)
                .help("Include extra script settings and debug details at the top of the log.")
                .padding(.top, 4)

            // Log output
            Text("Log:")
                .bold()

            ScrollView {
                Text(logText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
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
    }
    
    // MARK: - Save log

    private func saveLogToFile() {
        let panel = NSSavePanel()
        panel.title = "Save Log"
        panel.nameFieldStringValue = "DVMetaLog.txt"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try fullLogText.data(using: .utf8)?.write(to: url)
            } catch {
                appendToLog("\n\n[ERROR saving log: \(error.localizedDescription)]\n", capped: true)
            }
        }
    }

    // MARK: - Open temp / artifact folder

    private func openTempFolder() {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("DVMeta")

        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }

        NSWorkspace.shared.open(base)
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

    // MARK: - Output folder picker

    @discardableResult
    private func promptForOutputFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"

        if let def = defaultOutputFolder, !def.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: def, isDirectory: true)
        } else if let existing = selectedOutputFolder, !existing.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: existing, isDirectory: true)
        } else {
            let trimmedInput = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedInput.isEmpty {
                let inputURL = URL(fileURLWithPath: trimmedInput)
                if inputURL.hasDirectoryPath {
                    panel.directoryURL = inputURL
                } else {
                    panel.directoryURL = inputURL.deletingLastPathComponent()
                }
            }
        }

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            selectedOutputFolder = path

            UserDefaults.standard.set(path, forKey: "DVMetaLastOutputFolder")

            if defaultOutputFolder == nil {
                defaultOutputFolder = path
                UserDefaults.standard.set(path, forKey: "DVMetaDefaultOutputFolder")
            }
            return true
        }

        return false
    }

    private func chooseScratchDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"

        if !scratchDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: scratchDirectory, isDirectory: true)
        }

        if panel.runModal() == .OK, let url = panel.url {
            scratchDirectory = url.path
            UserDefaults.standard.set(url.path, forKey: "DVMetaScratchDirectory")
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
                debugURL = url
            }
        }

        if debugURL == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false

            if panel.runModal() == .OK, let url = panel.url {
                debugURL = url
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
        fullLogText.append(chunk)

        guard capped else {
            logText = fullLogText
            return
        }

        logText.append(chunk)

        let maxChars = 50_000
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

        if burnMode == .subtitleTrack && subtitleMode == nil {
            logText = "Please choose a subtitle timing mode before starting."
            return
            
        }

        if outputToLocationFolder && (selectedOutputFolder?.isEmpty ?? true) {
            if !promptForOutputFolder() {
                logText = "Output cancelled. Please choose an output folder or disable the location override."
                return
            }
        }

        logText = ""
        fullLogText = ""
        isRunning = true

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

        guard let fontURL = findResource(named: "UAV-OSD-Mono.ttf") else {
            throw NSError(domain: "DVMeta", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "ERROR: Could not find UAV-OSD-Mono.ttf in app bundle."])
        }
        _ = fontURL

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempScriptURL = tempDir.appendingPathComponent("dvmetaburn_run.zsh")

        _ = try? fm.removeItem(at: tempScriptURL)
        try fm.copyItem(at: bundledScriptURL, to: tempScriptURL)

        let attrs: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o755))
        ]
        try fm.setAttributes(attrs, ofItemAtPath: tempScriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

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
            "--missing-meta=\(missingMetaArg)",
            "--fontfile=\(resolvedFontPath())",
            "--fontname=\(resolvedFontName())",
            "--ffmpeg=\(ffmpegURL.path)",
            "--dvrescue=\(dvrescueURL.path)"
        ]
        if mode == "batch" && stitchMode == "stitch" && burnMode != .off {
            args.append("--stitch-mode=stitch")
        }

        switch burnMode {
        case .burnin:
            args.append("--burn-mode=\(BurnMode.burnin.rawValue)")
        case .off:
            args.append("--burn-mode=\(BurnMode.off.rawValue)")
        case .subtitleTrack:
            args.append("--burn-mode=\(BurnMode.subtitleTrack.rawValue)")
            if let subtitleMode {
                args.append("--subtitle-mode=\(subtitleMode.rawValue)")
            }
        }

        if format == "mp4" {
            let resolvedPreset = mp4Preset.isEmpty ? "default" : mp4Preset
            args.append("--preset=\(resolvedPreset)")
        } else if !mp4Preset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(
                domain: "DVMeta",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey:
                           "ERROR: MP4 presets can only be used when the output format is set to MP4."]
            )
        }

        if debugMode {
            args.append("--debug")
        }

        if outputToLocationFolder, let destination = selectedOutputFolder, !destination.isEmpty {
            args.append("--dest-dir=\(destination)")
        }

        let trimmedScratch = scratchDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedScratch.isEmpty {
            args.append("--scratch-dir=\(trimmedScratch)")
        }

        args.append(contentsOf: ["--", inputPath])

        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = tempDir.path
        process.environment = env
        process.currentDirectoryURL = tempDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return (process, pipe)
    }

    // MARK: - Font discovery

    private enum SubtitleFontSource {
        case camcorder
        case system
    }

    private struct SubtitleFontOption: Identifiable {
        let id = UUID()
        let displayName: String
        let path: String
        let source: SubtitleFontSource
        let previewAssetName: String?
        let fontName: String?
    }

    private func loadAvailableFonts() {
        let fm = FileManager.default
        let resourceRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL

        let extensions = ["ttf", "otf", "ttc"]
        var camcorderResults: [SubtitleFontOption] = []
        var systemResults: [SubtitleFontOption] = []

        if let enumerator = fm.enumerator(at: resourceRoot, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator {
                guard extensions.contains(file.pathExtension.lowercased()) else { continue }
                guard camcorderFontPreviews.keys.contains(file.lastPathComponent) else { continue }

                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor]
                let descriptor = descriptors?.first

                let displayName =
                    (descriptor.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontDisplayNameAttribute) as? String })
                    ?? file.deletingPathExtension().lastPathComponent

                let postScriptName =
                    descriptor.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }

                if !camcorderResults.contains(where: { $0.path == file.path }) {
                    camcorderResults.append(
                        SubtitleFontOption(
                            displayName: displayName,
                            path: file.path,
                            source: .camcorder,
                            previewAssetName: camcorderFontPreviews[file.lastPathComponent],
                            fontName: postScriptName
                        )
                    )
                }
            }
        }

        let systemFontDirs = [
            URL(fileURLWithPath: "/System/Library/Fonts"),
            URL(fileURLWithPath: "/Library/Fonts"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts"),
            URL(fileURLWithPath: "/usr/share/fonts"),
            URL(fileURLWithPath: "/usr/local/share/fonts")
        ]

        for dir in systemFontDirs {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in contents where extensions.contains(file.pathExtension.lowercased()) {
                if camcorderResults.contains(where: { $0.path == file.path }) { continue }

                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor]
                let descriptor = descriptors?.first

                let displayName =
                    (descriptor.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontDisplayNameAttribute) as? String })
                    ?? file.deletingPathExtension().lastPathComponent

                let postScriptName =
                    descriptor.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }

                if !systemResults.contains(where: { $0.path == file.path }) {
                    systemResults.append(
                        SubtitleFontOption(
                            displayName: displayName,
                            path: file.path,
                            source: .system,
                            previewAssetName: nil,
                            fontName: postScriptName
                        )
                    )
                }
            }
        }

        camcorderResults.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        systemResults.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        camcorderFonts = camcorderResults
        systemFonts = systemResults
        normalizeSelectedFont()
    }

    private func resolvedFontPath() -> String {
        let fm = FileManager.default
        if let selected = selectedFontPath, fm.fileExists(atPath: selected) {
            return selected
        }

        let bundleRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let bundledFont = bundleRoot.appendingPathComponent("fonts/UAV-OSD-Mono.ttf")
        return bundledFont.path
    }

    private func resolvedFontName() -> String {
        if let match = displayedFonts.first(where: { $0.path == selectedFontPath }) {
            return match.displayName
        }
        return "UAV-OSD-Mono"
    }

    private func currentFontSelectionName() -> String {
        if let match = displayedFonts.first(where: { $0.path == selectedFontPath }) {
            return match.displayName
        }

        if let uavDefault = camcorderFonts.first(where: { $0.path.localizedCaseInsensitiveContains("uav-osd-mono") }) {
            return uavDefault.displayName
        }

        return "Choose font"
    }

    private func normalizeSelectedFont() {
        let fm = FileManager.default
        if let selectedFontPath,
           displayedFonts.contains(where: { $0.path == selectedFontPath }),
           fm.fileExists(atPath: selectedFontPath) {
            return
        }

        if let uavFont = camcorderFonts.first(where: { $0.path.localizedCaseInsensitiveContains("uav-osd-mono") }) {
            selectedFontPath = uavFont.path
            return
        }

        selectedFontPath = displayedFonts.first?.path
    }

    @ViewBuilder
    private func fontMenuItem(_ option: SubtitleFontOption) -> some View {
        Button {
            registerFontIfNeeded(at: option.path)
            selectedFontPath = option.path
        } label: {
            HStack {
                if selectedFontPath == option.path {
                    Image(systemName: "checkmark")
                }
                Text(option.displayName)
            }
        }
    }

    // MARK: - Debug helpers

    private func debugSnapshot() -> String {
        var lines: [String] = []
        let fm = FileManager.default
        let inputExists = fm.fileExists(atPath: inputPath) ? "yes" : "no"
        let systemFontsEnabled = includeSystemFonts ? "yes" : "no"
        let debugFlag = debugMode ? "on" : "off"
        let subtitleModeValue = subtitleMode?.rawValue ?? "(none selected)"

        lines.append("[DEBUG] Input path: \(inputPath)")
        lines.append("[DEBUG] Input exists: \(inputExists)")
        lines.append("[DEBUG] Mode: \(mode) | Layout: \(layout) | Format: \(format)")
        if format == "mp4" {
            let preset = mp4Preset.isEmpty ? "default" : mp4Preset
            lines.append("[DEBUG] MP4 preset: \(preset)")
        } else if !mp4Preset.isEmpty {
            lines.append("[DEBUG] MP4 preset ignored for format: \(format)")
        }
        lines.append("[DEBUG] Burn mode: \(burnMode.rawValue) | Missing metadata handling: \(missingMetaMode.rawValue)")
        lines.append("[DEBUG] Subtitle timing mode: \(subtitleModeValue)")
        lines.append("[DEBUG] Font path: \(resolvedFontPath()) | Font name: \(resolvedFontName())")
        lines.append("[DEBUG] System fonts enabled: \(systemFontsEnabled)")
        if outputToLocationFolder {
            let destination = selectedOutputFolder ?? "(none chosen)"
            lines.append("[DEBUG] Output destination: \(destination)")
        } else {
            lines.append("[DEBUG] Output destination: source folder")
        }
        lines.append("[DEBUG] Debug flag passed to script: \(debugFlag)")
        return lines.joined(separator: "\n") + "\n\n"
    }
}
