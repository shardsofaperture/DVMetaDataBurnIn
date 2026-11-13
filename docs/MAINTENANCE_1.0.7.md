# DVMetaDataBurnIn 1.0.7 maintenance status

November 12, 2026. Implementation, synthetic regression checks, and the native Xcode build are complete. The maintenance changes first passed the native build at 1.0.6; the application was then updated to **1.0.7** and its Debug and Release builds passed. Distribution is the `v1.0.7-maintenance.1` prerelease from `maintenance/1.0.7`. Additional bug fixes, GUI checks and real-footage acceptance remain pending before merging the maintenance work into `main`. See [release notes](releases/1.0.7-maintenance.1.md).

## Repository and baseline

The folder was already a Git repository before VS Code setup. It had a clean working tree on `codex-refactor`, tracking `origin/codex-refactor`, with remote `https://github.com/shardsofaperture/DVMetaDataBurnIn/`. Baseline HEAD was `cfa50d5` (1.0.6B release push). Created `maintenance/1.0.7` from that exact revision. The owner subsequently authorized committing and pushing this maintenance branch to GitHub. This report accompanies that maintenance commit. Application changes remain on the maintenance branch. The owner later authorized the maintenance prerelease, a draft pull request, a documentation-only status notice on `main`, and a supporting handoff ZIP in Nextcloud. Build products and local diagnostic evidence remain ignored by Git.

The README, development notes, developer scenarios, changelog, actual Swift launch code, active libraries, and entrypoint were inspected before editing. Baseline checks:

| Check | Baseline result |
| --- | --- |
| `smoke_zsh_parse.zsh` | Passed. |
| `smoke_sanitize_sendcmd.zsh` | Failed: missing logging setup, CR-only records joined together, unexpected row count. |
| `smoke_sendcmd_format.zsh` | Failed: uninitialized font/debug globals and an invalid newline test. |
| Native `xcodebuild` | Blocked before compilation: selected `/Library/Developer/CommandLineTools` is not full Xcode. |
| Bundled tool execution | FFmpeg 8.0.1-tessus and DVRescue 24.07 ran on this Intel macOS 14.7.1 host. |

Initial discovery found no full Xcode installation in Applications or Spotlight. The owner then identified `/Volumes/1 TB Storage/xcode-15.4/Xcode.app`; Xcode 15.4 (15F31d) there successfully compiled the native project. The project build wrapper selects it per command when the system selection is Command Line Tools, while honoring an explicit `DEVELOPER_DIR`. No tools, packages, extensions, or system configuration were installed or changed. `xcode-select -p` still reports `/Library/Developer/CommandLineTools`.

## Actual issues and implemented fixes

1. **Premature final ASS event:** the active generator ended its last event one frame after the last metadata change, which can precede the end of the clip. It now uses frame-aligned media duration; a last numbered DVRescue row is the fallback. Media duration is read through bundled FFmpeg, avoiding a new ffprobe runtime requirement. Fractional NTSC rates are restored before frame arithmetic. Interior ASS boundaries share the same centisecond conversion, final ends round up, and invalid/backwards/duplicate source rows cannot create overlapping or empty events. Date/time text and styles are retained. The sendcmd overlay already persists until changed; its unused end-time arithmetic was removed.
2. **Shared GUI temporary paths:** the GUI previously removed/replaced a common `dvmetaburn_run.zsh` and `lib` directory. Swift now creates a private directory with `mkdtemp`, writes an ownership marker, and passes that same workspace to Zsh. CLI-only runs allocate equivalent exclusive directories. Per-clip artifact directories are also exclusive. Deinterlacing work files now live inside their clip's artifact directory, including runs without a custom scratch folder.
3. **Premature/unsafe cleanup:** per-clip `finish_run` could remove the shared batch scratch root while later clips or concatenation still needed it. Cleanup now runs once at job exit. It validates canonical ownership and protects inputs, explicit stitch-list sources, and output destinations. Tracked subprocesses are stopped/reaped on handled cancellation before temporary files are removed. Retention policies remain available; old workspaces are never swept automatically.
4. **Duplicate/cross-run GUI stitching:** Swift performed another concat after the CLI had already stitched, using scans of recent scratch/log/output folders. Removed this second path and its private scanning/FFmpeg helpers. The active CLI alone resolves ordered current-run parts. Stop waits for processing exit and prevents automatic advancement to the next queued folder.
5. **Masked failures:** several `if ! command; then status=$?` branches captured the status of negation (zero). They now retain actual failure statuses, honor missing-metadata policies in subtitle mode, and report failed batch items. Failed concat fallback cannot publish a merely existing partial file as success. Batch destinations are created before moving the final output.
6. **Rolling time and unusual paths:** smoke-check repair exposed insufficient sendcmd escaping for the time's colons. Literal escaping now survives both parser layers. FFmpeg option/filtergraph path escaping covers punctuation, quotes, and backslashes. Zsh's special `path` variable is no longer used as a local file-path variable. Diagnostic manifests escape path strings into valid JSON.
7. **Verified legacy cleanup:** both `DVMETA_FUNCTIONS` heredocs were arguments to the no-op `:` command and entirely inactive. They were removed. Duplicate active helpers were consolidated into their libraries. Where old library definitions differed, the previously active entrypoint implementations were moved intact so actual encoding defaults remain unchanged. The unused `DVProcessor` observable object was replaced by the workspace helper in the same already-compiled source file. The explicit stitch-list reader now uses Zsh instead of Bash-only `mapfile`, and the undefined intermediate extension was replaced with an internal MOV source container for DV stream copying.
8. **Development setup:** added VS Code tasks, generated-file ignores, tool checks, a project-local Xcode selector, a test runner, synthetic regressions, six executable Swift workspace checks, and updated development/release notes. The Xcode project remains the native build system. After the build gate passed, both marketing-version settings and the splash/About version labels were updated to 1.0.7.

