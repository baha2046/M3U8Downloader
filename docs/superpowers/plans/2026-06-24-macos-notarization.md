# macOS Release Notarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add synchronous Apple notarization, stapling, validation, tests, and release documentation to the macOS packaging flow.

**Architecture:** Keep `scripts/package-macos-release.sh` as the release orchestrator. Package the signed app first, submit that ZIP or DMG with a configurable `notarytool` keychain profile, then staple the app for ZIP releases or the disk image for DMG releases; rebuild ZIP files after stapling so the distributed app contains its ticket.

**Tech Stack:** Bash, Apple `codesign`/`notarytool`/`stapler`, Python `unittest`

---

### Task 1: Establish the test harness and ZIP notarization behavior

**Files:**
- Modify: `tests/test_package_macos_release.py`

- [ ] **Step 1: Refactor command setup into a reusable fixture**

Create a `_run_package` helper that builds a temporary fake command directory
for `git`, `security`, `xcodebuild`, `codesign`, `ditto`, `hdiutil`, `xattr`,
and `xcrun`. It must return the completed process and command log paths while
accepting format, environment overrides, and a simulated notary submission
failure.

- [ ] **Step 2: Add a failing ZIP notarization test**

Add a test that runs with `NOTARYTOOL_PROFILE=develop` and asserts:

```python
self.assertEqual(result.returncode, 0, result.stderr)
self.assertIn(
    "notarytool submit "
    + str(ROOT_DIR / "dist/M3U8Downloader-v9.9.9-macOS.zip")
    + " --keychain-profile develop --wait",
    xcrun_commands,
)
self.assertIn("stapler staple", xcrun_commands)
self.assertIn("stapler validate", xcrun_commands)
self.assertEqual(ditto_commands.count("-c -k"), 2)
```

- [ ] **Step 3: Run the ZIP test and verify it fails**

Run:

```bash
./.venv/bin/python3 -m unittest tests.test_package_macos_release.PackageMacOSReleaseTests.test_signed_zip_is_notarized_and_rebuilt_after_stapling -v
```

Expected: `FAIL` because the script does not invoke `xcrun notarytool` or
`xcrun stapler`.

### Task 2: Implement ZIP notarization

**Files:**
- Modify: `scripts/package-macos-release.sh`

- [ ] **Step 1: Document notarization environment variables in usage**

Add:

```text
NOTARYTOOL_PROFILE   Keychain profile created by `xcrun notarytool store-credentials`.
SKIP_NOTARIZATION    Set to 1 for a signed local package without notarization.
```

- [ ] **Step 2: Add reusable artifact and notarization helpers**

Add a `create_artifact` function containing the existing ZIP/DMG packaging
commands, and a `submit_for_notarization` function that runs:

```bash
xcrun notarytool submit \
  "$ARTIFACT_PATH" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait
```

Wrap submission, stapling, and validation commands in `if ! ...; then` blocks
that print contextual `error:` messages and exit nonzero.

- [ ] **Step 3: Require a profile for signed release notarization**

When signing is enabled and `SKIP_NOTARIZATION` is not `1`, fail if
`NOTARYTOOL_PROFILE` is empty. The error must mention both
`xcrun notarytool store-credentials` and `SKIP_NOTARIZATION=1`.

- [ ] **Step 4: Notarize and staple ZIP releases**

After the initial `create_artifact`, submit the ZIP, staple and validate
`$STAGED_APP`, then call `create_artifact` again.

- [ ] **Step 5: Run the ZIP test and verify it passes**

Run the focused command from Task 1. Expected: `OK`.

### Task 3: Add DMG and failure-path coverage

**Files:**
- Modify: `tests/test_package_macos_release.py`

- [ ] **Step 1: Add a failing DMG test**

Run `--format dmg`, then assert the submitted, stapled, and validated path ends
in `.dmg`, and that `hdiutil create` ran once.

- [ ] **Step 2: Add a failing submission test**

Make fake `xcrun notarytool submit` print an Apple-style rejection diagnostic
and exit nonzero. Assert the package script:

```python
self.assertNotEqual(result.returncode, 0)
self.assertIn("error: Apple notarization failed", result.stderr)
self.assertNotIn("stapler staple", xcrun_commands)
self.assertNotIn("Release artifact:", result.stdout)
```

- [ ] **Step 3: Add missing-profile and skip-mode tests**

Cover:

- Missing `NOTARYTOOL_PROFILE` fails clearly for a normal signed package.
- `SKIP_NOTARIZATION=1` signs and packages without any `xcrun` calls.
- `SKIP_CODESIGN=1` packages without `codesign` or `xcrun` calls.

- [ ] **Step 4: Run the packaging test module and verify new tests fail**

Run:

```bash
./.venv/bin/python3 -m unittest tests.test_package_macos_release -v
```

Expected: DMG and error-handling assertions fail until the script implements
the remaining branches.

### Task 4: Complete DMG notarization and error handling

**Files:**
- Modify: `scripts/package-macos-release.sh`

- [ ] **Step 1: Staple the correct target by format**

For ZIP, staple/validate `$STAGED_APP` and rebuild the archive. For DMG,
staple/validate `$ARTIFACT_PATH` without rebuilding it.

- [ ] **Step 2: Preserve diagnostics and suppress success on failure**

Let `notarytool` output flow to the caller. Print the release artifact line
only after every enabled notarization command succeeds.

- [ ] **Step 3: Run packaging tests**

Run:

```bash
./.venv/bin/python3 -m unittest tests.test_package_macos_release -v
```

Expected: all packaging tests pass.

### Task 5: Update release documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document credential setup**

Add:

```bash
xcrun notarytool store-credentials develop
```

Explain that the command stores Apple credentials in Keychain.

- [ ] **Step 2: Update release examples**

Use:

```bash
NOTARYTOOL_PROFILE=develop \
  VERSION=1.0.0 \
  ./scripts/package-macos-release.sh --format dmg
```

State that the script signs, submits with `--wait`, staples, validates, and
only then reports the final artifact.

- [ ] **Step 3: Document local opt-outs**

Explain `SKIP_NOTARIZATION=1` for signed local packages and
`SKIP_CODESIGN=1` for unsigned local packages.

### Task 6: Verify the complete change

**Files:**
- Verify: `scripts/package-macos-release.sh`
- Verify: `tests/test_package_macos_release.py`
- Verify: `README.md`

- [ ] **Step 1: Check Bash syntax**

Run:

```bash
bash -n scripts/package-macos-release.sh
```

Expected: exit status 0.

- [ ] **Step 2: Run the full Python suite**

Run:

```bash
./.venv/bin/python3 -m unittest discover -s tests -v
```

Expected: all tests pass.

- [ ] **Step 3: Check the patch**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only the planned script, test, README, and
plan changes are present.
