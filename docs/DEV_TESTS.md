# Developer tests

Run all automated checks from the repository root:

```sh
zsh Resources/scripts/dev/test_all.zsh
```

The VS Code **DVMeta: run automated tests** task runs that same command. It stops on a failure and uses the checkout's bundled FFmpeg and DVRescue by default. `FFMPEG_BIN` and `DVRESCUE_BIN` can explicitly select other tools for comparison. Tests create disposable synthetic fixtures; no owner footage is read or changed.

The runner needs Zsh and a developer Python 3 interpreter (default `/usr/bin/python3`, override with `DVMETA_TEST_PYTHON`). Media inspection uses a developer `ffprobe` on PATH; those tests explicitly report skips if it is unavailable. Neither Python nor ffprobe is a new application dependency. The November 12, 2026 run used bundled FFmpeg 8.0.1-tessus, DVRescue 24.07, and an existing ffprobe, with no skips.

## Smoke checks

- `smoke_zsh_parse.zsh`: `zsh -n` on the entrypoint, libraries, and developer Zsh scripts.
- `smoke_sanitize_sendcmd.zsh`: mixed CR/CRLF, BOM, comments, semicolons, effective row count, and final newline; includes a bundled-FFmpeg parse check.
- `smoke_sendcmd_format.zsh`: builds a filtergraph and its sanitized execution file, invokes FFmpeg, and rejects drawtext reinitialization errors even when FFmpeg returns zero.

The two sendcmd smoke scripts clean their own temporary directories. Newline tests inspect the final byte; command substitution strips newlines and cannot test for one.

## Automated regression fixtures

`Resources/scripts/dev/tests/test_maintenance.py` uses Python's standard `unittest` library and invokes the active Zsh code.

| Area | Assertions |
| --- | --- |
| ASS final duration | One frame, subsecond and short clips; last event reaches the source end rather than one frame after the last metadata change. |
| NTSC and long clips | Exact 30000/1001 timing, rational FPS input, hour-long timeline arithmetic, correct minute/hour carry, invalid FPS rejection. The long clip uses a synthetic probe banner rather than an hour of encoded video. |
| Metadata discontinuities | Midnight date rollover and a later recording session preserve their recorded values at their actual frame positions. |
| Event validity | Duplicate/backwards/zero frame indices and rows beyond the source are excluded; no negative, empty, or overlapping events within either visual style; single and stacked layouts, per-frame granularity. |
| Duration fallback | Last numbered DVRescue row bounds the tail even if that row has no date/time. |
| Workspace ownership | Concurrent runs get distinct roots; success/failure/never policies and keep-on-failure; mismatched ownership, changed roots, symlinks, protected destinations; GUI ownership handoff. |
| Cancellation | A real tracked child stops before cleanup; only that child is signalled. |
| DV passthrough | Synthetic 720×480 DV AVI → MOV retains identical compressed video-packet hashes. |
| MP4/burn-in | FFmpeg produces 37 input-rate frames with deinterlace off/30p and 74 frames with 60p; a final decoded frame contains the overlay. This does not constitute visual approval of deinterlacing. |
| Subtitle track | MKV contains an ASS track whose final packet covers the last source frame. |
| Paths and manifests | Spaces, apostrophes, double quotes, Unicode, brackets, comma, colon, semicolon, dollar and backslash characters in input/scratch/font paths; manifests remain parseable JSON. |
| Missing metadata | Actual bundled DVRescue on generated DV without RDT; fallback conversion, skip, and error policies are distinguished. |
| Batch and stitching | Multiple clips with cleanup-on-success, single final output, both subtitle modes with ordered clip boundaries, regular batch, explicit stitch manifests, mixed metadata fallback, rejection of stale destination parts, encoder/concat failure reporting. |

Recording metadata in the positive media fixtures is supplied by a controlled DVRescue-log producer. This isolates timeline/encoding tests; it does not prove metadata extraction from every camera or damaged tape. The negative metadata fixture invokes the actual bundled DVRescue binary.

## App build and resources

```sh
zsh Resources/scripts/dev/xcodebuild.zsh -project DVMetaDataBurnIn.xcodeproj \
  -scheme DVMetaDataBurnIn -configuration Debug \
  -derivedDataPath .build/Xcode15DerivedData CODE_SIGNING_ALLOWED=NO build
```

After a successful build, inspect `.build/Xcode15DerivedData/Build/Products/Debug/DVMetaDataBurnIn.app/Contents/Resources/`: the `scripts` folder must contain `dvmetaburn.zsh` and the entire `lib` directory, and the bundled binaries/fonts must be present. The Xcode project uses a folder reference for scripts so newly added libraries remain bundled. Source-level project checks do not replace inspecting the built app.

The owner identified full Xcode at `/Volumes/1 TB Storage/xcode-15.4/Xcode.app`. Using Xcode 15.4, the native project compiled successfully at version 1.0.6, after which the version was updated and the 1.0.7 Debug and Release builds passed. Runtime scripts, libraries, tools and fonts were read back from the built apps and compared with source. The Release app's bundled pipeline also passed its four-stage CLI self-test. The project build wrapper selects this installation locally while leaving the system-wide Command Line Tools selection unchanged.

Six additional Swift checks in `Resources/scripts/dev/tests/RunWorkspaceChecks.swift` passed when compiled alongside `DVProcessor.swift` with the Xcode toolchain. They test exclusive allocation, literal owner tokens, launch-copy cleanup with retained diagnostics, failed-launch isolation, changed-marker refusal and symlinked scratch parents. The compile/run command is in [DEV.md](../DEV.md). The regular 26-test runner remains usable without full Xcode.

Earlier Command Line Tools build/type-check failures are retained as baseline evidence; they do not describe the successful Xcode build. Build logs can include simulator-service and locale diagnostics even for this macOS target. Use the final build status to distinguish those from compiler failures. See [maintenance status](MAINTENANCE_1.0.7.md).

## Manual acceptance still required

Using a newly built app, check single-file processing, folder queues, all output modes, 480i motion and field order, 30p/60p motion, switching subtitles during playback, date/time readability, multiple real recording sessions, and Finder scratch/artifact access. Run two app instances concurrently with different outputs. Cancel during DVRescue, encoding, and stitching; confirm the UI waits, the next queued folder does not start, and retention matches the selected policy. Confirm low/medium/high quality and audio-only exports remain suitable.

Test mixed metadata using original camera footage only when the owner chooses appropriate samples. Confirm one final stitched output and correct subtitle boundaries across clip joins. Distribution signing, native Apple Silicon operation, player-specific subtitle rendering, real camera metadata, crash/power-loss cleanup, and end-to-end GUI acceptance are not established by the synthetic suite.

## Optional real-footage fixture

The [train preservation demonstration](examples/TRAIN_DV_PRESERVATION.md) includes hash-pinned downloads and explicit-path verification commands. It is opt-in and is not downloaded or processed by the default tests. Its single-clip CLI evidence does not replace GUI, motion/audio, target-player, or Apple Silicon acceptance.