## Files changed

| Files | Purpose |
| --- | --- |
| `.gitignore`, `.vscode/tasks.json` | Ignore local build/evidence output and provide native build/test/tool-check/Xcode tasks. |
| `DVMetaDataBurnIn.xcodeproj/project.pbxproj`, `SplashContentView.swift`, `DVMetaDataBurnIn/AboutView.swift` | Version 1.0.7 settings and visible version labels, updated after the native build gate passed. |
| `DVMetaDataBurnIn/ContentView.swift`, `DVProcessor.swift` | Owned run preparation, launch/cancellation lifecycle, latest-workspace Finder access, removal of redundant GUI concat. |
| `Resources/scripts/dvmetaburn.zsh` | Remove inactive/duplicate code, initialize workspace/exit traps, preserve batch failure status, ensure stitch destination and concat success. |
| `Resources/scripts/lib/cleanup.zsh` | Workspace allocation/adoption, ownership/deletion guards, tracked child execution, signal and job cleanup. |
| `Resources/scripts/lib/artifacts.zsh` | Exclusive per-clip artifacts, JSON escaping, defer workspace deletion to job exit. |
| `Resources/scripts/lib/dvrescue.zsh`, `timeline.zsh` | Exact fractional rates, source-end/fallback duration, robust ASS event emission and sendcmd escaping. |
| `Resources/scripts/lib/pathing.zsh`, `filtergraph.zsh` | Literal path handling and FFmpeg escaping; reject logged sendcmd reinitialization failures. |
| `Resources/scripts/lib/logging.zsh`, `env.zsh` | Tracked external stages, JSON/literal strings, normal child priority. |
| `Resources/scripts/lib/pipeline.zsh` | Preserve failure statuses, unique work outputs, batch-safe returns and owned self-test paths. |
| `Resources/scripts/lib/encode.zsh` | Consolidate the previously active helper implementations without changing their defaults. |
| `Resources/scripts/lib/stitch.zsh` | Zsh manifest reading and tracked concat processes, fixed internal source extension. |
| `Resources/scripts/dev/smoke_sanitize_sendcmd.zsh`, `smoke_sendcmd_format.zsh`, `smoke_zsh_parse.zsh` | Repair smoke setup/newline checks, cleanup test scratch, parse developer scripts too. |
| `Resources/scripts/dev/check_environment.zsh`, `xcodebuild.zsh`, `test_all.zsh`, `tests/test_maintenance.py`, `tests/RunWorkspaceChecks.swift` | Tool inventory, local Xcode selection, reproducible runner, 26 automated regressions and six Swift workspace checks. |
| `readme.md`, `DEV.md`, `docs/DEV_TESTS.md`, `Change Log.txt`, this report | Current architecture, VS Code/native development, cleanup contract, results and release gate. |

## Final verification

