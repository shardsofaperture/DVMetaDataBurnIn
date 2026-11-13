# Verified project status

Updated November 13, 2026 after PR #200 and maintenance engineering verification. This is the current summary; dated reports below preserve historical evidence.

## Application and branch policy

- **Stable application: 1.0.6.** The stable runtime restored at `da0a3b97126578d45d24e65573e85367c1f7979e` remains on `main`, which retains the pre-maintenance runtime. Its public package is still named [1.0.6 beta](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/1.0.6beta); “stable” describes the owner's retained baseline, not completed compatibility certification.
- **Experimental implementation: 1.0.7.** [`maintenance/1.0.7`](https://github.com/shardsofaperture/DVMetaDataBurnIn/tree/maintenance/1.0.7) includes runtime fix `2802355` for final-output safety and H.264 field signaling. [Preview 1](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.1) is still the original `5f7e13e` package and does **not** contain those fixes. No stable release or tag is changed.
- PR #191 prematurely integrated maintenance code; [PR #193](https://github.com/shardsofaperture/DVMetaDataBurnIn/pull/193) restored stable runtime on main. That historical integration is **superseded**, not ongoing authorization. Main and maintenance share public documentation/licensing corrections. Only owner testing and explicit acceptance can authorize future runtime integration.
- The eight audited historical app ZIPs contain x86_64 FFmpeg and DVRescue executables. The stable 1.0.6 app executable (and older apps) has x86_64/arm64 slices; preview 1.0.7 is x86_64-only. An arm64 UI slice does not make the Intel tools native or prove Apple Silicon operation. Current packages declare macOS **12.0 minimum**. Native build/tool evidence is Intel macOS 14 with Xcode 15.4; this is not testing across all macOS 12+ versions. Native Apple Silicon and Rosetta operation remain unverified. No Windows/Linux application support is claimed. Preview signing is ad-hoc, not notarized.

## Historical preview 1 evidence and limits

| Claim / check | Verified evidence | What it does not establish |
| --- | --- | --- |
| Synthetic regressions and native builds | November 12 preview `5f7e13e`: 26 regressions, three shell smoke checks, Release build. Six Swift workspace checks and Debug/Release builds were also recorded earlier that day. November 13 integration `41abf9d`, with the same preview runtime: fresh 26 regressions, three smoke checks, six Swift checks, native Intel Release build. | GUI operation, real-player acceptance, Apple Silicon or comprehensive recording accuracy. These are historical checks, not newly run by this documentation audit. |
| DV video and audio in MOV | November 13 [train evidence](examples/TRAIN_DV_PRESERVATION.md), preview `5f7e13e`: original and MOV match concatenated encoded DV payload and native-rate/channel decoded PCM hashes, with 238 frames and matching extracted date rows. `encode.zsh` uses video/audio copying for MOV. | Every container metadata field, every input/camera or universal player support. Keep the original AVI. |
| MP4/MKV audio | H.264 viewing copies use AAC; full decode passed. Published measurements distinguish priming/padding/sample counts. | PCM identity, listening quality or lip-sync acceptance. |
| Recording dates and transitions | One original Sony MiniDV capture: stored dates 2025-11-11 08:29:35–43; eight second transitions inspected in overlays; nine ASS events cover the final frame. | Independent historical camera-clock truth, damaged tape, other cameras, real midnight/day changes or interior recording breaks. Synthetic fixtures cover some of those timeline cases. |
| Subtitle tail and NTSC timing | Synthetic short/long/fractional-rate cases; real train subtitle coverage through ~7.941 s. AVI rate 2997/100 is distinguished from nominal DV 30000/1001; 60p output is 60000/1001. | Exact-rate metadata in every output container, player subtitle rendering/toggling or all-input timing correctness. |
| Interlaced/deinterlaced output | DV/MOV decode bottom-field-first; 60p derivative has 476 frames. Deinterlacing-off H.264 retains combing but progressive decoded flags; MKV container/decoded flags disagree. | Correct moving-picture cadence or all-player behavior. [Field-signaling issue #197](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/197) remains open. |
| Batch cancellation and temporary isolation | Maintenance source and synthetic child-process/workspace tests cover ownership, isolation, failure propagation and tracked cancellation. | GUI folder queues/Stop, every cancellation stage, crash/power-loss cleanup or safe publication of every final output. This historical limitation was fixed on maintenance; [issue #198](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/198) is closed. |

Source references for maintenance claims: [encode.zsh](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/5f7e13e0b9f94b98bfef32c5d828aae614265583/Resources/scripts/lib/encode.zsh), [timeline.zsh](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/5f7e13e0b9f94b98bfef32c5d828aae614265583/Resources/scripts/lib/timeline.zsh), [regression tests](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/5f7e13e0b9f94b98bfef32c5d828aae614265583/Resources/scripts/dev/tests/test_maintenance.py). Those maintenance fixes must not be attributed to stable 1.0.6.

Published evidence is the separate [train example release](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/examples-train-dv-v1), its original/derivative hashes, stream measurements, metadata rows, transition images and reproduction commands. The owner's supplied MP4 has unknown producing app version; only the four identified maintenance derivatives are bound to `5f7e13e`. CLI results do not prove GUI acceptance. No independent tester reports or adoption evidence were established by this audit; owner-supplied footage and maintainer-run checks are identified as such.

## Completed engineering and distribution corrections

PR #200 integrated documentation only. Main's Swift, Xcode project, runtime scripts, tools and fonts still match the restored 1.0.6 baseline. Narrow shared documentation updates preserve that boundary.

Maintenance runtime `2802355` passes 33 synthetic regressions and three shell checks, including failed/cancelled encodes, destination collisions and extracted H.264 bitstream flags. Fresh train CLI checks preserve 238 DV frames and PCM in MOV, correctly signal 238 bottom-field-first H.264 frames in MP4/MKV, retain 476 progressive frames at 60p and nine subtitles ending at 7.95 seconds. [Machine-readable results](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/docs/audit/2026-11-13/maintenance-output-verification.json) and the [maintenance report](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/docs/MAINTENANCE_1.0.7.md) distinguish these checks from player/GUI acceptance. Historical table rows above describe Preview 1, not the new code.

The original official DVRescue 24.07 package now matches the distributed executable byte for byte. Twelve verified notice texts are preserved in [the supplement](audit/2026-11-13/DVRESCUE-NOTICES.txt) and appended to the existing bundled notice. The historical [provenance receipt](audit/2026-11-13/dvrescue-provenance.json) preserves the earlier DeckLink/build-manifest uncertainty. The [non-font review](THIRD_PARTY_DISTRIBUTION_AUDIT.md#non-font-readiness-review--november-13-2026) resolves #195: verified notice delivery and the SDK Include-file/object-code exceptions satisfy the inspected distribution requirements. Exact historical SDK/build mapping is optional provenance. The [release integrity gate](../scripts/verify_release.py) rejects mismatched tags, manifests, built versions and hashes. The historical 1.0.4beta ZIP remains unchanged and labeled as containing version 1.0.3; its actual runtime provenance is not inferred from either label.

## UAV font permission update — November 13, 2026

On November 13, 2026, Nicholas Kruse, the original author of UAV OSD Mono and UAV OSD Sans Mono, granted DVMetaDataBurnIn express written permission to use and redistribute both fonts. The correspondence is privately retained by the maintainer. This project-specific permission resolves the UAV redistribution concern in [#196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196); it is not an OFL license, a public-domain dedication, or blanket permission for unrelated projects. Existing copyright attribution and source links are retained. Issue #196 remains open only for VCR OSD Mono by Riciery Leal.

## Outstanding work

Application submission evidence is materially improved, but **complete distribution readiness cannot yet be claimed**. Exact FFmpeg corresponding source/build materials and dependency notices (#194) and explicit VCR OSD Mono redistribution/embedding evidence (#196) remain external evidence dependencies. See the [distribution audit](THIRD_PARTY_DISTRIBUTION_AUDIT.md) for exact findings. Application MIT terms and authorship remain unchanged.

Accepting the entire 1.0.7 release is not required to complete documentation, notice repair or the packaging gate. Before promoting 1.0.7, complete GUI queues/Stop, player subtitle/motion/audio review, broader real-camera cases and platform acceptance. #197 remains open only as a moving-picture/player acceptance gate before stable 1.0.7 promotion; the technical correction and automated verification are complete. It does not block maintenance commits, experimental prereleases, documentation or unrelated licensing work. #198 concerns publication safety, with GUI acceptance tracked separately. Use the [community validation guide](COMMUNITY_VALIDATION.md). Direct DV/Digital8 and HDV capture remain [planned](ROADMAP.md).

## Experimental preview 2 update

[Preview 2](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.2)
packages the later output-safety and field-signaling fixes, source-built FFmpeg
and capture-free DVRescue, and three explicitly OFL-licensed fonts. Its source
archives, patch, build receipts and hashes accompany the download. Validation
includes 35 regressions, three shell checks, 11 release-gate tests, an Intel
Release build and fresh train CLI verification. Two clean DVRescue builds from
the publisher archive and delivered CLI subset produced identical binaries.

The [active maintenance report](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/docs/MAINTENANCE_1.0.7.md)
contains the current evidence and GUI/player/Apple Silicon limits. Main remains
the stable 1.0.6 application. Historical #194 and #196 remain open for the old bytes
(with #196 now limited to VCR OSD Mono);
replacement provenance is not claimed to repair those historical obligations.
