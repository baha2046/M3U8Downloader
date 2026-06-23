import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]


class PackageMacOSReleaseTests(unittest.TestCase):
    def test_package_auto_signs_with_developer_id_application_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake_bin = tmp_path / "bin"
            fake_bin.mkdir()
            codesign_log = tmp_path / "codesign.log"
            ditto_log = tmp_path / "ditto.log"

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

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["CODESIGN_LOG"] = str(codesign_log)
            env["DITTO_LOG"] = str(ditto_log)
            env.pop("CODESIGN_IDENTITY", None)

            subprocess.run(
                ["bash", str(ROOT_DIR / "scripts/package-macos-release.sh")],
                cwd=ROOT_DIR,
                env=env,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            log_contents = codesign_log.read_text() if codesign_log.exists() else ""
            self.assertIn(
                '--sign Developer ID Application: Eric Chan (TEAMID)',
                log_contents,
            )
            self.assertIn("--noextattr", ditto_log.read_text())
            self.assertIn("--noqtn", ditto_log.read_text())

    def _write_executable(self, path, content):
        path.write_text(textwrap.dedent(content).lstrip())
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
