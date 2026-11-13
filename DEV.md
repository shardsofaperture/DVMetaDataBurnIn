# Development Notes

- Libraries in `Resources/scripts/lib` must be side-effect free; `env.zsh` must be sourced first in the entrypoint.

## Release integrity

Before publishing any new application package, create external and embedded `BUILD-MANIFEST.json` files identifying the exact full source commit, release tag and application version. The external manifest also records the archive name/size/SHA-256, executable hash and bundled-tool hashes; the unchanged Preview 1 manifest is a concrete example. Keep the tag pointing at that source commit. Include all bundled notices, including the DVRescue supplement appended to `Resources/licenses/NOTICE.txt`.

Run against the exact source checkout and final ZIP:

```sh
python3 scripts/verify_release.py --tag v1.0.7-maintenance.2 --manifest /path/to/BUILD-MANIFEST.json --archive /path/to/application.zip --project DVMetaDataBurnIn.xcodeproj/project.pbxproj
python3 -m unittest discover -s scripts/tests -v
```

Use the intended tag and actual paths. This example is not a new release announcement. Never upload after a failed check. The `Application release integrity` workflow repeats validation on newly published application releases, or manually for a specified tag, and compares the tag's source project to the archive. Example-data releases are excluded. Historical packages without manifests are not retrospectively certified. The existing 1.0.4beta ZIP contains version 1.0.3; its tag and bytes are preserved, with actual runtime provenance unknown. Integrity checks do not establish licensing compliance, signing, GUI or player acceptance.
