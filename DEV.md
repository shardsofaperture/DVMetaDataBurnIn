# Development

This is a native macOS SwiftUI application. Keep `DVMetaDataBurnIn.xcodeproj` and its shared `DVMetaDataBurnIn` scheme as the build system. VS Code edits the same sources and uses the same Git repository; opening this folder there does not require a new repository or a Swift package.

## VS Code

Open the repository folder, then use **Terminal → Run Task**:

- **DVMeta: check development tools** reports Git, the selected developer directory, and bundled tool versions.
- **DVMeta: run automated tests** runs the Zsh smoke checks and synthetic regression tests.
- **DVMeta: build macOS app** invokes the existing Xcode scheme. It is the default build task (`⇧⌘B`).
- **DVMeta: open project in Xcode** opens the native project for running, debugging, signing, and archiving.

No editor extension is required to execute these tasks. `.gitignore` excludes generated build products and local validation evidence. Existing tracked Xcode settings are retained.

## Build

Full Xcode is required; Command Line Tools alone cannot execute `xcodebuild`. The project targets macOS 12.0 and uses Swift language version 5. The bundled FFmpeg and DVRescue binaries in this checkout are x86_64; native Apple Silicon compatibility is not established by these tests.

```sh
zsh Resources/scripts/dev/xcodebuild.zsh -project DVMetaDataBurnIn.xcodeproj \
  -scheme DVMetaDataBurnIn -configuration Debug \
  -derivedDataPath .build/Xcode15DerivedData CODE_SIGNING_ALLOWED=NO build
```

The build wrapper honors an explicit `DEVELOPER_DIR`, otherwise uses the system-selected full Xcode. On this Mac, when only Command Line Tools is selected, it falls back to `/Volumes/1 TB Storage/xcode-15.4/Xcode.app/Contents/Developer` (Xcode 15.4, build 15F31d). This selects Xcode for that command without changing the system selection. The external volume must be mounted. The Open Xcode task points at that same application; adjust its path if Xcode moves. To select a different installation, prefix the build with `DEVELOPER_DIR="/actual/path/Xcode.app/Contents/Developer"`.

Open the project in Xcode to run the app or create a signed archive. The native maintenance build passed before updating `MARKETING_VERSION` to 1.0.7; the 1.0.7 Debug and Release builds also passed. The unsigned development build does not establish distribution signing or GUI acceptance. See [the maintenance report](docs/MAINTENANCE_1.0.7.md) for results and remaining manual checks.

## Active architecture

1. `DVMetaDataBurnInApp.swift` launches the splash and `ContentView`.
2. `ContentView.makeProcess()` finds bundled scripts, fonts, FFmpeg, and DVRescue. `RunWorkspace` in `DVProcessor.swift` allocates an exclusive directory and copies the entrypoint and `lib` directory there. It passes paths as process arguments and an ownership token through the environment.
3. `Resources/scripts/dvmetaburn.zsh` loads `lib/env.zsh` first, validates and sources the remaining libraries, parses CLI options, and routes single/batch jobs. Libraries other than `env.zsh` define functions without executing processing work when sourced.
4. `lib/pipeline.zsh` coordinates validation, metadata capture, normalization, timeline generation, encoding/muxing, and manifests. FFmpeg and DVRescue remain bundled runtime dependencies; Python and ffprobe are developer-test tools only.
5. `lib/dvrescue.zsh` reads numbered recording date/time rows and recovers exact NTSC rates from FFmpeg's rounded banner. `lib/timeline.zsh` generates rolling drawtext commands or ASS events. Recording dates come from metadata; midnight and recording interruptions are not synthesized from elapsed time.
6. The CLI owns batch concatenation. Swift does not scan previous runs or perform a second concat. Ordered stitch parts belong to the current workspace. `--stitch-inputs` remains a text file with one source path per line.

