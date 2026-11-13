# Preservation roadmap

The goal is accurate, accessible preservation of legacy digital recordings and their original recording context. This is a direction and acceptance checklist, not a delivery schedule. [The train demonstration](examples/TRAIN_DV_PRESERVATION.md) records what has actually been measured. See the [current evidence summary](PROJECT_STATUS.md) and [community validation guide](COMMUNITY_VALIDATION.md).

## Completed and available

- Existing-file macOS workflow: DV AVI input, embedded recording-date extraction through DVRescue, timestamp overlays and switchable subtitles, batch processing, and FFmpeg output handling.
- Public train example: untouched supplied AVI reference and supplied viewing copy, separately identified maintenance derivatives, hashes, measured metadata, and repeatable verification.
- Application MIT terms exposed at the repository root, with separate dependency and sample-rights documentation.

## In progress: complete the 1.0.7 maintenance release

**Branch policy:** `main` retains the 1.0.6 application code; `maintenance/1.0.7` retains the 1.0.7 preview for owner testing. The premature merge of PR #191 was reversed by [PR #193](https://github.com/shardsofaperture/DVMetaDataBurnIn/pull/193), restoring the stable application code, without deleting the maintenance branch or rewriting history. No further maintenance integration or release promotion is authorized until the owner approves it after testing. Subtitle-tail timing, scratch isolation, cancellation cleanup, and failure propagation have synthetic/CLI evidence. The train clip adds bounded real-footage evidence, including a field-flag mismatch in deinterlacing-off H.264 output.

Acceptance: match extracted recording dates to overlays/subtitle events across real fixtures; verify safe folder queues and Stop at every processing stage; demonstrate independent concurrent workspaces; reject failed or partial final outputs without overwriting valid owner exports; show useful progress and actionable errors. Confirm these through GUI and player checks, not only shell tests. Retain current-plus-rollback builds. See the [maintenance report](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/docs/MAINTENANCE_1.0.7.md).

## Planned: strengthen preservation verification

Prerequisites: owner-authorized real-camera fixtures with original hashes, camera/format provenance, and independently confirmed facts where possible. Add genuine recording breaks, day changes, and damaged-input examples only when such material exists.

Acceptance: reproducible metadata reports; container-independent DV payload comparison; separate audio, duration, frame, and subtitle checks; safe publication of final outputs; documented player review and Intel/Apple Silicon validation as separate gates. Resolve metadata-versus-decoded-field discrepancies and verify motion visually. Preserve each untouched capture even when a derivative passes selected checks. Resolve [FFmpeg source/notices #194](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/194), [DVRescue dependency evidence #195](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/195), and [VCR OSD Mono terms #196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196), as detailed in the [distribution audit](THIRD_PARTY_DISTRIBUTION_AUDIT.md). Track [field signaling #197](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/197) and [safe final-output publication #198](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/198) before claiming those behaviors verified.

## Planned: direct DV/Digital8 capture

Investigate suitable open-source capture components, starting with [DVRescue's capture documentation](https://mipops.github.io/dvrescue/sections/capture). Its documented workflow uses supported DV equipment and a FireWire connection; the app does not currently integrate capture. Hardware, adapters, device control, and operating-system support must be tested as a combination. Reducing dependence on the legacy Sony laptop is a goal, not a promise that those requirements disappear.

Prerequisites: an identified camera/deck and supported recording format, a tested host/connection chain, permission to use test tapes, and an evaluated capture component. Digital8 DV recordings must be distinguished from analog Video8/Hi8 playback or conversion; support cannot be inferred from a tape fitting a device. See [DVRescue's format guide](https://mipops.github.io/dvrescue/sections/dv_formats.html).

Acceptance: native DV-stream retention; device discovery/control; recording metadata and continuity/dropout reporting; bounded interruption/reconnection recovery; read-back hashes and A/V checks against approved captures. Document the exact supported device/format/host matrix before advertising capture support.

## Planned later: HDV capture

Treat HDV as a separate capture, container, and metadata workstream. DVRescue's current [capture scope](https://mipops.github.io/dvrescue/sections/capture) excludes HDV. Shared cassette shapes do not make DV and HDV streams interchangeable.

Prerequisites: suitable open-source capture tooling, an HDV-capable device and tested connection, native MPEG-2 transport-stream handling, representative HDV material, and a format-specific metadata strategy.

Acceptance: preserve the native stream without an implicit DV transcode; verify audio/video continuity and metadata extraction; test interruptions, recovery, and player compatibility on real hardware. Keep HDV test evidence separate from DV/Digital8 acceptance. Cross-platform implementation and a new capture-engine rewrite are outside this roadmap's current scope.

## Future integration after owner acceptance

PR #191 is historical and closed. Because its merge was reversed on `main`, a future ordinary merge of the maintenance branch alone may not reapply those reverted changes. After explicit owner approval, prepare a fresh integration PR that reverses the corrective revert or reapplies the tested maintenance changes; review the complete application diff and run the acceptance gates. Never treat the closed PR or existing ancestry as approval to ship 1.0.7.
