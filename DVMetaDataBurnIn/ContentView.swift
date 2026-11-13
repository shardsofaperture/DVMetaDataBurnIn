import SwiftUI
import AppKit
import UniformTypeIdentifiers   // for logoutput to txt
import Foundation
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

enum OutputMode: String, CaseIterable, Identifiable {
    case video
    case audioOnly

    var id: String { rawValue }
}

enum MissingMetaMode: String, CaseIterable, Identifiable {
    case error              // stop on missing metadata
    case skipBurninConvert  // still convert file, no burn-in
    case skipFile           // skip that file, continue batch

    var id: String { rawValue }
}

enum InputMode: String, CaseIterable, Identifiable {
    case singleFile = "single"
    case batchFolder = "batch"
    case folderQueue = "folderQueue"

    var id: String { rawValue }

    var scriptValue: String {
        switch self {
        case .singleFile:
            return "single"
        case .batchFolder, .folderQueue:
            return "batch"
        }
    }

    var displayName: String {
        switch self {
        case .singleFile:
            return "Single file"
        case .batchFolder:
            return "Batch folder"
        case .folderQueue:
            return "Folder queue"
        }
    }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case mov
    case mp4
    case mkv

    var id: String { rawValue }
}

enum DeinterlaceMode: String, CaseIterable, Identifiable {
    case off = "off"
    case p30 = "30p"
    case p60 = "60p"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .p30:
            return "30p"
        case .p60:
            return "60p"
        }
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var qscale: Int {
        switch self {
        case .low:
            return 5
        case .medium:
            return 3
        case .high:
            return 2
        }
    }
}

struct ResolvedQuality {
    let selection: Quality
    let qscale: Int?
    let audioBitrateKbps: Int?

    var isPassthrough: Bool {
        qscale == nil
    }
}

struct BurnSettingsSnapshot: Hashable {
    let inputMode: InputMode
    let burnMode: BurnMode
    let missingMetaMode: MissingMetaMode
    let subtitleMode: SubtitleMode?
    let layout: String
    let format: OutputFormat
    let quality: Quality
    let deinterlace: DeinterlaceMode
    let outputMode: OutputMode
    let stitchBatch: Bool
    let destinationOverride: String?
    let scratchDirectory: String?
    let debugMode: Bool
    let resolvedFontPath: String
    let resolvedFontName: String
    let outputToLocationFolder: Bool
    let advancedFFmpegOptions: Bool
    let extraFFmpegArgsText: String
    let sanitizedExtraArgs: [String]
    let extraArgWarnings: [String]
    let rawExtraArgs: String?

    var summaryDescription: String {
        var parts: [String] = []
        parts.append("Burn: \(burnMode.rawValue)")
        parts.append("Missing: \(missingMetaMode.rawValue)")
        if let subtitleMode {
            parts.append("Subs: \(subtitleMode.rawValue)")
        }
        parts.append("Layout: \(layout)")
        parts.append("Format: \(format.rawValue)")
        parts.append("Quality: \(quality.rawValue)")
        if outputMode == .video {
            parts.append("Deinterlace: \(deinterlace.rawValue)")
        }
        parts.append("Output: \(outputMode.rawValue)")
        if stitchBatch {
            parts.append("Stitch on")
        }
        if let destinationOverride, !destinationOverride.isEmpty {
            parts.append("Dest: \(destinationOverride)")
        }
        return parts.joined(separator: " · ")
    }

    var queueSummaryDescription: String {
        let stitchLabel = stitchBatch ? "on" : "off"
        let deinterlacePart = outputMode == .video ? " · Deinterlace: \(deinterlace.rawValue)" : ""
        return "Burn: \(burnMode.rawValue) · Stitch: \(stitchLabel) · Quality: \(quality.rawValue)\(deinterlacePart)"
    }

    var isBatchMode: Bool { inputMode != .singleFile }
}

struct QueueEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String
    var settingsSnapshot: BurnSettingsSnapshot

    var url: URL { URL(fileURLWithPath: path) }

    var displayName: String {
        url.lastPathComponent
    }

    var outputBaseName: String {
        url.deletingPathExtension().lastPathComponent
    }
}

func resolveQuality(
    _ selection: Quality,
    format: OutputFormat,
    outputMode: OutputMode
) -> ResolvedQuality {
    let qscale: Int?
    let audioBitrate: Int?

    if outputMode == .audioOnly {
        switch selection {
        case .low:
            audioBitrate = 128
        case .medium:
            audioBitrate = 192
        case .high:
            audioBitrate = 256
        }

        return ResolvedQuality(selection: selection, qscale: nil, audioBitrateKbps: audioBitrate)
    }

    switch format {
    case .mov:
        return ResolvedQuality(selection: selection, qscale: nil, audioBitrateKbps: 192)
    case .mp4, .mkv:
        qscale = selection.qscale
    }

    return ResolvedQuality(selection: selection, qscale: qscale, audioBitrateKbps: 192)
}

func qscaleToCRF(_ qscale: Int) -> Int {
    // Map legacy qscale values to a reasonable H.264 CRF range (lower is better)
    return max(10, min(40, 16 + (qscale * 2)))
}

