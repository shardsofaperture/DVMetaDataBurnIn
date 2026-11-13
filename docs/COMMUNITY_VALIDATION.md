# Community real-camera validation

Successful tests and discrepancies are both useful. This guide separates application behavior, upstream utility measurements and manual observations. See [current status](PROJECT_STATUS.md) before interpreting a pass: **main is the retained 1.0.6 baseline; 1.0.7 is an unconfirmed preview.**

## 1. Choose the application and record your environment

Download [1.0.6 beta](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/1.0.6beta) for the retained application, or [1.0.7 Maintenance Preview 1](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.1) to test maintenance changes. Keep them separately identified. The preview release includes a manifest and SHA256SUMS; verify the ZIP before extracting. Its source is `5f7e13e0b9f94b98bfef32c5d828aae614265583`. Report the package/tag and archive hash; if building locally, also report `git rev-parse HEAD` and whether the tree was modified.

Current packages declare macOS 12 minimum. Stable 1.0.6 has an Intel/Apple Silicon app executable with Intel-only bundled tools; preview 1.0.7 is Intel-only throughout. Apple Silicon/native or Rosetta acceptance is still open. The preview is ad-hoc signed and not notarized. Use macOS's normal controls for opening software you trust. [Distribution evidence gaps](THIRD_PARTY_DISTRIBUTION_AUDIT.md) remain public.

Record Mac model, macOS version, Intel/Apple Silicon and any translation used. Do not include serial numbers, hardware UUIDs, usernames or full personal paths.

## 2. Download the existing train demonstration

Use the [train release](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/examples-train-dv-v1); no republishing is needed. The original is the reference, not a generated replacement. The following shell commands download a minimal comparison set into a new directory:

```sh
mkdir train-validation
cd train-validation
TRAIN_RELEASE=https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/download/examples-train-dv-v1
for asset in train-01-original-dv.avi train-01-maintenance-dv-copy.mov train-01-maintenance-subtitles.mkv manifest.json; do
  curl --fail --location --output "$asset" "$TRAIN_RELEASE/$asset" || break
done
shasum -a 256 train-01-original-dv.avi
```

The original must hash to `13be6af4cc481e5eea0a8ed9daee8d9ef329abd79ccc5c6620147604cefcca0a`. The verifier below checks every supplied sample against `manifest.json`; compare that manifest with the [repository copy](examples/train-dv/manifest.json). To inspect overlays/motion too, download the identified deinterlacing-off and 60p MP4s from the release. The owner's MP4 has unknown producing version/settings and must not be used as proof of 1.0.6 or 1.0.7 behavior.

## 3. Inspect without running the application

These checks use **upstream utilities**, not the app GUI. Use existing trusted FFmpeg, ffprobe and DVRescue installations and record their versions. ffprobe is not bundled with the application. macOS developers can use MacPorts or official publisher binaries; no new installation is required if the tools already exist.

In the download directory, substitute your tool paths:

```sh
FFMPEG=/path/to/ffmpeg
FFPROBE=/path/to/ffprobe
DVRESCUE=/path/to/dvrescue
"$FFMPEG" -version
"$FFPROBE" -version
"$DVRESCUE" --version
"$DVRESCUE" train-01-original-dv.avi > original-metadata.txt 2> original-metadata-diagnostics.txt
"$FFPROBE" -v error -count_frames -show_streams -show_format -of json train-01-original-dv.avi > original-streams.json
"$FFPROBE" -v error -select_streams s -show_packets -show_entries packet=pts_time,duration_time -of json train-01-maintenance-subtitles.mkv > subtitle-packets.json
```

For the project's existing automated comparisons, obtain a repository checkout containing [verify_train_demo.py](../scripts/verify_train_demo.py), set `REPO` to it and run from the download directory:

```sh
REPO=/path/to/DVMetaDataBurnIn
python3 "$REPO/scripts/verify_train_demo.py" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE" --dvrescue "$DVRESCUE" --manifest manifest.json --reference train-01-original-dv.avi train-01-original-dv.avi train-01-maintenance-dv-copy.mov train-01-maintenance-subtitles.mkv > verification-local.json
```

Exit zero means the verifier's selected checks passed. Review the JSON and compare it with [published measurements](examples/train-dv/measurements.json) and [verification](examples/train-dv/verification.json). Tool-version differences can affect reporting; record them before interpreting a discrepancy. The script hashes inputs before/after, decodes streams, compares DV payload and PCM audio, extracts recording dates and checks subtitle coverage. It neither encodes new media nor proves GUI operation, camera-clock truth or subjective quality.

Expected bounded results:

