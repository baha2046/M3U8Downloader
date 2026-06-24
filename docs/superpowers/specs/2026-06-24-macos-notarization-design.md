# macOS Release Notarization Design

## Goal

Extend `scripts/package-macos-release.sh` so Developer ID release packages are
submitted to Apple notarization, waited on synchronously, stapled, validated,
and distributed with the stapled ticket.

## Configuration

The release environment accepts:

- `NOTARYTOOL_PROFILE`: the keychain profile name created with
  `xcrun notarytool store-credentials`.
- `SKIP_NOTARIZATION=1`: build a signed local package without submitting it to
  Apple.
- Existing `SKIP_CODESIGN=1`: build an unsigned local package and implicitly
  skip notarization because Apple notarization requires Developer ID signing.

Normal signed release packaging requires `NOTARYTOOL_PROFILE`. Missing
credentials fail before submission with an actionable message explaining how
to set the profile or explicitly skip notarization.

## Packaging Flow

The script keeps the existing build, staging, Developer ID signing, and
signature verification steps.

For ZIP releases:

1. Create the ZIP from the signed staged app.
2. Submit the ZIP with
   `xcrun notarytool submit "$ARTIFACT_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait`.
3. If Apple accepts the submission, staple and validate the staged app with
   `xcrun stapler staple` and `xcrun stapler validate`.
4. Recreate the ZIP from the stapled staged app so the distributed archive
   contains the ticket.

For DMG releases:

1. Create the DMG containing the signed staged app.
2. Submit the DMG with the same synchronous `notarytool` command.
3. If Apple accepts the submission, staple and validate the DMG itself.

The script prints the final artifact path only after all enabled signing and
notarization work succeeds.

## Error Handling

Every notarization stage has a clear contextual error:

- Missing `NOTARYTOOL_PROFILE` explains credential setup and
  `SKIP_NOTARIZATION=1`.
- A nonzero `notarytool submit --wait` result reports that Apple notarization
  failed and preserves the command's output for diagnostics.
- Failed stapling or stapler validation identifies the affected app or DMG.

Because the script uses `set -euo pipefail`, failed commands terminate the
release. Explicit conditionals provide the release-specific messages before
exiting.

## Tests

`tests/test_package_macos_release.py` will extend its fake macOS command harness
to cover:

- A signed ZIP is submitted with the configured keychain profile, the staged
  app is stapled and validated, and the ZIP is rebuilt afterward.
- A signed DMG is submitted, stapled, and validated as a DMG.
- A notarization submission failure exits nonzero, reports a clear error, and
  does not staple or print a successful artifact message.
- Signed release packaging without `NOTARYTOOL_PROFILE` fails clearly.
- `SKIP_NOTARIZATION=1` retains signed local packaging without invoking
  `notarytool` or `stapler`.
- `SKIP_CODESIGN=1` creates an unsigned local package without invoking signing
  or notarization.

Python tests are run with `./.venv/bin/python3` as required by `AGENTS.md`.

## Documentation

The README release section will document:

- Creating a keychain profile with `xcrun notarytool store-credentials`.
- Setting `NOTARYTOOL_PROFILE` for normal signed and notarized releases.
- The synchronous submit, staple, and validation behavior.
- `SKIP_NOTARIZATION=1` for signed local packages.
- `SKIP_CODESIGN=1` for unsigned local packages.