ASS uses centiseconds: interior event boundaries round down together, while the final end rounds up to cover the source's last frame. For constant-rate DV, the probed media duration is aligned to the nearest source frame. If duration is unavailable, the last numbered DVRescue frame is used, including a frame without date/time metadata. A one-frame final tail is the last fallback. Neither date/time appearance nor encoding presets are changed. Per-clip and continuous flags retain their existing routing; both were tested for ordered batch subtitle boundaries, not for new semantics.

## Run workspaces and cleanup

Default workspaces are `~/Library/Logs/DVMeta/run.XXXXXXXX/`. With `--scratch-dir` or `DVMETA_SCRATCH_DIR`, they are `<scratch>/DVMetaDataBurnIn/run.XXXXXXXX/`. Each is created exclusively and contains:

- `.dvmeta-owner`: the token shared by Swift and Zsh.
- `dvmetaburn_run.zsh` and `lib/`: the GUI's private launch copies; Swift removes these after exit.
- `tmp/`: subprocess temporary files; removed on handled exit after the tracked child stops.
- `artifacts/`: separate per-clip directories, logs, timeline, ASS, versions, manifests, and stitch intermediates.

`TMPDIR` and `TMPPREFIX` point inside the run. Output filenames and user-selected output locations are retained. A batch cleans its workspace once, after every clip and final concat, rather than at the end of each clip. The GUI's **Open temp folder** button opens its latest workspace; if that workspace was explicitly cleaned, it opens the existing parent folder.

CLI cleanup controls retain their meanings:

| Setting | Result |
| --- | --- |
| `--scratch-cleanup=never` (default) | Retain diagnostic artifacts on success or failure. |
| `--scratch-cleanup=success` | Remove the owned workspace after a successful job. Retain failed jobs. |
| `--scratch-cleanup=failure` | Remove it after a failed/cancelled job. Retain successful jobs. |
| `--keep-on-failure` | Retain a failed/cancelled workspace even with the failure cleanup policy. |

Environment equivalents are `DVMETA_SCRATCH_CLEANUP` and `DVMETA_KEEP_ON_FAILURE`. Enhanced debug logging changes logging only. Cleanup validates the canonical root, its original ownership marker, and protected input/destination paths. It refuses to delete a replaced/symlinked root or a workspace containing the input or chosen destination. Internal `DVMETA_WORKSPACE` and `DVMETA_WORKSPACE_TOKEN` coordinate the GUI and CLI; they are not user-selected cleanup roots.

Stop sends termination to the shell; the shell stops and reaps its tracked encoder or DVRescue child before cleanup. The GUI waits for exit, and a cancelled folder queue does not automatically start its next entry. Abrupt process death (for example SIGKILL or power loss) cannot execute cleanup traps; retained directories are intentionally not swept by future runs. Existing older artifacts are left alone.

## Validation

```sh
zsh Resources/scripts/dev/check_environment.zsh
zsh Resources/scripts/dev/test_all.zsh
zsh Resources/scripts/dvmetaburn.zsh \
  --ffmpeg="$PWD/Resources/bin/ffmpeg" \
  --dvrescue="$PWD/Resources/bin/dvrescue" --selftest
```

The legacy `--selftest` now reaches all four processing checks; it keeps its generated fixtures/outputs under the run's artifacts for inspection. [Developer tests](docs/DEV_TESTS.md) describe dependencies, automated coverage, and the remaining manual checks. No system packages are installed by these commands.

The Swift workspace contract also has six executable checks. With full Xcode selected for these commands:

```sh
export DEVELOPER_DIR="/Volumes/1 TB Storage/xcode-15.4/Xcode.app/Contents/Developer"
xcrun swiftc -module-cache-path .build/Xcode15DerivedData/ModuleCache.noindex \
  DVProcessor.swift Resources/scripts/dev/tests/RunWorkspaceChecks.swift \
  -o .build/workspace-checks
.build/workspace-checks
```

Use the actual Xcode path on another Mac. These checks exercise Swift allocation, ownership markers, launch-file removal, diagnostic preservation, and scratch-parent symlinks; they do not launch the GUI.
