# Default DMG and Applications Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make macOS release packaging produce a drag-to-Applications DMG by default while preserving explicit ZIP packaging and documenting both paths in English, Japanese, and Simplified Chinese.

**Architecture:** Keep `scripts/package-macos-release.sh` as the sole packaging orchestrator. Change its default format to DMG and create `Applications -> /Applications` only inside the DMG artifact branch, leaving ZIP staging and notarization behavior unchanged.

**Tech Stack:** Bash, macOS `hdiutil`, Python `unittest`, Markdown

---

### Task 1: Specify the default DMG behavior with tests

**Files:**
- Modify: `tests/test_package_macos_release.py`

- [ ] **Step 1: Add a failing default-DMG test**

Add a test that invokes `_run_package()` without `--format`, supplies
`NOTARYTOOL_PROFILE=develop`, and asserts:

```python
artifact = str(ROOT_DIR / "dist/M3U8Downloader-v9.9.9-macOS.dmg")
self.assertEqual(run["result"].returncode, 0, run["result"].stderr)
self.assertIn(f"notarytool submit {artifact}", run["xcrun"])
self.assertIn(f"stapler staple {artifact}", run["xcrun"])
self.assertIn("applications=/Applications", run["hdiutil"])
```

Update the fake `hdiutil` executable to parse the value after `-srcfolder` and
append the symlink target to its log:

```bash
source_folder=
while [[ $# -gt 0 ]]; do
  case "$1" in
    -srcfolder)
      source_folder="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'applications=%s\n' "$(readlink "$source_folder/Applications" 2>/dev/null || true)" >> "$HDIUTIL_LOG"
```

- [ ] **Step 2: Make existing ZIP expectations explicit**

Pass `arguments=["--format", "zip"]` in tests whose assertions require ZIP
creation, including the signed ZIP notarization test and the notarization
failure test. Add an assertion that explicit ZIP packaging does not invoke
`hdiutil`.

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```bash
./.venv/bin/python3 -m unittest tests.test_package_macos_release.PackageMacOSReleaseTests.test_default_package_is_dmg_with_applications_link -v
```

Expected: FAIL because the default artifact is still ZIP.

### Task 2: Implement default DMG packaging

**Files:**
- Modify: `scripts/package-macos-release.sh`
- Test: `tests/test_package_macos_release.py`

- [ ] **Step 1: Change the default format**

Change:

```bash
FORMAT="zip"
```

to:

```bash
FORMAT="dmg"
```

- [ ] **Step 2: Add the Applications link only for DMG creation**

In the `dmg)` branch of `create_artifact`, immediately before `hdiutil create`,
add:

```bash
ln -sfn /Applications "$STAGING_DIR/Applications"
```

Do not create the link during common staging or ZIP creation.

- [ ] **Step 3: Run packaging tests and verify GREEN**

Run:

```bash
./.venv/bin/python3 -m unittest tests.test_package_macos_release -v
```

Expected: all packaging tests pass.

### Task 3: Update all release documentation

**Files:**
- Modify: `README.md`
- Modify: `README.ja.md`
- Modify: `README.zh-CN.md`

- [ ] **Step 1: Update the English release section**

Describe the no-argument command as producing a signed and notarized DMG, show
the `.dmg` artifact name, mention the root-level Applications drop link, and
show `--format zip` as the explicit ZIP command.

- [ ] **Step 2: Add equivalent Japanese release instructions**

Add a localized `### macOS リリースのパッケージ化` section after the Xcode build
instructions. Document `NOTARYTOOL_PROFILE`, default DMG output, the
Applications drag target, and explicit `--format zip`.

- [ ] **Step 3: Add equivalent Simplified Chinese release instructions**

Add a localized `### 打包 macOS 发布版本` section after the Xcode build
instructions. Document `NOTARYTOOL_PROFILE`, default DMG output, the
Applications drag target, and explicit `--format zip`.

### Task 4: Verify the complete change

**Files:**
- Verify: `scripts/package-macos-release.sh`
- Verify: `tests/test_package_macos_release.py`
- Verify: `README.md`
- Verify: `README.ja.md`
- Verify: `README.zh-CN.md`

- [ ] **Step 1: Check shell syntax**

Run:

```bash
bash -n scripts/package-macos-release.sh
```

Expected: exit code 0 with no output.

- [ ] **Step 2: Run the full test suite**

Run:

```bash
./.venv/bin/python3 -m unittest discover -s tests -v
```

Expected: all tests pass.

- [ ] **Step 3: Check the diff**

Run:

```bash
git diff --check
git diff -- scripts/package-macos-release.sh tests/test_package_macos_release.py README.md README.ja.md README.zh-CN.md
```

Expected: no whitespace errors; the diff contains only the approved packaging,
test, and documentation changes.
