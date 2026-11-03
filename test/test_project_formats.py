#!/usr/bin/env python3
"""Exercise CLI project normalization without Xcode or a signing identity.

Run on macOS (the legacy path uses BSD sed): python3 test/test_project_formats.py
Only conversion, building, and signature verification are stubbed.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "chrome-to-safari.sh"
FIXTURES = Path(__file__).resolve().parent / "fixtures"


class ProjectFormatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="portkit project test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.extension = self.root / "extension"
        self.extension.mkdir()
        (self.extension / "manifest.json").write_text('{"name": "Test Extension"}')
        # The CLI must also work when downloaded without the rest of the repo.
        self.script = self.root / "chrome-to-safari.sh"
        shutil.copyfile(SCRIPT, self.script)
        self.output = self.root / "output"
        self.project = self.output / "Test Extension/Test Extension.xcodeproj"
        self.fixture = self.root / "fixture"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEAM_ID="TESTTEAM01", APP_NAME="Test Extension",
                        BUNDLE_ID="com.requested.extension", OUT_DIR=str(self.output),
                        FIXTURE=str(self.fixture))
        self.stub("xcrun", """
            #!/usr/bin/env python3
            import os
            from pathlib import Path
            import shutil
            project = Path(os.environ["OUT_DIR"]) / "Test Extension/Test Extension.xcodeproj"
            project.mkdir(parents=True)
            if os.environ["PROJECT_FILE"]:
                shutil.copyfile(os.environ["FIXTURE"], project / os.environ["PROJECT_FILE"])
        """)
        self.stub("xcodebuild", """
            #!/bin/bash
            touch "$OUT_DIR/build-called"
            mkdir -p "$OUT_DIR/build/Build/Products/Release/Test Extension.app"
            echo '** BUILD SUCCEEDED **'
        """)
        self.stub("codesign", """
            #!/bin/bash
            touch "$OUT_DIR/codesign-called"
        """)

    def stub(self, name, source):
        path = self.bin / name
        path.write_text(textwrap.dedent(source).lstrip())
        path.chmod(0o755)

    def run_cli(self, filename, source):
        self.fixture.write_text(source, encoding="utf-8")
        return subprocess.run(
            ["bash", str(self.script), str(self.extension), "--build-only"],
            env=dict(self.env, PROJECT_FILE=filename), cwd=self.root,
            text=True, capture_output=True,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.output / "build-called").exists())
        self.assertTrue((self.output / "codesign-called").exists())

    def test_xcproj_preserves_app_ids_and_trailing_commas(self):
        source = (FIXTURES / "project.xcproj").read_text()
        self.assert_success(self.run_cli("project.xcproj", source))
        expected = source.replace("com.requested.extension.Extension",
                                  "com.generated.Test-Extension.Extension")
        self.assertEqual((self.project / "project.xcproj").read_text(), expected)

    def test_xcproj_already_normalized(self):
        source = (FIXTURES / "project.xcproj").read_text().replace(
            "com.requested.extension.Extension", "com.generated.Test-Extension.Extension")
        self.assert_success(self.run_cli("project.xcproj", source))
        self.assertEqual((self.project / "project.xcproj").read_text(), source)

    def test_pbxproj_quoted_and_unquoted_settings(self):
        source = (FIXTURES / "project.pbxproj").read_text()
        self.assert_success(self.run_cli("project.pbxproj", source))
        expected = source.replace(
            '"com.requested.extension.Extension"', '"com.generated.Test-Extension.Extension"'
        ).replace(
            "= com.requested.extension.Extension;", '= "com.generated.Test-Extension.Extension";'
        )
        self.assertEqual((self.project / "project.pbxproj").read_text(), expected)

    def test_xcproj_missing_identifiers_fails_before_building(self):
        for source in ('{}', '{\n"PRODUCT_BUNDLE_IDENTIFIER": "com.app",\n}',
                       '{\n"PRODUCT_BUNDLE_IDENTIFIER": "com.app.Extension",\n}'):
            with self.subTest(source=source):
                if self.project.exists():
                    shutil.rmtree(self.project)
                result = self.run_cli("project.xcproj", source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cannot find app and extension bundle identifiers", result.stderr)
                self.assertFalse((self.output / "build-called").exists())
                self.assertEqual((self.project / "project.xcproj").read_text(), source)

    def test_missing_project_file_fails_before_building(self):
        result = self.run_cli("", "")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no project.pbxproj or project.xcproj found", result.stderr)
        self.assertFalse((self.output / "build-called").exists())


if __name__ == "__main__":
    unittest.main()
