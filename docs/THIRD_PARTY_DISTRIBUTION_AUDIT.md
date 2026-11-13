# Third-party distribution audit

> Maintenance update: preview 2 replaces the tools with pinned source builds and the fonts with OFL alternatives. See [current licensing and source delivery](LICENSING.md). The dated findings below apply to the original eight ZIPs; those bytes and their unresolved historical questions are preserved.

Audited November 13, 2026. **Distribution readiness remains partially verified.** This records what the distributed files demonstrate and the specific materials still needed; it does not certify blanket compliance or change any license terms.

## UAV permission update — November 13, 2026

On November 13, 2026, Nicholas Kruse, the original author of UAV OSD Mono and UAV OSD Sans Mono, granted DVMetaDataBurnIn express written permission to use and redistribute both fonts. The correspondence is privately retained by the maintainer. This project-specific permission resolves the UAV redistribution concern in [#196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196); it is not an OFL license, a public-domain dedication, or blanket permission for unrelated projects. Existing copyright attribution and source links are retained. The remaining font permission requirements concern only VCR OSD Mono by Riciery Leal. Dated source checks and original distribution artifacts remain unchanged.

## Scope and reproducible evidence

Downloaded all eight published application ZIPs: `alpha`, `0.2.0alpha`, `0.3.0alpha`, `1.0.0beta`, `1.0.4beta`, `1.0.5beta`, `1.0.6beta`, `v1.0.7-maintenance.1`. Every archive's SHA-256 matched its GitHub asset digest. Inspected ZIP entries, Mach-O headers, Info.plist, binaries, fonts and license texts. Each contains exactly three Mach-O executables: the app, FFmpeg and DVRescue. All tool binaries are x86_64-only; stable 1.0.6 and older app executables have x86_64/arm64 slices, while preview 1.0.7 is x86_64-only. These headers establish architecture, not compatibility acceptance. No extra bundled dylibs/frameworks were found. Static dependencies inside executables require separate evidence.

[Release inventory](audit/2026-11-13/release-inventory.json) records exact asset URLs, archive/resource hashes, paths and version fields. [Binary readouts](audit/2026-11-13/binary-readouts.json) preserve `-version`, `-buildconf`, `-L`, `file` and `otool -L` evidence. Both repository branches contain the same dependency bytes. The app's root MIT text equals its bundled application notice; no root-license correction was needed.

Stable 1.0.6 has flat license files under `Contents/Resources/`; the preview also has a `licenses/` directory. Both include the existing FFmpeg GPL/LGPL texts, FFmpeg licensing overview, MIPoPS BSD notice, application MIT text and font attribution. Their presence is verified, but they do not constitute a complete dependency source/notice set. The [historical 1.0.4beta package version mismatch](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/199) is separate from licensing: its Info.plist says 1.0.3. Current stable/preview say 1.0.6/1.0.7.

Statuses: **Verified** = the stated evidence/requirement has been checked; **Partially verified** = identity or some materials confirmed, with gaps; **Unresolved** = required evidence not established; **Not applicable** = the stated requirement does not apply to the inspected distribution. A verified identity is not a verified distribution-compliance conclusion.

| Component actually distributed | Identity and license evidence | Source/build and accompanying materials | Status / action |
| --- | --- | --- | --- |
| FFmpeg executable, 8.0.1-tessus | Same binary in all eight ZIPs; exact SHA match to [Evermeet 8.0.1 ZIP](https://evermeet.cx/ffmpeg/ffmpeg-8.0.1.zip). Reports GPL-3.0-or-later, `--enable-gpl --enable-version3`, Apple clang 17.0.0 and static dependency flags. No `--enable-nonfree` reported. | Existing GPL/LGPL texts included. Configure line verified. Exact corresponding source, patches, dependency sources/notices and complete build scripts not found in inspected delivery materials. [Upstream FFmpeg source](https://ffmpeg.org/download.html) alone does not establish this build's provenance. | **Partially verified** identity/config/license; **Unresolved** source delivery and dependency notices: [#194](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/194). |
| DVRescue executable, 24.07; MediaInfoLib 24.06 reported | Exact match to MediaArea’s official 24.07 Mac package; original MIPoPS BSD-3-Clause attribution retained. | Same-release all-in-one source includes MediaInfoLib 24.06 and ZenLib 0.4.41. Twelve verified notices accompany historical downloads. DeckLink Include-file grants permit compiled redistribution without an additional notice requirement. | **Resolved #195** distribution requirements; exact historical SDK/build revision remains optional provenance. See the non-font review below. |
| UAV-OSD-Mono.ttf and UAV-OSD-Sans-Mono.ttf, embedded version 1.0 | Both exactly match [author-linked download](https://dl.dafont.com/dl/?f=uav_osd). Nicholas Kruse's [author note](https://www.dafont.com/uav-osd.font) permits personal/commercial use. Author's [project page](https://nicholaskruse.com/work/uavosd) identifies both designs. Existing attribution retained. | The inspected download contains only two fonts; no standalone license or explicit redistribution/embedding/attribution conditions were found in those files or name tables. The subsequently obtained direct written permission is recorded above. The published subtitle MKV attaches the Sans font. Font source/build provenance was not supplied. | **Resolved** UAV redistribution concern: express written project use/redistribution permission granted by Nicholas Kruse on November 13, 2026, privately retained by the maintainer. [#196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196) remains open only for VCR OSD Mono. |
| VCR_OSD_MONO.ttf, embedded version 1.001 (March 31, 2015); older ZIPs name it VCR_OSD_MONO_1.001.ttf | Exact match to [author-linked download](https://dl.dafont.com/dl/?f=vcr_osd_mono). Riciery Leal / mrmanet's own [February 24, 2017 comment](https://www.dafont.com/font-comment.php?file=vcr_osd_mono) permits commercial use; other users' comments are not permission evidence. Existing attribution retained. | Download contains only the font; no standalone license or explicit redistribution/embedding/attribution conditions found. Font source/build provenance was not supplied. | **Partially verified** origin/use permission; **Unresolved** distribution terms: [#196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196). |
| macOS system frameworks, libc++, libSystem, system zlib, Objective-C runtime | `otool -L` identifies system references; their paths are in the readouts. | These libraries are provided by macOS and are not copied into the inspected ZIPs. This does not inventory static dependencies. | **Not applicable** to bundled-library source delivery in these ZIPs. |
| ffprobe / ffplay | Neither executable occurs in the app ZIPs. ffprobe is an optional external verification utility; the bundled FFmpeg README also describes upstream tools not shipped here. | Testers supply their own ffprobe. | **Not applicable** to this app's binary distribution inventory. |

[Audit checks](audit/2026-11-13/audit-checks.json) record Markdown/relative-link checks, shell-command syntax, JSON/YAML parsing, unchanged application licensing and dependency-byte comparisons. [Public link checks](audit/2026-11-13/public-link-checks.json) cover current application releases and every train asset using unauthenticated requests. Historical media measurements were reused; no app rebuild or encode was needed.

## FFmpeg: exact identity is established; source delivery is not

Distributed FFmpeg SHA-256:

```text
430d60fbf419dab28daee9b679e7929a31ee9bae53f6e42e8ae26b725584290f
```

The hash match to Evermeet identifies the binary supplier. [Version-specific supplier metadata](https://evermeet.cx/ffmpeg/info/ffmpeg/8.0.1), preserved as [a dated snapshot](audit/2026-11-13/evermeet-8.0.1.json), supplies internal/external library version leads. The current landing page lists newer builds and must not substitute for that version-specific evidence. The supplier API is not a complete linked-component manifest: it lists some libraries without corresponding enabled switches and omits enabled libxml2. [Dependency leads](audit/2026-11-13/ffmpeg-dependency-leads.json) retain each supplier name/version/upstream URL and the configure switches, with per-entry unresolved license/build status. Inclusion, exact source, applicable license variant and required notices must be reconciled rather than inferred from the table.

The executable reports seven FFmpeg libraries (avutil, avcodec, avformat, avdevice, avfilter, swscale, swresample) and enabled external codec/filter/font libraries including x264, x265, libass, FreeType, fontconfig and others. `otool -L` exposes only system dynamic dependencies, not this static dependency inventory. Existing generic FFmpeg notices describe license options; they are not evidence that this GPL build is LGPL-only. See [FFmpeg's license explanation](https://ffmpeg.org/legal.html).

For this GPLv3-or-later executable, [GPLv3 sections 1 and 6](../Resources/licenses/COPYING.GPLv3) govern corresponding source and object-code delivery. For a network distribution, section 6(d) provides a route with equivalent source access and clear directions alongside the binary; the source may be on another server, with continued availability the distributor's responsibility. Corresponding source includes applicable modifications and scripts controlling compilation/installation, with the license's exclusions. A configure string and a generic upstream source archive cannot establish the complete source of the hashed build. No verified source bundle or qualifying delivery route was identified in this repo/releases, app ZIPs, supplier landing page, public directory or version API. This is a bounded evidence finding, not a claim that the supplier has no source anywhere.

[#194](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/194) requires exact source/patch/build materials and the actual external-library notice set, then a durable source link beside all affected downloads. Application MIT terms remain separate; this audit does not infer that packaging command-line tools automatically relicenses the application.

## DVRescue and fonts: preserve evidence, resolve the specific gaps

DVRescue SHA-256 is `396f26f02b6ad16fa406b890964df20ddc16424a0c99314892ec12859283ad4f`. The binary's MediaInfo version is direct evidence; source-package dependencies such as ZenLib are leads until mapped to the actual build. [#195](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/195) distinguishes required notices from optional build reproducibility. The [24.07 source archive](https://mediaarea.net/download/source/dvrescue/24.07/dvrescue_24.07.tar.gz) was downloaded (SHA-256 `61aa09e5579491016a9462547b52780fd596c812c141d1d4fa44947c427a7dbf`); its CLI configure file references MediaInfoLib/ZenLib and optional serial support. Its BSD notice uses 2019–2020, while the distributed notice uses 2019–2025. Preserve existing notices and reconcile the exact source notice with the actual build in #195. The public source archive is not asserted to reproduce this exact executable.

[Font-origin checks](audit/2026-11-13/font-origin-checks.json) record source download URLs, hashes, package contents and name-table versions. The public author statements checked during the original audit establish free use, including commercial use, but did not explicitly settle redistribution, font attachment in MKV, or all attribution conditions. Nicholas Kruse’s subsequent express written permission resolves the UAV redistribution concern as recorded above. [#196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196) now tracks only VCR OSD Mono’s outstanding redistribution/embedding evidence and attribution requirements. No OFL or public-domain dedication is inferred for these fonts.

Existing notices and binaries remain intact. Application archives and train media were not replaced. [Sample rights](LICENSING.md#train-footage-and-extracted-frames) remain distinct from software/font rights. No issue is resolved solely because this document now records it.

## Distribution remediation, November 13, 2026

The [DVRescue provenance receipt](audit/2026-11-13/dvrescue-provenance.json) identifies the original [official 24.07 DMG](https://mediaarea.net/download/binary/dvrescue/24.07/dvrescue_CLI_24.07_Mac.dmg), SHA-256 `6cda2ec5f951ebe5984da2fd5a1cbe574831bb2aa7d21de0da8218625aa12484`. Extracting its package without installing it yields exactly the application's `396f26f0…` executable. The newer 24.07.1 package differs and was not substituted.

The official [all-in-one 24.07 source bundle](https://mediaarea.net/download/binary/dvrescue/24.07/dvrescue_CLI_24.07_GNU_FromSource.tar.gz) contains MediaInfoLib **24.06**, matching the binary, plus ZenLib source 0.4.41 and bundled third-party notices. This resolves the misleading split-download 24.04 lead. Twelve original notice texts are now preserved in [DVRESCUE-NOTICES.txt](audit/2026-11-13/DVRESCUE-NOTICES.txt), with source-file hashes in the receipt, and appended to [the existing bundled NOTICE](../Resources/licenses/NOTICE.txt) so future Xcode builds include them. Original copyright texts remain intact, including both the publisher's 2019–2020 DVRescue notice and the preexisting 2019–2025 notice.

For every historical application release, additive `DVRESCUE-NOTICES-2026-11-13.txt`, `DVRESCUE-PROVENANCE-2026-11-13.json`, and `DVRESCUE-SUPPLEMENT-SHA256SUMS-2026-11-13.txt` accompany the unchanged ZIP. Their download links and hashes are verified after upload. These materials repair missing verified notices; they do not claim a complete dependency audit. Binary type information establishes MediaInfoLib, ZenLib, serial, TinyXML2 and DeckLink support. System zlib/libc++/frameworks are dynamically referenced and are not redistributed here. The source bundle omits `DeckLinkAPI.h`. The later non-font review below establishes the applicable Include-file distribution exception and resolves #195; an exact publisher build manifest/SDK revision remains optional provenance. Source-bundle versions are not asserted as independently proven binary versions.

FFmpeg: the supplier page, version-specific API, binary configuration and public source leads still do not provide exact patches, static-library source revisions and controlling build scripts for `430d60fb…`. No generic upstream tarball is presented as corresponding source. #194 needs the publisher's exact build/source materials and durable delivery alongside all affected downloads. Replacement cannot repair missing corresponding-source delivery for already-published historical bytes. This original-byte investigation did not replace or rebuild the binary; the independent preview 2 source delivery is verified below.

Fonts: author-linked packages and public use statements were rechecked during the original audit. The maintainer has since obtained Nicholas Kruse’s express written permission on November 13, 2026 for this project’s use and redistribution of both UAV fonts; the correspondence remains private. #196 now requires only authoritative VCR OSD Mono redistribution/embedding terms from Riciery Leal, including applicable attribution conditions. Existing train assets and font bytes remain unchanged.

Historical packaging: `1.0.4beta` contains Info.plist 1.0.3. Its release notes already disclose this. The new [release gate](../scripts/verify_release.py) and [GitHub workflow](../.github/workflows/release-integrity.yml) compare tag, source project version, external/embedded manifests, app Info.plist and archive/executable/tool hashes. [Packaging instructions](../DEV.md#release-integrity) describe the pre-publication check. Seven focused tests and the unchanged Preview 1 ZIP pass. The historical ZIP hash remains `72c89f3312820091b5f58ee9075cc72c59abbf768020c6299d074212584f9972`; no claim is made that its mismatch is only cosmetic.

## Non-font readiness review — November 13, 2026

The [verification receipt](audit/2026-11-13/nonfont-readiness-review.json)
supersedes the earlier SDK/build-mapping blocker without changing historical
receipts, notices, binaries or release assets.

### FFmpeg: preview 2 source delivery verified; historical #194 remains open

The published preview 2 app and `dependency-sources.tar` were downloaded again.
Their hashes, source lock, controlling build recipe and source archives pass the
release gate. The source asset is SHA-256
`2a5b2a51376098a1cb6b4599191b6f124e2c0db4208679cc296128d1785f910f`;
the bundled replacement FFmpeg is `98ed2a98711494da4282ca7ea5316dbe11f0e270f071efe8b0d74122681f7838`.
FFmpeg, x264, FreeType and HarfBuzz sources and license files are present, with
the actual configuration and bundled dependency notices. Keep these materials
available beside that download and deliver matching materials for future builds.
See [preview 2](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.2)
and its [build recipe](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/1735e101881f5fe725c2d1ed539bc3c22bbf8e52/scripts/dependencies/README.md).

For the different historical `430d60fb…` binary, the publisher's
[version-specific API](https://evermeet.cx/ffmpeg/info/ffmpeg/8.0.1),
[download directory](https://evermeet.cx/pub/ffmpeg/) and
[build page](https://evermeet.cx/ffmpeg/) were rechecked. They identify binary
packages and dependency-version leads, but no complete corresponding-source,
patch and controlling-script delivery tied to those bytes was found. The API's
48 external-library entries are not an exact linked-library notice inventory;
the earlier enabled-library discrepancies remain. #194 stays open for the
historical binary's corresponding source and actual dependency notices, followed
by equivalent source access beside the eight affected downloads under
[GPLv3 sections 1 and 6(d)](../Resources/licenses/COPYING.GPLv3). Identical compiler
output is not required; the source must actually correspond to the executable.
This is a source-delivery obligation, not a requirement to promote 1.0.7 or to
rebuild either working binary. No supplier source or permission is invented.

### DVRescue: #195 distribution requirements satisfied

The official [24.07 Mac package](https://mediaarea.net/download/binary/dvrescue/24.07/dvrescue_CLI_24.07_Mac.dmg)
contains exactly the historical executable; the official
[all-in-one source](https://mediaarea.net/download/binary/dvrescue/24.07/dvrescue_CLI_24.07_GNU_FromSource.tar.gz)
contains MediaInfoLib 24.06 and ZenLib 0.4.41. The already published
[12-notice supplement](audit/2026-11-13/DVRESCUE-NOTICES.txt) remains available
beside all eight historical app downloads; its public readback and all existing
asset identities were rechecked. [BSD binary conditions](https://mediaarea.net/DVRescue/License)
require accompanying notices, not a corresponding-source offer or an exact
compiler/SDK manifest.

Blackmagic's official [SDK agreement](https://downloads.blackmagicdesign.com/EULA/DeckLink/DeckLink-End-User-License-Agreement.pdf),
section 0.1, excludes clauses 1, 4.3, 4.4, 5, 7 and 8 for files in `Mac/Include`,
`Win/Include` and `Linux/Include`. The remaining SDK files remain subject to the
full agreement; this is not permission to redistribute the complete SDK.
Blackmagic's [integration instructions](https://sdk-doc.blackmagicdesign.com/decklink-sdk/decklinkapi.html)
identify `DeckLinkAPI.h` and `DeckLinkAPIDispatch.cpp` as macOS integration files.
Their Blackmagic-authored [file-level grants](audit/2026-11-13/DECKLINK-API-NOTICES.txt)
permit distribution and expressly exempt machine-executable object code from
the condition to reproduce the copyright and permission statement. The inspected
SDK 11.6 and 12.0 copies have this exception; these are comparison sources, not
asserted inputs to the historical DVRescue build.

DVRescue 24.07's `configure.ac` selects the SDK include directory and checks
`DeckLinkAPI.h`; `DecklinkWrapper.cpp` includes `DeckLinkAPIDispatch.cpp`.
That dispatch code loads `/Library/Frameworks/DeckLinkAPI.framework` and the
Blackmagic streaming bundle at runtime. The executable contains matching loader
paths and entry-point names. Reinspection of all eight hashed app ZIPs finds no
DeckLink SDK files, Blackmagic runtime/framework, drivers or sample applications.
A runtime path string is not a bundled driver. Together, the source, package
inventory and file grants support distribution of the compiled integration
without an additional DeckLink notice or SDK source offer. The file-level
notices are preserved here voluntarily as evidence; no existing notice is removed.

The exact SDK revision, compiler setup and every static component revision remain
unrecovered historical provenance. Shared API entry points do not uniquely identify
an SDK version. They are useful for reproducibility, but are not unsatisfied
binary-distribution requirements in the inspected licenses. #195 is resolved on
that basis, without claiming a reproduced historical build or certifying unrelated
SDK components. Preview 2 independently disables DeckLink and uses no SDK.

### H.264: technical correction verified; #197 is a stable-promotion gate

Maintenance runtime `2802355`, included in preview 2, corrects deinterlacing-off
H.264 field signaling. Three focused regressions were rerun successfully: MP4
BFF/deinterlacing modes, decoded raw H.264 extracted from MKV, and TFF/progressive
input preservation. Existing [real-footage CLI results](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/1735e101881f5fe725c2d1ed539bc3c22bbf8e52/docs/audit/2026-11-13/dependency-builds/train-output-verification.json)
show 238 BFF H.264 frames in MP4/MKV, 476 progressive frames at 60p, retained
subtitle coverage and unchanged original footage. These are automated results;
no new human playback, GUI or hardware acceptance is claimed.

#197 remains open only for moving-picture/player acceptance before stable 1.0.7
promotion. It does not block ordinary maintenance commits, experimental
prereleases, documentation or unrelated licensing work. Record player/version,
representative footage, field cadence, subtitle rendering, motion and A/V sync
results using the [community guide](COMMUNITY_VALIDATION.md). GUI queues/Stop,
broader camera coverage and native Apple Silicon/Rosetta acceptance also remain
separate release gates. Mixed field orders within one source are not certified.
Main remains the stable 1.0.6 application; no maintenance runtime is merged.