func buildCodecArgs(format: OutputFormat, resolvedQuality: ResolvedQuality, outputMode: OutputMode) -> [String] {
    if outputMode == .audioOnly {
        let bitrate = resolvedQuality.audioBitrateKbps ?? 192
        return ["-vn", "-c:a", "aac", "-b:a", "\(bitrate)k"]
    }

    if resolvedQuality.isPassthrough {
        if format == .mov {
            return ["-c:v", "dvvideo", "-c:a", "pcm_s16le"]
        }

        return ["-c:v", "copy", "-c:a", "copy"]
    }

    guard let qscale = resolvedQuality.qscale else {
        return ["-c:v", "copy", "-c:a", "copy"]
    }

    let crf = qscaleToCRF(qscale)
    return ["-c:v", "libx264", "-crf", "\(crf)", "-preset", "medium", "-c:a", "aac", "-b:a", "192k"]
}

func outputExtension(for format: OutputFormat, outputMode: OutputMode) -> String {
    guard outputMode == .audioOnly else { return format.rawValue.lowercased() }

    switch format {
    case .mkv:
        return "mka"
    default:
        return "m4a"
    }
}


// MARK: - Main view
struct ContentView: View {
    // UI state
    @State private var inputPath: String = ""
    @State private var inputMode: InputMode = .singleFile
    @State private var layout: String = "stacked"   // "stacked" or "single"
    @State private var format: OutputFormat = .mp4
    @State private var quality: Quality = .medium
    @State private var deinterlaceMode: DeinterlaceMode = .p30
    @State private var outputMode: OutputMode = .video
    @State private var logText: String = ""
    @State private var isRunning: Bool = false
    @State private var isProcessing: Bool = false
    @State private var runID: String = ""
    @State private var showingAbout: Bool = false
    @State private var lastWorkspaceURL: URL?
    @State private var cancellationRequested = false
    @State private var currentProcess: Process?
    @State private var fullLogText: String = ""
    @State private var stitchBatch: Bool = false
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
    @State private var hoveredQuality: Quality?
    @State private var outputToLocationFolder: Bool = false
    @State private var folderQueue: [QueueEntry] = []
    @State private var isFolderDropTarget: Bool = false
    @State private var scratchDirectory: String =
        UserDefaults.standard.string(forKey: "DVMetaScratchDirectory") ?? ""
    @AppStorage("DVMetaAdvancedFFmpegOptions")
    private var advancedFFmpegOptions: Bool = false
    @AppStorage("DVMetaExtraFFmpegArgsText")
    private var extraFFmpegArgsText: String = ""
    private let placeholderText = """
    # Optional: extra ffmpeg flags (leave unchanged to ignore)
    # Examples:
    #   -b:v 6M -maxrate 8M -bufsize 16M
    #   -preset slow
    """
    @State private var debugMode: Bool = false
    @State private var selectedOutputFolder: String? =
        UserDefaults.standard.string(forKey: "DVMetaLastOutputFolder")
    @State private var defaultOutputFolder: String? =
        UserDefaults.standard.string(forKey: "DVMetaDefaultOutputFolder")
    @State private var isLogExpanded: Bool = true

    private var startBlockReason: String? {
        if outputToLocationFolder && sanitizedDestinationOverride() == nil {
            return "Choose an output folder before starting."
        }

        if outputMode == .audioOnly {
            return nil
        }

        if burnMode == .subtitleTrack && subtitleMode == nil {
            return "Choose a subtitle timing mode before starting."
        }

        return nil
    }

    private func startBlockReason(for snapshot: BurnSettingsSnapshot) -> String? {
        if snapshot.outputToLocationFolder && snapshot.destinationOverride == nil {
            return "Choose an output folder before starting."
        }

        if snapshot.outputMode == .audioOnly {
            return nil
        }

        if snapshot.burnMode == .subtitleTrack && snapshot.subtitleMode == nil {
            return "Choose a subtitle timing mode before starting."
        }

        return nil
    }

    private var shouldBlockStart: Bool {
        startBlockReason != nil
    }

    private var isBatchMode: Bool {
        inputMode != .singleFile
    }

    private var activeInputPath: String {
        switch inputMode {
        case .folderQueue:
            if let first = folderQueue.first { return first.path }
            return ""
        case .singleFile, .batchFolder:
            return inputPath
        }
    }

