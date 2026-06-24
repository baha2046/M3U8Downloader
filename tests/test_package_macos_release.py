import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]


class PackageMacOSReleaseTests(unittest.TestCase):
    def test_signed_zip_is_notarized_and_rebuilt_after_stapling(self):
        run = self._run_package(
            arguments=["--format", "zip"],
            environment={"NOTARYTOOL_PROFILE": "develop"},
        )

        self.assertEqual(run["result"].returncode, 0, run["result"].stderr)
        self.assertIn(
            "notarytool submit "
            + str(ROOT_DIR / "dist/M3U8Downloader-v9.9.9-macOS.zip")
            + " --keychain-profile develop --wait",
            run["xcrun"],
        )
        self.assertIn(
            "stapler staple "
            + str(
                ROOT_DIR
                / ".build/release/M3U8Downloader-v9.9.9-macOS/"
                "M3U8Downloader.app"
            ),
            run["xcrun"],
        )
        self.assertIn("stapler validate", run["xcrun"])
        self.assertEqual(run["ditto"].count("-c -k"), 2)
        self.assertEqual(run["hdiutil"], "")

    def test_default_package_is_dmg_with_applications_link(self):
        run = self._run_package(
            environment={"NOTARYTOOL_PROFILE": "develop"},
        )

        artifact = str(
            ROOT_DIR / "dist/M3U8Downloader-v9.9.9-macOS.dmg"
        )
        self.assertEqual(run["result"].returncode, 0, run["result"].stderr)
        self.assertIn(f"notarytool submit {artifact}", run["xcrun"])
        self.assertIn(f"stapler staple {artifact}", run["xcrun"])
        self.assertIn("applications=/Applications", run["hdiutil"])

    def test_package_auto_signs_with_developer_id_application_identity(self):
        run = self._run_package(
            environment={"SKIP_NOTARIZATION": "1"},
        )

        self.assertEqual(run["result"].returncode, 0, run["result"].stderr)
        self.assertIn(
            "--sign Developer ID Application: Eric Chan (TEAMID)",
            run["codesign"],
        )
        self.assertIn("--noextattr", run["ditto"])
        self.assertIn("--noqtn", run["ditto"])

    def test_signed_dmg_is_notarized_stapled_and_validated(self):
        run = self._run_package(
            arguments=["--format", "dmg"],
            environment={"NOTARYTOOL_PROFILE": "develop"},
        )

        artifact = str(
            ROOT_DIR / "dist/M3U8Downloader-v9.9.9-macOS.dmg"
        )
        self.assertEqual(run["result"].returncode, 0, run["result"].stderr)
        self.assertIn(
            f"notarytool submit {artifact} "
            "--keychain-profile develop --wait",
            run["xcrun"],
        )
        self.assertIn(f"stapler staple {artifact}", run["xcrun"])
        self.assertIn(f"stapler validate {artifact}", run["xcrun"])
        self.assertEqual(run["hdiutil"].count("create "), 1)

    def test_notarization_failure_stops_before_stapling_or_success(self):
        run = self._run_package(
            arguments=["--format", "zip"],
            environment={"NOTARYTOOL_PROFILE": "develop"},
            notary_failure=True,
        )

        self.assertNotEqual(run["result"].returncode, 0)
        self.assertIn("status: Invalid", run["result"].stderr)
        self.assertIn("error: Apple notarization failed", run["result"].stderr)
        self.assertNotIn("stapler staple", run["xcrun"])
        self.assertNotIn("Release artifact:", run["result"].stdout)

    def test_signed_release_requires_notarytool_profile(self):
        run = self._run_package()

        self.assertNotEqual(run["result"].returncode, 0)
        self.assertIn(
            "error: NOTARYTOOL_PROFILE is required",
            run["result"].stderr,
        )
        self.assertIn(
            "xcrun notarytool store-credentials",
            run["result"].stderr,
        )
        self.assertIn("SKIP_NOTARIZATION=1", run["result"].stderr)
        self.assertEqual(run["xcrun"], "")

    def test_skip_notarization_creates_signed_local_package(self):
        run = self._run_package(
            environment={"SKIP_NOTARIZATION": "1"},
        )

        self.assertEqual(run["result"].returncode, 0, run["result"].stderr)
        self.assertIn("--sign Developer ID Application:", run["codesign"])
        self.assertEqual(run["xcrun"], "")
        self.assertIn("Release artifact:", run["result"].stdout)

    def test_skip_codesign_creates_unsigned_local_package(self):
        run = self._run_package(
            environment={"SKIP_CODESIGN": "1"},
        )

        self.assertEqual(run["result"].returncode, 0, run["result"].stderr)
        self.assertEqual(run["codesign"], "")
        self.assertEqual(run["xcrun"], "")
        self.assertIn("Release artifact:", run["result"].stdout)

    def _run_package(
        self,
        *,
        arguments=None,
        environment=None,
        notary_failure=False,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake_bin = tmp_path / "bin"
            fake_bin.mkdir()
            logs = {
                name: tmp_path / f"{name}.log"
                for name in ("codesign", "ditto", "hdiutil", "xcrun")
            }

            self._write_executable(
                fake_bin / "git",
                """
                #!/usr/bin/env bash
                echo v9.9.9
                """,
            )
            self._write_executable(
                fake_bin / "security",
                """
                #!/usr/bin/env bash
                cat <<'EOF'
                  1) ABCDEF1234567890 "Developer ID Application: Eric Chan (TEAMID)"
                     1 valid identities found
                EOF
                """,
            )
            self._write_executable(
                fake_bin / "xcodebuild",
                """
                #!/usr/bin/env bash
                set -euo pipefail
                derived_data=
                configuration=Release
                while [[ $# -gt 0 ]]; do
                  case "$1" in
                    -derivedDataPath)
                      derived_data="$2"
                      shift 2
                      ;;
                    -configuration)
                      configuration="$2"
                      shift 2
                      ;;
                    *)
                      shift
                      ;;
                  esac
                done
                app="$derived_data/Build/Products/$configuration/M3U8Downloader.app"
                mkdir -p "$app/Contents"
                printf '<plist></plist>' > "$app/Contents/Info.plist"
                """,
            )
            self._write_executable(
                fake_bin / "codesign",
                """
                #!/usr/bin/env bash
                printf '%s\n' "$*" >> "$CODESIGN_LOG"
                """,
            )
            self._write_executable(
                fake_bin / "ditto",
                """
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s\n' "$*" >> "$DITTO_LOG"
                archive=0
                for arg in "$@"; do
                  if [[ "$arg" == "-c" ]]; then
                    archive=1
                  fi
                done
                if [[ "$archive" == "1" ]]; then
                  artifact="${@: -1}"
                  mkdir -p "$(dirname "$artifact")"
                  printf 'archive' > "$artifact"
                else
                  src="${@: -2:1}"
                  dest="${@: -1}"
                  rm -rf "$dest"
                  mkdir -p "$(dirname "$dest")"
                  cp -R "$src" "$dest"
                fi
                """,
            )
            self._write_executable(
                fake_bin / "hdiutil",
                """
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s\n' "$*" >> "$HDIUTIL_LOG"
                artifact="${@: -1}"
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
                printf 'applications=%s\n' \
                  "$(readlink "$source_folder/Applications" 2>/dev/null || true)" \
                  >> "$HDIUTIL_LOG"
                mkdir -p "$(dirname "$artifact")"
                printf 'disk image' > "$artifact"
                """,
            )
            self._write_executable(
                fake_bin / "xattr",
                """
                #!/usr/bin/env bash
                exit 0
                """,
            )
            self._write_executable(
                fake_bin / "xcrun",
                """
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s\n' "$*" >> "$XCRUN_LOG"
                if [[ "$1" == "notarytool" && "${NOTARY_FAILURE:-0}" == "1" ]]; then
                  echo "status: Invalid" >&2
                  echo "message: The archive failed validation." >&2
                  exit 1
                fi
                """,
            )

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["CODESIGN_LOG"] = str(logs["codesign"])
            env["DITTO_LOG"] = str(logs["ditto"])
            env["HDIUTIL_LOG"] = str(logs["hdiutil"])
            env["XCRUN_LOG"] = str(logs["xcrun"])
            env["NOTARY_FAILURE"] = "1" if notary_failure else "0"
            for name in (
                "CODESIGN_IDENTITY",
                "NOTARYTOOL_PROFILE",
                "SKIP_CODESIGN",
                "SKIP_NOTARIZATION",
            ):
                env.pop(name, None)
            env.update(environment or {})

            command = [
                "bash",
                str(ROOT_DIR / "scripts/package-macos-release.sh"),
                *(arguments or []),
            ]
            result = subprocess.run(
                command,
                cwd=ROOT_DIR,
                env=env,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            return {
                "result": result,
                **{
                    name: path.read_text() if path.exists() else ""
                    for name, path in logs.items()
                },
            }

    def _write_executable(self, path, content):
        path.write_text(textwrap.dedent(content).lstrip())
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