| Check | Published expectation |
| --- | --- |
| Original and MOV | 238 DV frames, 720x480, SAR 8:9, 48 kHz/two-channel PCM; identical encoded DV payload and decoded PCM hashes. AVI layout tag is unknown, not independently confirmed stereo metadata. |
| Rates | AVI/MOV report 2997/100; nominal DV metadata rate is 30000/1001. 60p MP4 is 60000/1001 with 476 frames. |
| Recorded date/time | 2025-11-11 08:29:35 through 08:29:43. This is the stored camera clock, not independently verified historical time. |
| Second transitions | Zero-based source frames 24, 54, 84, 114, 144, 174, 204, 234. Inspect both sides of each transition; in 60p use frames 2*n-1 and 2*n. |
| ASS subtitles | Nine positive, nonoverlapping intervals; final interval 7.80–7.95 s covers the final video packet ending near 7.941 s. Compare text with the [original ASS](examples/train-dv/train-01-maintenance-timestamps.ass). |
| H.264/AAC derivatives | Lossy viewing copies; no original-audio identity claim. Deinterlacing-off combing/progressive-flag mismatch is known ([#197](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/197)). |

## 4. Test the application or reproduce CLI processing

**GUI test:** open the chosen application, select the downloaded original AVI, choose a new output directory, and record every setting. Test DV-copy MOV with timestamps off, burn-in MP4 with deinterlacing off or 60p, or MKV with switchable subtitles. Compare the new output with the reference using the verifier **without `--manifest`**, because your derivative is not an existing published asset. Compare measured properties and dates; do not require byte-identical newly encoded MP4/MKV files.

**CLI reproduction:** the four historical command argument lists are in [processing-commands.json](examples/train-dv/processing-commands.json). They use the preview source checkout, not main's 1.0.6 scripts. For a single MOV reproduction from the extracted preview app, run this in the download directory after replacing `APP_RES`:

```sh
APP_RES=/path/to/DVMetaDataBurnIn.app/Contents/Resources
SOURCE="$PWD/train-01-original-dv.avi"
WORK=$(mktemp -d "$PWD/reprocess.XXXXXX")
zsh "$APP_RES/scripts/dvmetaburn.zsh" --mode=single --layout=stacked --format=mov --quality=high --burn-mode=off --deinterlace=off --ffmpeg="$APP_RES/ffmpeg" --dvrescue="$APP_RES/dvrescue" --fontfile="$APP_RES/UAV-OSD-Sans-Mono.ttf" --fontname="UAV OSD Sans Mono" --dest-dir="$WORK/generated" --output-base=train-check --scratch-dir="$WORK/scratch" --scratch-cleanup=never "$SOURCE"
python3 "$REPO/scripts/verify_train_demo.py" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE" --dvrescue "$DVRESCUE" --reference "$SOURCE" "$WORK/generated/train-check_conv.mov" > "$WORK/verification.json"
```

Use separate destinations for concurrent runs and keep originals untouched. Scratch is deliberately retained here for diagnosis. CLI success is a CLI result. A GUI report should separately describe file selection, progress, folder queue behavior, Finder workspace access and Stop. Cancellation can leave a partial final output ([#198](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/198)); test with disposable derivatives in a new destination.

## 5. Observe playback and report the result

Manual checks require a player, viewing and listening: report player/version, subtitle visibility and toggling (including the final frame), timestamp placement, moving train cadence/field order, audio quality and apparent A/V sync. Still images and decode success cannot answer those questions. Record pass/fail/not tested separately for each mode and player.

Open a [real-camera validation report](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/new?template=real-camera-validation.yml). If the form is not yet on the default branch, use [the template fields](../.github/ISSUE_TEMPLATE/real-camera-validation.yml) in a [blank issue](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/new). A successful test is useful; state exactly what passed and what was not exercised. Include version/commit or package identity, hardware/OS, source hash, modes/settings, expected/actual results and reproducible steps. Link the existing public sample instead of uploading another copy.

## 6. Optionally test your own recording

Keep an untouched original and work on a copy with a neutral filename such as `sample-01.avi`. Identify DV/MiniDV/Digital8 recording format, PAL/NTSC if known, camera, capture method and input container. Digital8 recording is distinct from analog Video8/Hi8 conversion. Direct capture and HDV capture are planned features, not supported app workflows today.

Useful additional cases include missing recording dates, real recording breaks, midnight/day changes, PAL, different cameras and damaged tape. Record any independent reference for the camera clock; otherwise say accuracy is unknown. Do not infer historical truth from agreement between two tools reading the same metadata.

Samples are optional. Only share material you have permission to publish. Review logs/JSON/XML for filenames, personal paths, camera dates, container titles and other identifying metadata before posting; tools and this verifier can retain some of these fields. Share a small relevant excerpt or sanitized measurements if the recording is private. Do not upload whole family tapes to report a result. Redaction or editing can change evidence, so describe it without exposing the original information.