    private var hasInputPath: Bool {
        !activeInputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resolvedInputURL: URL? {
        let trimmed = activeInputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    private func sanitizedDestinationOverride() -> String? {
        guard outputToLocationFolder else { return nil }

        let trimmed = selectedOutputFolder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedDestinationPath(for input: String, destinationOverride: String? = nil) -> String? {
        if let override = destinationOverride ?? sanitizedDestinationOverride() {
            return override
        }

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }

        let inputURL = URL(fileURLWithPath: trimmedInput)
        if inputURL.hasDirectoryPath {
            return inputURL.path
        }

        return inputURL.deletingLastPathComponent().path
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

    private var qualityPickerDisabled: Bool {
        format == .mov || outputMode == .audioOnly
    }

    private func qualityDescription(for option: Quality) -> String {
        let resolvedQuality = resolveQuality(option, format: format, outputMode: outputMode)

        if outputMode == .audioOnly {
            let bitrate = resolvedQuality.audioBitrateKbps ?? 192
            return "\(option.displayName): AAC \(bitrate)k audio transcode (lower = smaller, higher = cleaner)."
        }

        if resolvedQuality.isPassthrough {
            return "\(option.displayName): DV passthrough (quality ignored)."
        }

        let crf = qscaleToCRF(resolvedQuality.qscale ?? option.qscale)
        return "\(option.displayName): H.264 (libx264) CRF \(crf), preset medium. Lower = smaller files, higher = cleaner image. Audio stays AAC 192k unless overridden."
    }

    private func qualityExample(for option: Quality) -> String {
        let resolvedQuality = resolveQuality(option, format: format, outputMode: outputMode)

        if outputMode == .audioOnly {
            let bitrate = resolvedQuality.audioBitrateKbps ?? 192
            return "Example: AAC \(bitrate)k audio-only."
        }

        if resolvedQuality.isPassthrough {
            return "Example: DV video passthrough with PCM audio."
        }

        let crf = qscaleToCRF(resolvedQuality.qscale ?? option.qscale)
        return "Example: H.264 CRF \(crf) · preset medium · AAC 192k audio."
    }

    private let camcorderFontPreviews: [String: String] = [
        "UAV-OSD-Mono.ttf": "FontPreview_UAVOSDMono",
        "UAV-OSD-Sans-Mono.ttf": "FontPreview_UAVOSDSANS",
        "VCR_OSD_MONO.ttf": "FontPreview_VCROSDMONO"
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            logPanel

            VStack(alignment: .leading, spacing: 16) {
                Text("DV Metadata Date/Time Burn-In")
                    .font(.title2)
                    .bold()

            // Input picker
            if inputMode != .folderQueue {
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
            }

            // Mode: single vs batch
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Mode:")
                    Picker("", selection: $inputMode) {
                        ForEach(InputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 360)
                    .help("Choose whether to process one file, a batch folder, or a queue of folders.")

                    if inputMode == .folderQueue {
                        Spacer()
                        Button("Add Folders…") {
                            chooseInput()
                        }
                        .help("Append folders to the queue using the file picker.")

                        Button("Clear") {
                            folderQueue.removeAll()
                        }
                        .disabled(folderQueue.isEmpty)
                        .help("Remove all queued folders.")

                    }
                }

                if isBatchMode {
                    Toggle(
                        "Stitch batch files together into one file",
                        isOn: $stitchBatch
                    )
                    .toggleStyle(.checkbox)
                    .help("Produces one final stitched output instead of per-clip files.")
                }
            }
            .onChange(of: inputMode) { newMode in
                if newMode == .singleFile {
                    stitchBatch = false
                }
            }

            if inputMode == .folderQueue {
                folderQueueView
            }
            HStack {
                Text("Output:")
                Picker("", selection: $outputMode) {
                    Text("Video (burn-in or subtitles)").tag(OutputMode.video)
                    Text("Audio only").tag(OutputMode.audioOnly)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 320)
                .help("Select whether to create video outputs or extract audio only.")
            }
            .onChange(of: outputMode) { newMode in
                if newMode == .audioOnly {
                    burnMode = .off
                    subtitleMode = nil
                }
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
            .disabled(outputMode == .audioOnly)
            .opacity(outputMode == .audioOnly ? 0.5 : 1.0)

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
                .disabled(outputMode == .audioOnly)
                .opacity(outputMode == .audioOnly ? 0.5 : 1.0)
            }
             

            // Format + quality area (kept together so it never overlaps subtitle timing)
            VStack(alignment: .leading, spacing: 10) {

                HStack(spacing: 12) {
                    Text("Format:")
                        .frame(width: 110, alignment: .leading)

                    Picker("", selection: $format) {
                        Text("MOV (DV, Passthrough)").tag(OutputFormat.mov)
                        Text("MP4 (H.264, Transcode)").tag(OutputFormat.mp4)
                        Text("MKV (H.264, Transcode)").tag(OutputFormat.mkv)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 420)
                    .help("Pick the container format for the output file.")
                    .onChange(of: format) { newValue in
                        guard newValue == .mov else { return }
                        if deinterlaceMode != .off {
                            deinterlaceMode = .off
                            appendToLog("[INFO] Deinterlace disabled for MOV passthrough.\n")
                        }
                    }
                }

                Text("MOV = DV passthrough only · MP4 / MKV = transcode")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Text("Quality:")
                        .frame(width: 110, alignment: .leading)

                    Picker("", selection: $quality) {
                        ForEach(Quality.allCases) { option in
                            Text(option.displayName)
                                .tag(option)
                                .onHover { hovering in
                                    hoveredQuality = hovering ? option : nil
                                }
                                .help(qualityDescription(for: option))
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 320)
                    .help("Choose the transcode quality for MP4 or MKV outputs.")
                    .disabled(qualityPickerDisabled)
                    .opacity(qualityPickerDisabled ? 0.5 : 1.0)

                    Text("Deinterlace:")
                        .frame(width: 110, alignment: .leading)

                    Picker("", selection: $deinterlaceMode) {
                        ForEach(DeinterlaceMode.allCases) { option in
                            Text(option.displayName)
                                .tag(option)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 220)
                    .help("Apply deinterlacing when transcoding.")
                    .disabled(format == .mov)
                    .opacity(format == .mov ? 0.5 : 1.0)
                }

                if let hoveredQuality, !qualityPickerDisabled, outputMode == .video {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(qualityDescription(for: hoveredQuality))
                            .font(.subheadline)
                            .bold()

                        Text(qualityExample(for: hoveredQuality))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.windowBackgroundColor))
                            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                    )
                    .frame(maxWidth: 340, alignment: .leading)
                    .offset(y: -4)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Advanced: extra ffmpeg flags", isOn: $advancedFFmpegOptions)
                    .help("Enable power-user overrides to append additional ffmpeg arguments.")
                    .onChange(of: advancedFFmpegOptions) { newValue in
                        if newValue && extraFFmpegArgsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            extraFFmpegArgsText = placeholderText
                        }
                    }

                if advancedFFmpegOptions {
                    Text("Extra ffmpeg flags")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enter raw ffmpeg args exactly as you would in Terminal. Example: -b:v 4M -maxrate 6M -bufsize 12M")
                        Text("Do NOT include -i, -vf/-filter_complex, -map, or output filename; the app manages those.")
                        Text("Leave blank to do nothing.")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.windowBackgroundColor))
                            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                    )

                    TextEditor(text: $extraFFmpegArgsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .help("Appended to ffmpeg command")

                    Text("Appended to ffmpeg command")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Text("Will apply: \(sanitizedExtraArgsPreview())")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)


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
                .disabled(outputMode == .audioOnly)
                .onChange(of: burnMode) { newMode in
                    if newMode == .subtitleTrack {
                        if subtitleMode == nil { subtitleMode = .perClip }
                        if format != .mkv { format = .mkv }
                    } else {
                        subtitleMode = nil
                    }
                }

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
            .disabled(outputMode == .audioOnly)
            .opacity(outputMode == .audioOnly ? 0.5 : 1.0)

                // Controls: run controls on the right
                HStack(alignment: .top) {
                    Spacer()

                    // Right: Stop / Start, then choose output folder button under them
                    VStack(alignment: .trailing, spacing: 4) {

                        HStack(spacing: 8) {
                            let coneOrange = Color(red: 1.0, green: 0.4, blue: 0.0)

                            // START button — cone orange
                            Button(action: {
                                if isProcessing {
                                    let idValue = runID.isEmpty ? "unknown" : runID
                                    appendToLog("[RUN] duplicate launch ignored id=\(idValue)")
                                    return
                                }
                                runID = UUID().uuidString
                                isProcessing = true
                                runBurn()
                            }) {
                                Text(isRunning ? "Running…" : "Start Burn/Encode")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.black)
                                    .frame(width: 150, height: 22)   // FIXED HEIGHT
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill((isRunning || !hasInputPath || shouldBlockStart)
                                                  ? coneOrange.opacity(0.45)
                                                  : coneOrange)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(isRunning || !hasInputPath || shouldBlockStart)

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

                        if let reason = startBlockReason {
                            Text(reason)
                                .font(.footnote)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
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
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .onAppear(perform: loadAvailableFonts)
    }

    private var folderQueueView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Queued folders")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                if folderQueue.isEmpty {
                    Text(isFolderDropTarget
                         ? "Release to add folders to the queue"
                         : "Drop folders here or click “Add Folders…”")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    List {
                        ForEach(folderQueue) { entry in
                            queueRow(for: entry)
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 260)
                    .listStyle(.inset)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isFolderDropTarget ? Color.accentColor : Color.gray.opacity(0.3),
                        lineWidth: isFolderDropTarget ? 2 : 1
                    )
            )
            .onDrop(of: [UTType.folder, .fileURL], isTargeted: $isFolderDropTarget) { providers in
                handleQueueDrop(providers)
            }
        }
    }

    private func queueRow(for entry: QueueEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(.headline)
                Text("Output base: \(entry.outputBaseName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(entry.settingsSnapshot.queueSummaryDescription)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(entry.settingsSnapshot.summaryDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(spacing: 6) {
                Button {
                    moveEntry(entry, offset: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("Move folder earlier in the queue.")
                .disabled(folderQueue.first?.id == entry.id)

                Button {
                    moveEntry(entry, offset: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .help("Move folder later in the queue.")
                .disabled(folderQueue.last?.id == entry.id)

                Button {
                    removeEntry(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove this folder from the queue.")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: { withAnimation { isLogExpanded.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: isLogExpanded ? "chevron.left" : "chevron.right")
                        Text("Log")
                            .font(.subheadline)
                            .bold()
                            .opacity(isLogExpanded ? 1.0 : 0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if isLogExpanded {
                VStack(alignment: .leading, spacing: 8) {
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

                    Toggle("Enhanced debug logging", isOn: $debugMode)
                        .help("Include extra script settings and debug details at the top of the log.")

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
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(minWidth: isLogExpanded ? 280 : 52, maxWidth: isLogExpanded ? 320 : 60)
        .padding(8)
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
        let defaultBase = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("DVMeta")
        let base: URL
        if let lastWorkspaceURL {
            base = fm.fileExists(atPath: lastWorkspaceURL.path)
                ? lastWorkspaceURL : lastWorkspaceURL.deletingLastPathComponent()
        } else {
            base = defaultBase
        }

        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }

        NSWorkspace.shared.open(base)
    }

    private func captureSettingsSnapshot(for mode: InputMode? = nil) -> BurnSettingsSnapshot {
        let (extraArgsForRun, extraWarnings, rawExtraArgs) = resolveExtraFFmpegArgs()
        let trimmedScratch = scratchDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDeinterlace: DeinterlaceMode = (format == .mov) ? .off : deinterlaceMode

        return BurnSettingsSnapshot(
            inputMode: mode ?? inputMode,
            burnMode: burnMode,
            missingMetaMode: missingMetaMode,
            subtitleMode: subtitleMode,
            layout: layout,
            format: format,
            quality: quality,
            deinterlace: resolvedDeinterlace,
            outputMode: outputMode,
            stitchBatch: stitchBatch,
            destinationOverride: sanitizedDestinationOverride(),
            scratchDirectory: trimmedScratch.isEmpty ? nil : trimmedScratch,
            debugMode: debugMode,
            resolvedFontPath: resolvedFontPath(),
            resolvedFontName: resolvedFontName(),
            outputToLocationFolder: outputToLocationFolder,
            advancedFFmpegOptions: advancedFFmpegOptions,
            extraFFmpegArgsText: extraFFmpegArgsText,
            sanitizedExtraArgs: extraArgsForRun,
            extraArgWarnings: extraWarnings,
            rawExtraArgs: rawExtraArgs
        )
    }

    private func appendQueueEntries(from urls: [URL]) {
        let snapshot = captureSettingsSnapshot(for: .folderQueue)
        let existing = Set(folderQueue.map { $0.path })
        var localSeen = Set<String>()
        var additions: [QueueEntry] = []

        for url in urls where url.hasDirectoryPath {
            let path = url.path
            guard !existing.contains(path), !localSeen.contains(path) else { continue }
            localSeen.insert(path)
            additions.append(QueueEntry(path: path, settingsSnapshot: snapshot))
        }

        guard !additions.isEmpty else { return }

        folderQueue.append(contentsOf: additions)
        inputMode = .folderQueue

        if inputPath.isEmpty {
            inputPath = additions.first?.path ?? inputPath
        }
    }

    private func removeEntry(_ entry: QueueEntry) {
        folderQueue.removeAll { $0.id == entry.id }
    }

    private func moveEntry(_ entry: QueueEntry, offset: Int) {
        guard let currentIndex = folderQueue.firstIndex(of: entry) else { return }
        let newIndex = currentIndex + offset
        guard folderQueue.indices.contains(newIndex) else { return }

        var updated = folderQueue
        let item = updated.remove(at: currentIndex)
        updated.insert(item, at: newIndex)
        folderQueue = updated
    }

    private func handleQueueDrop(_ providers: [NSItemProvider]) -> Bool {
        let identifiers = [UTType.folder.identifier, UTType.fileURL.identifier]
        let dispatchGroup = DispatchGroup()
        var urls: [URL] = []
        var accepted = false

        for provider in providers {
            guard identifiers.contains(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
            accepted = true
            for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
                dispatchGroup.enter()
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    defer { dispatchGroup.leave() }

                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true),
                       url.hasDirectoryPath {
                        urls.append(url)
                    } else if let url = item as? URL, url.hasDirectoryPath {
                        urls.append(url)
                    }
                }
            }
        }

        dispatchGroup.notify(queue: .main) {
            inputMode = .folderQueue
            appendQueueEntries(from: urls)
        }

        return accepted
    }

    // MARK: - File / folder picker

    private func chooseInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            let urls = panel.urls
            let folders = urls.filter { $0.hasDirectoryPath }
            let files = urls.filter { !$0.hasDirectoryPath }

            if !folders.isEmpty {
                appendQueueEntries(from: folders)
                inputMode = .folderQueue
            }

            if folders.isEmpty, let file = files.first {
                inputPath = file.path
                inputMode = .singleFile
            } else if folders.count == 1 && files.isEmpty {
                inputPath = folders.first?.path ?? inputPath
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
            if let inputURL = resolvedInputURL {
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

        if let existingInput = resolvedInputURL,
           fm.fileExists(atPath: existingInput.path),
           !existingInput.hasDirectoryPath {
            debugURL = existingInput
        }

        if debugURL == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false

            if panel.runModal() == .OK, let url = panel.url {
                debugURL = url
                inputPath = url.path
                inputMode = .singleFile
            }
        }

        guard let url = debugURL else { return }

        logText = ""
        fullLogText = ""
        cancellationRequested = false
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
        if let proc = currentProcess, proc.isRunning {
            cancellationRequested = true
            proc.terminate()
            appendToLog("\n[stop requested; waiting for processing and cleanup]\n")
        }
    }

    // MARK: - Run script

    private func runBurn() {
        if inputMode == .folderQueue {
            startFolderQueueRun()
            return
        }

        let snapshot = captureSettingsSnapshot()
        let selectedInput = activeInputPath.trimmingCharacters(in: .whitespacesAndNewlines)

        launchRun(using: snapshot, inputPath: selectedInput, outputBaseName: nil)
    }

    private func startFolderQueueRun() {
        guard !folderQueue.isEmpty else {
            logText = "Queue is empty."
            isProcessing = false
            return
        }

        guard !isRunning else { return }

        guard let entry = folderQueue.first else { return }
        let trimmedPath = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)

        launchRun(using: entry.settingsSnapshot, inputPath: trimmedPath, outputBaseName: entry.outputBaseName) {
            folderQueue.removeAll { $0.id == entry.id }
            if !folderQueue.isEmpty {
                startFolderQueueRun()
            }
        }
    }

    private func launchRun(
        using snapshot: BurnSettingsSnapshot,
        inputPath: String,
        outputBaseName: String?,
        completion: (() -> Void)? = nil
    ) {
        let selectedInput = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !selectedInput.isEmpty else {
            logText = "Please choose an input file or folder first."
            isProcessing = false
            return
        }

        if let reason = startBlockReason(for: snapshot) {
            logText = reason
            isProcessing = false
            return
        }

        logText = ""
        fullLogText = ""
        cancellationRequested = false
        isRunning = true

        if !snapshot.extraArgWarnings.isEmpty {
            appendToLog(snapshot.extraArgWarnings.joined(separator: "\n") + "\n", capped: false)
        }

        if snapshot.debugMode {
            appendToLog(debugSnapshot(for: selectedInput, snapshot: snapshot), capped: false)
        }

        let resolvedDestination = resolvedDestinationPath(
            for: selectedInput,
            destinationOverride: snapshot.destinationOverride
        ) ?? "unknown"
        print("[RUN] id=\(runID) mode=\(snapshot.inputMode) stitch=\(snapshot.stitchBatch) output=\(resolvedDestination)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (process, pipe, argv, workspace) = try self.makeProcess(
                    inputPath: selectedInput,
                    inputFolderPath: snapshot.isBatchMode ? selectedInput : nil,
                    rawExtraArgs: snapshot.rawExtraArgs,
                    snapshot: snapshot,
                    outputBaseName: outputBaseName
                )

                var didLaunch = false
                defer {
                    if didLaunch { workspace.removeLaunchFiles() }
                    else { workspace.discardBeforeLaunch() }
                }

                let wantsStitch = snapshot.isBatchMode && snapshot.stitchBatch
                let launchLine =
                    "[launch] wantsStitch=\(wantsStitch) " +
                    "burnMode=\(snapshot.burnMode.rawValue) " +
                    "mode=\(snapshot.inputMode.scriptValue) " +
                    "argv=\(argv)"

                DispatchQueue.main.async {
                    self.appendToLog(launchLine, capped: false)
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

                try DispatchQueue.main.sync {
                    try process.run()
                    self.currentProcess = process
                    self.lastWorkspaceURL = workspace.url
                }
                didLaunch = true
                process.waitUntilExit()
                let status = process.terminationStatus

                let remainder = self.drainPipeRemainder(handle)
                if !remainder.isEmpty {
                    DispatchQueue.main.async {
                        self.appendToLog(remainder)
                    }
                }

                DispatchQueue.main.async {
                    self.isRunning = false
                    self.isProcessing = false
                    self.appendToLog("\n\n[process exit status: \(status)]")
                    handle.readabilityHandler = nil
                    self.currentProcess = nil
                    if !self.cancellationRequested { completion?() }
                }

            } catch {
                DispatchQueue.main.async {
                    self.logText = "Error: \(error.localizedDescription)"
                    self.isRunning = false
                    self.isProcessing = false
                    self.currentProcess = nil
                }
            }
        }
    }
    private func drainPipeRemainder(_ handle: FileHandle) -> String {
        handle.readabilityHandler = nil
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.isEmpty else {
            return ""
        }
        return s
    }
    // MARK: - Process builder

    private func makeProcess(
        inputPath: String,
        inputFolderPath: String?,
        rawExtraArgs: String?,
        snapshot: BurnSettingsSnapshot,
        outputBaseName: String?
    ) throws -> (Process, Pipe, [String], RunWorkspace) {
        let bundleRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let fm = FileManager.default

        func findScriptURL() -> URL? {
            if let u = findBundledResource(named: "dvmetaburn.zsh") {
                return u
            }
            if let u = findBundledResource(named: "dvmetaburn") {
                return u
            }
            return nil
        }

        guard let bundledScriptURL = findScriptURL() else {
            throw NSError(domain: "DVMeta", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "ERROR: Could not find dvmetaburn(.zsh) in app bundle (root: \(bundleRoot.path))."])
        }

        guard let ffmpegURL = findBundledResource(named: "ffmpeg") else {
            throw NSError(domain: "DVMeta", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "ERROR: Could not find ffmpeg in app bundle."])
        }

        guard let dvrescueURL = findBundledResource(named: "dvrescue") else {
            throw NSError(domain: "DVMeta", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "ERROR: Could not find dvrescue in app bundle."])
        }

        guard let fontURL = findBundledResource(named: "UAV-OSD-Mono.ttf") else {
            throw NSError(domain: "DVMeta", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "ERROR: Could not find UAV-OSD-Mono.ttf in app bundle."])
        }
        _ = fontURL

        let workspace = try RunWorkspace.create(scratchDirectory: snapshot.scratchDirectory)
        var prepared = false
        defer { if !prepared { workspace.discardBeforeLaunch() } }
        let tempDir = workspace.url
        let tempScriptURL = tempDir.appendingPathComponent("dvmetaburn_run.zsh")
        let tempLibDirURL = tempDir.appendingPathComponent("lib", isDirectory: true)
        try fm.copyItem(at: bundledScriptURL, to: tempScriptURL)
        let bundledLibDirURL = bundledScriptURL.deletingLastPathComponent().appendingPathComponent("lib", isDirectory: true)
        let fallbackLibDirURL = bundleRoot.appendingPathComponent("scripts/lib", isDirectory: true)
        let libSourceURL: URL?
        if fm.fileExists(atPath: bundledLibDirURL.path) {
            libSourceURL = bundledLibDirURL
        } else if fm.fileExists(atPath: fallbackLibDirURL.path) {
            libSourceURL = fallbackLibDirURL
        } else {
            libSourceURL = nil
        }

        guard let resolvedLibSourceURL = libSourceURL else {
            throw NSError(domain: "DVMeta", code: 7,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "ERROR: Could not find scripts/lib in app bundle (root: \(bundleRoot.path))."])
        }

        try fm.copyItem(at: resolvedLibSourceURL, to: tempLibDirURL)

        let attrs: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o755))
        ]
        try fm.setAttributes(attrs, ofItemAtPath: tempScriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        let args = buildScriptArgs(
            scriptURL: tempScriptURL,
            ffmpegURL: ffmpegURL,
            dvrescueURL: dvrescueURL,
            inputPath: inputPath,
            rawExtraArgs: rawExtraArgs,
            snapshot: snapshot
        )

        process.arguments = args

        // Pass ownership to the CLI; every subprocess shares this run workspace.
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = tempDir.path
        env["DVMETA_WORKSPACE"] = workspace.url.path
        env["DVMETA_WORKSPACE_TOKEN"] = workspace.token
        if let inputFolderPath {
            env["DVMETA_INPUT_FOLDER"] = inputFolderPath
        }
        if let outputBaseName {
            env["DVMETA_OUTPUT_BASENAME"] = outputBaseName
        }
        env["DVMETA_RUN_ID"] = runID
        process.environment = env
        process.currentDirectoryURL = tempDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let argv = [process.executableURL?.path ?? ""] + args

        prepared = true
        return (process, pipe, argv, workspace)
    }

    private func buildScriptArgs(
        scriptURL: URL,
        ffmpegURL: URL,
        dvrescueURL: URL,
        inputPath: String,
        rawExtraArgs: String?,
        snapshot: BurnSettingsSnapshot
    ) -> [String] {
        let missingMetaArg: String
        switch snapshot.missingMetaMode {
        case .error:
            missingMetaArg = "error"

        case .skipBurninConvert:
            // subtitleTrack has no burn-in stage; treat as skip_file
            missingMetaArg = (snapshot.burnMode == .subtitleTrack)
                ? "skip_file"
                : "skip_burnin_convert"

        case .skipFile:
            missingMetaArg = "skip_file"
        }

        var args: [String] = [
            scriptURL.path,
            "--mode=\(snapshot.inputMode.scriptValue)",
            "--layout=\(snapshot.layout)",
            "--format=\(snapshot.format.rawValue)",
            "--deinterlace=\(snapshot.deinterlace.rawValue)",
            "--output-mode=\(snapshot.outputMode.rawValue)",
            "--missing-meta=\(missingMetaArg)",
            "--fontfile=\(snapshot.resolvedFontPath)",
            "--fontname=\(snapshot.resolvedFontName)",
            "--ffmpeg=\(ffmpegURL.path)",
            "--dvrescue=\(dvrescueURL.path)"
        ]

        if snapshot.burnMode != .subtitleTrack, (snapshot.format == .mp4 || snapshot.format == .mkv) {
            args.append("--quality=\(snapshot.quality.rawValue)")
        }
        switch snapshot.burnMode {
        case .burnin:
            args.append("--burn-mode=\(BurnMode.burnin.rawValue)")
        case .off:
            args.append("--burn-mode=\(BurnMode.off.rawValue)")
        case .subtitleTrack:
            args.append("--burn-mode=\(BurnMode.subtitleTrack.rawValue)")
            if let subtitleMode = snapshot.subtitleMode {
                args.append("--subtitle-mode=\(subtitleMode.rawValue)")
            }
        }

        if snapshot.debugMode {
            args.append("--debug")
        }

        let wantsStitch = snapshot.isBatchMode && snapshot.stitchBatch
        if wantsStitch {
            args.append("--stitch-batch")
        }

        if let destination = snapshot.destinationOverride {
            args.append("--dest-dir=\(destination)")
        }

        if let trimmedScratch = snapshot.scratchDirectory, !trimmedScratch.isEmpty {
            args.append("--scratch-dir=\(trimmedScratch)")
        }

        if let rawExtraArgs, !rawExtraArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append("--extra-ffmpeg-flags=\(rawExtraArgs)")
        }

        args.append(contentsOf: ["--", inputPath])

        return args
    }

    private func findBundledResource(named name: String) -> URL? {
        let fm = FileManager.default
        let bundleRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL

        guard let enumerator = fm.enumerator(at: bundleRoot, includingPropertiesForKeys: nil) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    private func resolveExtraFFmpegArgs() -> ([String], [String], String?) {
        guard advancedFFmpegOptions else { return ([], [], nil) }

        let raw = extraFFmpegArgsText

        guard !shouldIgnoreExtraArgs(raw) else { return ([], [], nil) }

        let parsed = parseExtraFFmpegArgs(from: raw)
        var (sanitized, warnings) = sanitizeExtraFFmpegArgs(parsed)

        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRaw.isEmpty {
            warnings.insert("[extra-args] Raw extra flags: \(trimmedRaw)", at: 0)
        }

        return (sanitized, warnings, trimmedRaw.isEmpty ? nil : raw)
    }

    private func sanitizedExtraArgsPreview() -> String {
        guard advancedFFmpegOptions else { return "(none)" }
        guard !shouldIgnoreExtraArgs(extraFFmpegArgsText) else { return "(none)" }

        let parsed = parseExtraFFmpegArgs(from: extraFFmpegArgsText)
        let (sanitized, _) = sanitizeExtraFFmpegArgs(parsed)

        return sanitized.isEmpty ? "(none)" : sanitized.joined(separator: " ")
    }

    private func parseExtraFFmpegArgs(from text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        var args: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false

        func flush() {
            if !current.isEmpty {
                args.append(current)
                current = ""
            }
        }

        for char in normalized {
            if char == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }

            if char == "'" && !inDouble {
                inSingle.toggle()
                continue
            }

            if char.isWhitespace && !inSingle && !inDouble {
                flush()
            } else {
                current.append(char)
            }
        }

        flush()
        return args
    }

    private func sanitizeExtraFFmpegArgs(_ args: [String]) -> ([String], [String]) {
        var sanitized: [String] = []
        var warnings: [String] = []
        var skipNextInput = false
        var skippedOption: String?
        let blockedExtensions: Set<String> = [
            "mov", "mp4", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "m4v", "ts", "webm", "mxf", "mp3", "wav"
        ]
        let blockedOptionsWithValue: Set<String> = ["-i", "-filter_complex", "-vf", "-af", "-map"]
        let blockedStandalone: Set<String> = ["-y", "-n"]

        for token in args {
            if skipNextInput {
                warnings.append("[extra-args] Dropping value following \(skippedOption ?? "managed option"): \(token)")
                skipNextInput = false
                skippedOption = nil
                continue
            }

            let lowerToken = token.lowercased()

            if blockedOptionsWithValue.contains(lowerToken) {
                warnings.append("[extra-args] Ignoring '\(token)' to protect managed inputs.")
                skipNextInput = true
                skippedOption = token
                continue
            }

            if blockedStandalone.contains(lowerToken) {
                warnings.append("[extra-args] Ignoring '\(token)' to protect managed outputs.")
                continue
            }

            let extensionMatch = URL(fileURLWithPath: lowerToken).pathExtension
            if !extensionMatch.isEmpty, blockedExtensions.contains(extensionMatch) {
                warnings.append("[extra-args] Ignoring possible output override '\(token)'.")
                continue
            }

            sanitized.append(token)
        }

        if !sanitized.isEmpty {
            warnings.append("[extra-args] Sanitized args: \(sanitized.joined(separator: " "))")
        }

        return (sanitized, warnings)
    }

    private func shouldIgnoreExtraArgs(_ text: String) -> Bool {
        if text == placeholderText {
            return true
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }

        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("#") }
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
        let familyName: String?
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
                            fontName: postScriptName,
                            familyName: descriptor.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
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
                            fontName: postScriptName,
                            familyName: descriptor.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
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
        if let selectedFontPath {
            registerFontIfNeeded(at: selectedFontPath)
        }
    }

    private func resolvedFontPath() -> String {
        let fm = FileManager.default
        if let selected = selectedFontPath, fm.fileExists(atPath: selected) {
            return selected
        }
        if let u = findBundledResource(named: "UAV-OSD-Mono.ttf") {
            return u.path
        }
        return "/Library/Fonts/UAV-OSD-Mono.ttf" // last-ditch; or just return ""
    }

    private func resolvedFontName() -> String {
        if let match = displayedFonts.first(where: { $0.path == selectedFontPath }) {
            return match.familyName ?? match.displayName
        }
        return "UAV OSD Mono"
    }

    private func currentFontSelectionName() -> String {
        if let match = displayedFonts.first(where: { $0.path == selectedFontPath }) {
            return match.displayName
        }

        if let bundledDefault = camcorderFonts.first(where: { $0.path.localizedCaseInsensitiveContains("vt323-regular") }) {
            return bundledDefault.displayName
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

        if let defaultFont = camcorderFonts.first(where: { $0.path.localizedCaseInsensitiveContains("vt323-regular") }) {
            selectedFontPath = defaultFont.path
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

    private func debugSnapshot(for inputPath: String, snapshot: BurnSettingsSnapshot) -> String {
        var lines: [String] = []
        let fm = FileManager.default
        let inputExists = fm.fileExists(atPath: inputPath) ? "yes" : "no"
        let debugFlag = snapshot.debugMode ? "on" : "off"
        let resolvedQuality = resolveQuality(snapshot.quality, format: snapshot.format, outputMode: snapshot.outputMode)
        let qscaleDisplay = resolvedQuality.qscale.map { String($0) } ?? "passthrough"
        let subtitleModeValue = snapshot.subtitleMode?.rawValue ?? "(none selected)"

        lines.append("[DEBUG] Input path: \(inputPath)")
        lines.append("[DEBUG] Input exists: \(inputExists)")
        lines.append("[DEBUG] Mode: \(snapshot.inputMode.rawValue) | Layout: \(snapshot.layout) | Format: \(snapshot.format) | Output: \(snapshot.outputMode.rawValue)")
        lines.append("[DEBUG] Quality: \(snapshot.quality.rawValue) | qscale=\(qscaleDisplay)")
        lines.append("[DEBUG] Burn mode: \(snapshot.burnMode.rawValue) | Missing metadata handling: \(snapshot.missingMetaMode.rawValue)")
        lines.append("[DEBUG] Subtitle timing mode: \(subtitleModeValue)")
        lines.append("[DEBUG] Font path: \(snapshot.resolvedFontPath) | Font name: \(snapshot.resolvedFontName)")
        let requestedDestination = snapshot.destinationOverride ?? "(default: input folder)"
        let resolvedDestination = resolvedDestinationPath(for: inputPath, destinationOverride: snapshot.destinationOverride) ?? "(unresolved)"
        lines.append("[DEBUG] Requested destination: \(requestedDestination)")
        lines.append("[DEBUG] Resolved destination: \(resolvedDestination)")
        let scratchDisplay = snapshot.scratchDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append("[DEBUG] Scratch directory override: \(scratchDisplay.isEmpty ? "(default)" : scratchDisplay)")
        lines.append("[DEBUG] Debug flag passed to script: \(debugFlag)")
        return lines.joined(separator: "\n") + "\n\n"
    }
}