- `zsh Resources/scripts/dev/test_all.zsh`: **26 regression tests passed**, no skips, plus **all three smoke scripts passed**. The final 1.0.7 rerun passed in 19.637 seconds; evidence is in `test-all-1.0.7-final.log`.
- Existing `--selftest`: **passed** burn-in MP4, subtitle MKV, convert-only, and 60p deinterlace checks using generated input. Its outputs are retained under the self-test run's artifacts, deliberately protected from recursive cleanup. The same four-stage self-test also passed using scripts, tools and fonts directly from the built 1.0.7 Release app (`bundle-selftest-1.0.7.log`).
- DV AVI → MOV: compressed video-packet hashes matched, retaining 720×480 DV video.
- MP4: synthetic burn-in/deinterlacing tests produced 37/37/74 frames for off/30p/60p and found overlay pixels on the last decoded frame.
- ASS: source-tail coverage, one-frame/subsecond/long-NTSC cases, multiple recording dates and midnight, event validity, missing-duration fallback, and subtitle packets in MKV passed. Both batch subtitle flags produced ordered clip-boundary packets.
- Batch: ordinary multi-file processing, mixed metadata burn-in fallback, rejection of stale output parts, one final stitched output, explicit stitch manifests, cleanup-on-success, and failure handling passed.
- Workspaces: concurrent allocation, path punctuation/Unicode, retention matrix, owner-token handoff, deletion guards, and stopping/reaping a real child before cleanup passed. Quoted/backslashed source paths retained valid diagnostic JSON.
- `git diff --check`: **passed**. `plutil -lint` on `project.pbxproj`: **passed**. Shared scheme XML and VS Code task JSON parsed successfully.
- The Xcode project differs from baseline only in its two marketing-version fields (1.0.6 → 1.0.7). All other project settings, bundled tools, fonts, and licenses are unchanged. Built runtime scripts, libraries, binaries and fonts were read back from the app and compared with source.
- The original Command Line Tools Swift attempts failed/reported duplicate `SwiftBridging` definitions and are retained as baseline evidence. Full Xcode compilation subsequently passed. Compiling and executing `RunWorkspaceChecks.swift` with the Xcode toolchain passed **six Swift workspace checks** for separate runs, owner markers, diagnostic preservation, failed-launch isolation, changed ownership and symlinked scratch parents.
- Native `xcodebuild`: the maintenance build **passed at 1.0.6 before the version bump**, then **1.0.7 Debug and Release builds passed**, using Xcode 15.4 and the original project/scheme. No compiler fixes or build-setting changes were needed. Builds use `CODE_SIGNING_ALLOWED=NO`; distribution signing, GUI behavior and real-footage acceptance are separate checks. Logs include simulator-service and locale diagnostics while still ending in `BUILD SUCCEEDED`.

Local, ignored evidence is under `.maintenance/`, including `baseline-build.log`, `test-all-final.log`, `selftest-final.log`, the initial Command Line Tools `final-build.log`, `xcode15-baseline-build.log`, `xcode15-debug-1.0.7-final.log`, `xcode15-release-1.0.7-final.log`, `test-all-1.0.7-final.log`, `swift-workspace-checks.log`, `bundle-selftest-1.0.7.log`, `environment-1.0.7.log`, and retained synthetic self-test outputs.

Local unsigned build outputs (the distribution copy is separately ad-hoc signed):

- `.build/Xcode15DerivedData/Build/Products/Debug/DVMetaDataBurnIn.app`
- `.build/Xcode15DerivedData/Build/Products/Release/DVMetaDataBurnIn.app`

## Remaining work and limits

1. Full Xcode is now located and the native build/version gate is complete. Use the project wrapper or VS Code build task to reproduce it with the external volume mounted. Keep the system developer selection and installed Command Line Tools untouched. See [DEV.md](../DEV.md) for an explicit `DEVELOPER_DIR` override if Xcode moves.
2. Perform GUI acceptance from that build: Finder workspace access, folder queues, Stop during each processing stage, two app instances with distinct outputs, and the retention controls. Syntax and CLI checks do not prove Swift lifecycle or UI behavior.
3. Review real camcorder footage and player rendering: timestamp appearance and date transitions, 480i motion/field order, 30p/60p motion, switchable subtitles, and clip joins. Positive automated metadata is synthetic; actual DVRescue was exercised for the missing-RDT case. Full damaged-tape/camera coverage, native Apple Silicon operation, distribution signing, and audio/quality subjective acceptance remain unverified.
4. Retain existing per-clip/continuous routing; this release does not invent a new distinction between those modes. Mixed metadata burn-in stitching is automated; heterogeneous subtitle-stream stitching and player-specific edge cases merit real-footage follow-up.
5. The ownership guard intentionally preserves workspaces containing selected inputs/outputs, including generated `--selftest` outputs. SIGKILL/power loss cannot run cleanup traps. Existing final-output overwrite behavior and names are unchanged; callers running identical inputs concurrently should use distinct destinations. Direct-output encoder failures can still leave a partial final file; this maintenance change does not delete potentially preexisting user exports.
6. Further library/UI restructuring and dormant compatibility helpers were left alone where removal would provide little benefit without broader GUI/real-footage validation. No architecture rewrite or new runtime dependency was introduced.

Rebuild using [DEV.md](../DEV.md), then perform the remaining manual acceptance checks in [DEV_TESTS.md](DEV_TESTS.md). The owner authorized publication of the maintenance prerelease and a draft pull request. The maintenance branch remains open for additional bug fixes before a future merge into `main`. GUI and real-footage acceptance remain pending.
