#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SKILL_DIR = pathlib.Path(__file__).resolve().parents[1]
UPDATER = SKILL_DIR / "scripts" / "update-ghostel-module"
OLD_VERSION = "1.2.3"
NEW_VERSION = "1.2.4"
OLD_HASHES = {
    "aarch64-darwin": "sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=",
    "x86_64-linux": "sha256-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=",
}
NEW_HASHES = {
    "aarch64-darwin": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    "x86_64-linux": "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
}
ASSETS = {
    "aarch64-darwin": "ghostel-module-aarch64-macos.dylib",
    "x86_64-linux": "ghostel-module-x86_64-linux.so",
}


def package_fixture() -> str:
    return f'''{{ epkgs, pkgs }}:

let
  ghostel = epkgs.ghostel;
  supportedVersion = "{OLD_VERSION}";
  modules = {{
    "aarch64-darwin" = {{
      asset = "{ASSETS["aarch64-darwin"]}";
      hash = "{OLD_HASHES["aarch64-darwin"]}";
    }};
    "x86_64-linux" = {{
      asset = "{ASSETS["x86_64-linux"]}";
      hash = "{OLD_HASHES["x86_64-linux"]}";
    }};
  }};
in
ghostel
'''


class GhostelUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ghostel-update-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.package = self.root / "ghostel.nix"
        self.package.write_text(package_fixture(), encoding="utf-8")
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        release = {
            "tag_name": f"v{NEW_VERSION}",
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": asset,
                    "state": "uploaded",
                    "browser_download_url": (
                        "https://github.com/dakra/ghostel/releases/download/"
                        f"v{NEW_VERSION}/{asset}"
                    ),
                }
                for asset in ASSETS.values()
            ],
        }
        (self.fixtures / "release.json").write_text(
            json.dumps(release), encoding="utf-8"
        )
        for system, hash_value in NEW_HASHES.items():
            (self.fixtures / f"{system}.json").write_text(
                json.dumps({"hash": hash_value, "storePath": "/nix/store/fixture"}),
                encoding="utf-8",
            )

    def tearDown(self):
        self.temporary.cleanup()

    def run_updater(self, *arguments, expect=0, env=None):
        result = subprocess.run(
            [
                sys.executable,
                str(UPDATER),
                "--package",
                str(self.package),
                "--old-version",
                OLD_VERSION,
                "--new-version",
                NEW_VERSION,
                *arguments,
            ],
            text=True,
            capture_output=True,
            env=env,
        )
        self.assertEqual(result.returncode, expect, result.stderr)
        return result

    def test_unchanged_version_with_hashes_is_a_no_op(self):
        result = self.run_updater("--new-version", OLD_VERSION)
        self.assertIn("unchanged", result.stdout)
        self.assertNotIn("gh api", result.stderr)

    def test_supported_version_change_dry_run_and_edit(self):
        before = self.package.read_text(encoding="utf-8")
        dry_run = self.run_updater("--fixture-dir", str(self.fixtures), "--dry-run")
        self.assertEqual(self.package.read_text(encoding="utf-8"), before)
        self.assertIn(f'-  supportedVersion = "{OLD_VERSION}";', dry_run.stdout)
        self.assertIn(f'+  supportedVersion = "{NEW_VERSION}";', dry_run.stdout)
        for system, asset in ASSETS.items():
            self.assertIn("nix store prefetch-file --json", dry_run.stderr)
            self.assertIn(asset, dry_run.stderr)
            self.assertIn(f"fixture: {system}.json", dry_run.stderr)

        self.run_updater("--fixture-dir", str(self.fixtures))
        updated = self.package.read_text(encoding="utf-8")
        self.assertIn(f'supportedVersion = "{NEW_VERSION}";', updated)
        for hash_value in NEW_HASHES.values():
            self.assertIn(f'hash = "{hash_value}";', updated)

    def test_missing_hash_entry_fails_even_when_version_is_unchanged(self):
        text = self.package.read_text(encoding="utf-8")
        self.package.write_text(
            text.replace(
                f'hash = "{OLD_HASHES["x86_64-linux"]}";',
                'hash = "";',
            ),
            encoding="utf-8",
        )
        result = self.run_updater("--new-version", OLD_VERSION, expect=1)
        self.assertIn("missing or invalid hash entry", result.stderr)

    def test_missing_release_asset_fails_without_editing(self):
        release_path = self.fixtures / "release.json"
        release = json.loads(release_path.read_text(encoding="utf-8"))
        release["assets"] = release["assets"][:1]
        release_path.write_text(json.dumps(release), encoding="utf-8")
        before = self.package.read_text(encoding="utf-8")
        result = self.run_updater("--fixture-dir", str(self.fixtures), expect=1)
        self.assertIn("is missing asset", result.stderr)
        self.assertEqual(self.package.read_text(encoding="utf-8"), before)

    def test_incomplete_release_asset_is_rejected(self):
        release_path = self.fixtures / "release.json"
        release = json.loads(release_path.read_text(encoding="utf-8"))
        release["assets"][0]["state"] = "new"
        release_path.write_text(json.dumps(release), encoding="utf-8")
        result = self.run_updater("--fixture-dir", str(self.fixtures), expect=1)
        self.assertIn("not fully uploaded", result.stderr)

    def test_missing_release_command_preserves_failure_diagnostic(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_gh = fake_bin / "gh"
        fake_gh.write_text(
            "#!/bin/sh\necho 'HTTP 404: release not found' >&2\nexit 22\n",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        result = self.run_updater(expect=1, env=environment)
        self.assertIn("exit status 22", result.stderr)
        self.assertIn("HTTP 404: release not found", result.stderr)

    def test_unexpected_version_relationship_is_non_mechanical(self):
        result = self.run_updater("--old-version", "1.2.2", expect=1)
        self.assertIn("non-mechanical version relationship", result.stderr)
        self.assertNotIn("gh api", result.stderr)

    def test_unsupported_platform_entry_is_non_mechanical(self):
        text = self.package.read_text(encoding="utf-8")
        marker = '    "x86_64-linux" = {'
        extra = (
            '    "aarch64-linux" = {\n'
            '      asset = "ghostel-module-aarch64-linux.so";\n'
            f'      hash = "{NEW_HASHES["aarch64-darwin"]}";\n'
            "    };\n"
        )
        self.package.write_text(text.replace(marker, extra + marker), encoding="utf-8")
        result = self.run_updater(expect=1)
        self.assertIn("unsupported platform", result.stderr)
        self.assertNotIn("gh api", result.stderr)

    def test_noncanonical_extra_platform_cannot_bypass_validation(self):
        text = self.package.read_text(encoding="utf-8")
        marker = '    "x86_64-linux" = {'
        extra = (
            '    "aarch64-linux"={\n'
            '      asset = "ghostel-module-aarch64-linux.so";\n'
            f'      hash = "{NEW_HASHES["aarch64-darwin"]}";\n'
            "    };\n"
        )
        self.package.write_text(text.replace(marker, extra + marker), encoding="utf-8")
        result = self.run_updater(expect=1)
        self.assertIn("modules attrset", result.stderr)
        self.assertNotIn("gh api", result.stderr)


if __name__ == "__main__":
    unittest.main()
