# Historical FFmpeg source delivery

Reviewed November 13, 2026. [Issue #194](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/194)
remains open. This report does not certify the historical downloads as compliant.

## Binary identity and investigation

The eight application releases from `alpha` through `v1.0.7-maintenance.1`
contain FFmpeg 8.0.1-tessus, SHA-256
`430d60fbf419dab28daee9b679e7929a31ee9bae53f6e42e8ae26b725584290f`.
The existing [release inventory](audit/2026-11-13/release-inventory.json)
records each package. A fresh download of the publisher's
[8.0.1 ZIP](https://evermeet.cx/ffmpeg/ffmpeg-8.0.1.zip) matched that executable;
the ZIP contains only `ffmpeg`, with no source, notices or scripts.

Checked channels and results:

- The [publisher page](https://evermeet.cx/ffmpeg/) and
  [version-specific API](https://evermeet.cx/ffmpeg/info/ffmpeg/8.0.1) supply binary
  downloads, library/version leads and upstream project links. They do not
  supply a corresponding-source bundle or supplier build/patch scripts. Use the
  8.0.1 API rather than the page's changing latest-version library list.
- The [official distribution directory](https://evermeet.cx/pub/ffmpeg/) redirects
  to the publisher's download host and lists binaries/signatures. The public
  `pub/scripts`, `pub/patches`, `pub/repo` and `pub/macosx/ff` directories did not
  reveal the required FFmpeg materials. Guessed source paths returned 403/404;
  that does not prove the files do not exist privately.
- The [archived November 16, 2025 publisher page](https://web.archive.org/web/20251116013333/https://evermeet.cx/ffmpeg/)
  was retrieved and inspected. Its upstream-library links do not establish the
  supplier's patches or build procedure. A bounded archive-index search returned
  500 entries without identifying the materials; narrower searches timed out or
  returned HTTP 503. Archive coverage is incomplete, not evidence of absence.
- A GitHub search for `user:tessus ffmpeg` found no public repository. Other
  publishers' build recipes are not evidence for this executable.

[Retrieval receipts](audit/2026-11-13/historical-ffmpeg-investigation.json)
record URLs, response status, sizes and hashes. Existing
[binary readouts](audit/2026-11-13/binary-readouts.json) and
[dependency leads](audit/2026-11-13/ffmpeg-dependency-leads.json) are retained.
No complete corresponding-source delivery was obtained through these channels.
No supplier response is claimed.

## Required materials versus reproducibility extras

Under [GPLv3 sections 1 and 6(d)](https://www.gnu.org/licenses/gpl-3.0.html),
network binary distribution requires equivalent access to corresponding source,
including needed non-system components and scripts controlling compilation and
installation. Preserve applicable copyright/license notices and modifications.
Clear directions beside the binary may point to an equivalent third-party server,
but the distributor remains responsible for availability. A generic upstream link
or license text alone is insufficient. System libraries, ordinary general-purpose
tools and automatically regenerable files have the section 1 exclusions.

A byte-identical executable, the supplier's complete computer image, original
build-directory paths and original signing credentials are not prerequisites to
source delivery. Version/commit information must establish the source relationship;
hashes and build receipts help verify it. If the supplier confirms unmodified
upstream inputs and provides the actual scripts/configuration, preserve those
inputs with that evidence; do not invent a patch set or reject it merely because
a fresh executable differs in timestamps or signing.

## Least disruptive next step

Request the materials from the publisher's listed contact, `ffmpeg@evermeet.cx`.
The following is an **unsent request checklist**, not evidence of correspondence:

- Identify `8.0.1-tessus` and the full executable hash above.
- Request the corresponding FFmpeg tree, each included non-system dependency's
  release/revision and source, all applied patches (or confirmation of none),
  and scripts/configuration needed to build and install this binary.
- Request applicable dependency copyright/license notices and any archived
  source-distribution location. Explain that byte-identical reproduction is not
  required; the source must correspond to the distributed executable.

If obtained, verify the relationship against the binary/API, archive the inputs
and required notices with hashes, and publish them with clear links on all eight
affected releases. Re-download and verify the delivery before closing #194.

If unavailable, the practical fallback is an explicitly labeled replacement
package using a verified source-built executable and its matching source/notices.
It must first pass the **legacy application's** workflows; Preview 2 tests alone
do not prove compatibility with 1.0.6 or older scripts/custom FFmpeg options.
Retain release records/tags and disclose the changed tool and package hashes.
Owner approval is required before removing or replacing any historical asset.
Adding an alternative while leaving the unsourced binary downloadable does not
resolve that binary's distribution obligation. Removing/replacing downloads also
does not retroactively satisfy obligations to earlier recipients; keep the source
request and remediation record open until the actual requirements are met.

[Preview 2](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.2)
already provides matching sources for its different FFmpeg 8.0.1-dvmetadata1.
Those sources are not substituted for the historical binary. No legacy asset,
tag or processing behavior was changed by this review.
