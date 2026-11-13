# Licenses and source materials

The application is **MIT licensed, Copyright (c) 2025 Zach Zarzycki**.
See [LICENSE](../LICENSE) and [APP_LICENSE.txt](../Resources/licenses/APP_LICENSE.txt).
Bundled components retain their own terms in [NOTICE.txt](../Resources/licenses/NOTICE.txt).
These licensing statements apply across the repository branches; component versions
and source downloads below identify the distribution to which each applies.

## Component licenses

[Main](https://github.com/shardsofaperture/DVMetaDataBurnIn/tree/main) remains stable
1.0.6. [Maintenance](https://github.com/shardsofaperture/DVMetaDataBurnIn/tree/maintenance/1.0.7)
remains experimental 1.0.7.

| Component | License and distribution |
| --- | --- |
| Application | MIT, with original authorship preserved. |
| FFmpeg 8.0.1-tessus in stable and releases through preview 1 | GPL-3.0-or-later. The full [GPLv3 text](../Resources/licenses/COPYING.GPLv3) is copied from [GNU](https://www.gnu.org/licenses/gpl-3.0.txt). Source delivery is described below. |
| FFmpeg 8.0.1-dvmetadata1 in preview 2/current maintenance | GPL-3.0-or-later, with x264 (GPL-2.0-or-later), FreeType (GPL alternative selected) and HarfBuzz (permissive notices). Sources and notices accompany preview 2. |
| DVRescue 24.07 | BSD-3-Clause. Stable uses the official binary; its dependency notices accompany the historical downloads as `DVRESCUE-NOTICES-2026-11-13.txt`. Current maintenance uses the source-built capture-disabled variant with MediaInfoLib 24.06 (BSD-2-Clause) and ZenLib 0.4.41 (zlib); no DeckLink SDK is used in that build. |
| UAV OSD Mono, UAV OSD Sans Mono, VCR OSD Mono | Original unmodified fonts in stable and current maintenance, with permissions and attribution below. |

## Corresponding source and notices

The [preview 2 release](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.2)
provides `dependency-sources.tar`: FFmpeg and dependency sources, DVRescue sources,
patches, build scripts and license texts for its source-built tools. See the
[build instructions](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/scripts/dependencies/README.md).
Keep matching source and notices available alongside each binary distribution.

For the different historical Evermeet FFmpeg binary, the outstanding delivery
work is its corresponding FFmpeg/dependency sources, applicable patches and
build/install scripts, plus the required dependency notices. These materials
must be made available alongside the affected downloads under an applicable
[GPLv3 section 6 route](https://www.gnu.org/licenses/gpl-3.0.html#section6).
Source delivery does not require byte-identical rebuilding. A license copy alone
is not corresponding source. This work remains tracked in
[#194](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/194).

## Bundled fonts

UAV OSD Mono and UAV OSD Sans Mono are by Nicholas Kruse. He granted
DVMetaDataBurnIn express written permission to use and redistribute both fonts
on November 13, 2026. The correspondence is privately retained by the maintainer.
This permission applies to this project; it is not an OFL license, a public-domain
dedication, or blanket permission for unrelated projects. Copyright attribution
and source links are retained in the notices.

VCR OSD Mono is by Riciery Leal (MrManet). In his
[February 24, 2017 comment](https://www.dafont.com/font-comment.php?file=vcr_osd_mono),
the author states: “Yes, the font is free even for commercial purposes.”
[DaFont](https://www.dafont.com/vcr-osd-mono.font) lists the font as 100% Free.
The maintainer retains it with the original attribution and source reference.
Font licensing issue [#196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196)
is closed. The maintainer will incorporate any further author clarification.

## Published preview 2 fonts

The unchanged preview 2 archive contains VT323, Share Tech Mono and IBM Plex Mono
under SIL OFL 1.1, with their full notices. Current maintenance restores the
original UAV/VCR fonts; build from the branch for that correction. System/custom
fonts selected by users retain their own terms.

## Train footage and extracted frames

Attribution: **Zach Zarzycki (ThePolish / shardsofaperture)**. The owner authorized publication of the identified train demonstration and directly related outputs. No existing explicit media license was found alongside the supplied files. No new MIT or Creative Commons license is applied to the videos or extracted frames. Public availability is not a new grant of reuse rights; contact the owner for permissions beyond the published demonstration.
