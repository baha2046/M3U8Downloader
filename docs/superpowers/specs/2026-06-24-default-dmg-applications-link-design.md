# Default DMG and Applications Link Design

## Goal

Make `scripts/package-macos-release.sh` create a DMG by default and include the
standard `Applications` drop target so users can drag `M3U8Downloader.app` into
their Applications folder. Keep ZIP packaging available through
`--format zip`.

## Packaging Behavior

The script's default `FORMAT` changes from `zip` to `dmg`. Passing
`--format zip` continues to produce the existing ZIP artifact, while passing
`--format dmg` remains supported and is equivalent to using no format option.

The staging directory continues to contain the signed
`M3U8Downloader.app`. When creating a DMG, the script also creates an
`Applications` symbolic link in the staging directory whose target is the
absolute `/Applications` directory. `hdiutil create` then packages that staging
directory, placing the app and link together at the root of the mounted disk
image.

ZIP creation must not include the `Applications` link. The link is created only
inside the DMG branch immediately before `hdiutil` runs, avoiding changes to
the existing ZIP contents and ZIP notarization rebuild flow.

## Signing and Notarization

Code signing, notarization submission, stapling, and validation behavior remain
unchanged. Default invocations now follow the existing DMG notarization path:
submit the DMG, then staple and validate the DMG itself. Explicit ZIP releases
continue to staple the staged app and rebuild the ZIP.

## Tests

`tests/test_package_macos_release.py` will verify:

- An invocation without `--format` creates and notarizes a `.dmg`.
- The directory passed to `hdiutil create` contains
  `Applications -> /Applications`.
- An explicit `--format zip` still creates the ZIP, follows its existing
  notarization/stapling flow, and does not package the Applications link.

The command harness will record enough DMG source information before the
temporary staging state changes so the test can assert the symlink target.

## Documentation

The README release section will describe DMG as the default artifact and show
that it contains the drag-to-Applications link. ZIP instructions will use an
explicit `--format zip` command.
