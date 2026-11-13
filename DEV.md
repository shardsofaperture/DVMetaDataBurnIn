# Development Notes

- Libraries in `Resources/scripts/lib` must be side-effect free; `env.zsh` must be sourced first in the entrypoint.

## Build

Use full Xcode and the existing project/scheme; Command Line Tools alone cannot
build the app. The project minimum is macOS 12. Verified native builds use Intel
macOS 14 and Xcode 15.4. Select Xcode for this process only:

```sh
DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" xcodebuild \
  -project DVMetaDataBurnIn.xcodeproj -scheme DVMetaDataBurnIn \
  -configuration Release -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The application and processing binaries are already in the checkout; no system
package installation or dependency compilation is needed for this build.
Bundled FFmpeg/DVRescue are Intel-only. Inspect the built app's
`Contents/Resources` for matching tools, fonts, notices and scripts. An unsigned
build does not establish distribution signing, GUI or Apple Silicon acceptance.

Main retains 1.0.6 runtime. The [maintenance development guide](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/DEV.md)
contains the experimental architecture, regression suite and pinned dependency
build instructions. Those tests and replacement tools are not present on main.
Historical tessus source delivery remains [separately tracked](docs/HISTORICAL_FFMPEG.md).

## Release integrity

Before publishing any new application package, create external and embedded `BUILD-MANIFEST.json` files identifying the exact full source commit, release tag and application version. The external manifest also records the archive name/size/SHA-256, executable hash and bundled-tool hashes; the unchanged Preview 1 manifest is a concrete example. Keep the tag pointing at that source commit. Include all bundled notices, including the DVRescue supplement appended to `Resources/licenses/NOTICE.txt`.

Run against the exact source checkout and final ZIP:

```sh
python3 scripts/verify_release.py --tag v1.0.7-maintenance.2 --manifest /path/to/BUILD-MANIFEST.json --archive /path/to/application.zip --project /path/to/tagged-source/DVMetaDataBurnIn.xcodeproj/project.pbxproj --sources /path/to/dependency-sources.tar
python3 -m unittest discover -s scripts/tests -v
```

Use the intended tag and its source checkout, not main’s 1.0.6 project when checking a 1.0.7 package. For source-built packages, the manifest must include `dependency_sources` and `bundled_resources_sha256`; the gate verifies the source delivery, locked archives, build recipe, fonts and notices. The Preview 1 manifest predates source delivery. Never upload after a failed check. The `Application release integrity` workflow repeats validation on newly published application releases, or manually for a specified tag, and compares the tag's source project to the archive. Example-data releases are excluded. Historical packages without manifests are not retrospectively certified. The existing 1.0.4beta ZIP contains version 1.0.3; its tag and bytes are preserved, with actual runtime provenance unknown. Integrity checks do not establish licensing compliance, signing, GUI or player acceptance.
