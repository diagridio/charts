"""
Tests for publish.py — catalyst-dapr-chart publish script.

Subprocess calls are mocked throughout; these tests do NOT clone repos or
invoke helm/git/yq for real.
"""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Ensure publish.py is importable from the parent directory.
# ---------------------------------------------------------------------------
PUBLISH_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PUBLISH_DIR))

import publish  # noqa: E402


FIXTURES = Path(__file__).resolve().parent / "fixtures"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

VALID_ARGS = [
    "--git-tag", "v1.17.5-catalyst.7",
    "--catalyst-version", "1.17.5-catalyst.7",
    "--image-tag", "1.17.5-catalyst.7-multi",
    "--registry", "709825985650.dkr.ecr.us-east-1.amazonaws.com",
    "--repo", "diagrid",
]


# ---------------------------------------------------------------------------
# 1. Argument parsing
# ---------------------------------------------------------------------------


class TestArgParsing:
    def test_git_tag_xor_fork_src_both_raises(self):
        """Providing both --git-tag and --fork-src must be rejected."""
        with pytest.raises(SystemExit) as exc_info:
            publish.parse_args([
                "--git-tag", "v1.17.5-catalyst.7",
                "--fork-src", "/tmp/dapr-dapr",
                "--catalyst-version", "1.17.5-catalyst.7",
                "--image-tag", "1.17.5-catalyst.7-multi",
                "--registry", "709825985650.dkr.ecr.us-east-1.amazonaws.com",
                "--repo", "diagrid",
            ])
        assert exc_info.value.code != 0

    def test_git_tag_xor_fork_src_neither_raises(self):
        """Providing neither --git-tag nor --fork-src must be rejected."""
        with pytest.raises(SystemExit) as exc_info:
            publish.parse_args([
                "--catalyst-version", "1.17.5-catalyst.7",
                "--image-tag", "1.17.5-catalyst.7-multi",
                "--registry", "709825985650.dkr.ecr.us-east-1.amazonaws.com",
                "--repo", "diagrid",
            ])
        assert exc_info.value.code != 0



# ---------------------------------------------------------------------------
# 2. patches.yaml schema validation
# ---------------------------------------------------------------------------


class TestPatchesYaml:
    def test_load_valid_fixture(self):
        patches = publish.load_patches(FIXTURES / "patches.yaml")
        assert len(patches) == 2
        for entry in patches:
            assert "file" in entry
            assert "ops" in entry
            assert isinstance(entry["ops"], list)
            assert len(entry["ops"]) > 0

    def test_missing_patches_key_raises(self, tmp_path):
        bad = tmp_path / "bad.yaml"
        bad.write_text("notpatches:\n  - foo\n")
        with pytest.raises(ValueError, match="missing top-level 'patches'"):
            publish.load_patches(bad)

    def test_missing_file_key_raises(self, tmp_path):
        bad = tmp_path / "bad.yaml"
        bad.write_text("patches:\n  - ops:\n    - '.name = \"x\"'\n")
        with pytest.raises(ValueError, match="missing 'file' key"):
            publish.load_patches(bad)

    def test_missing_ops_key_raises(self, tmp_path):
        bad = tmp_path / "bad.yaml"
        bad.write_text("patches:\n  - file: charts/dapr/Chart.yaml\n")
        with pytest.raises(ValueError, match="missing 'ops' key"):
            publish.load_patches(bad)

    def test_empty_ops_raises(self, tmp_path):
        bad = tmp_path / "bad.yaml"
        bad.write_text("patches:\n  - file: charts/dapr/Chart.yaml\n    ops: []\n")
        with pytest.raises(ValueError, match="must be a non-empty list"):
            publish.load_patches(bad)


# ---------------------------------------------------------------------------
# 3. Version string handling
# ---------------------------------------------------------------------------


class TestVersionString:
    @pytest.mark.parametrize("version", [
        "1.17.5-catalyst.7",
        "0.1.0-catalyst.99",
    ])
    def test_valid_versions(self, version):
        # Should not raise
        publish.validate_version_string(version)

    @pytest.mark.parametrize("bad_version", [
        "v1.17.5-catalyst.7",   # leading 'v'
        "1.17.5",               # no catalyst suffix
        "1.17.5-catalyst",      # no N
        "",                     # empty
    ])
    def test_invalid_versions_raise(self, bad_version):
        with pytest.raises(ValueError):
            publish.validate_version_string(bad_version)


# ---------------------------------------------------------------------------
# 4. Patch application on fixture files (no subprocess needed)
# ---------------------------------------------------------------------------


class TestPatchApplication:
    def test_apply_patches_missing_file_exits(self, tmp_path):
        """apply_patches should exit with code 1 when referenced file is absent."""
        patches = publish.load_patches(FIXTURES / "patches.yaml")
        # Don't create any files — all referenced files are missing
        with pytest.raises(SystemExit) as exc_info:
            publish.apply_patches(
                patches,
                tmp_path,
                chart_name="catalyst-dapr-chart",
                chart_registry="709.../diagrid",
                image_tag="1.17.5-catalyst.7-multi",
            )
        assert exc_info.value.code == 1


# ---------------------------------------------------------------------------
# 5. Validation gates — positive + negative cases
# ---------------------------------------------------------------------------


class TestGateForkFidelity:
    def test_fork_values_passes(self, tmp_path):
        """values.yaml with fork-only fields passes gate 6."""
        import shutil
        shutil.copy(FIXTURES / "values.yaml", tmp_path / "values.yaml")
        # Should not raise/exit
        publish.gate_fork_fidelity(tmp_path)

    def test_upstream_values_fails(self, tmp_path):
        """values.yaml missing fork-only fields triggers exit(1)."""
        import shutil
        shutil.copy(FIXTURES / "values_upstream.yaml", tmp_path / "values.yaml")
        with pytest.raises(SystemExit) as exc_info:
            publish.gate_fork_fidelity(tmp_path)
        assert exc_info.value.code == 1


class TestGateChartName:
    def test_correct_name_passes(self, tmp_path):
        chart = tmp_path / "Chart.yaml"
        chart.write_text("name: catalyst-dapr-chart\nversion: 1.0.0\n")
        publish.gate_chart_name(tmp_path)  # no exit

    def test_wrong_name_fails(self, tmp_path):
        chart = tmp_path / "Chart.yaml"
        chart.write_text("name: dapr\nversion: 1.0.0\n")
        with pytest.raises(SystemExit) as exc_info:
            publish.gate_chart_name(tmp_path)
        assert exc_info.value.code == 1


class TestGateRegistry:
    def test_correct_registry_passes(self, tmp_path):
        values = tmp_path / "values.yaml"
        values.write_text("global:\n  registry: 709.../diagrid\n  tag: t\n")
        publish.gate_registry(tmp_path, "709.../diagrid")

    def test_wrong_registry_fails(self, tmp_path):
        values = tmp_path / "values.yaml"
        values.write_text("global:\n  registry: wrong.registry/diagrid\n  tag: t\n")
        with pytest.raises(SystemExit) as exc_info:
            publish.gate_registry(tmp_path, "709.../diagrid")
        assert exc_info.value.code == 1


class TestGateImageTag:
    def test_correct_tag_passes(self, tmp_path):
        values = tmp_path / "values.yaml"
        values.write_text("global:\n  registry: r\n  tag: 1.17.5-catalyst.7-multi\n")
        publish.gate_image_tag(tmp_path, "1.17.5-catalyst.7-multi")

    def test_wrong_tag_fails(self, tmp_path):
        values = tmp_path / "values.yaml"
        values.write_text("global:\n  registry: r\n  tag: wrong-tag\n")
        with pytest.raises(SystemExit) as exc_info:
            publish.gate_image_tag(tmp_path, "1.17.5-catalyst.7-multi")
        assert exc_info.value.code == 1


class TestGateImageSources:
    def test_all_images_from_registry_passes(self, tmp_path):
        """helm template output where all images are from the expected registry."""
        # Real helm template output: 'image:' appears with leading spaces, NOT
        # preceded by '-' (that's the list marker for the container object itself).
        render = (
            "---\n"
            "spec:\n"
            "  containers:\n"
            "  - name: dapr-operator\n"
            '    image: "709.../diagrid/dapr-operator:v1"\n'
            "  - name: dapr-sentry\n"
            '    image: "709.../diagrid/dapr-sentry:v1"\n'
        )
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=render, stderr="")
            publish.gate_image_sources(tmp_path, "709.../diagrid")

    def test_foreign_image_fails(self, tmp_path):
        """helm template output with a docker.io image triggers exit(1)."""
        render = (
            "---\n"
            "spec:\n"
            "  containers:\n"
            "  - name: dapr-operator\n"
            '    image: "709.../diagrid/dapr-operator:v1"\n'
            "  - name: daprd\n"
            '    image: "docker.io/daprio/daprd:1.17.5"\n'
        )
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=render, stderr="")
            with pytest.raises(SystemExit) as exc_info:
                publish.gate_image_sources(tmp_path, "709.../diagrid")
        assert exc_info.value.code == 1


# ---------------------------------------------------------------------------
# 6. Subprocess mocking — materialize_source
# ---------------------------------------------------------------------------


class TestMaterializeSource:
    def test_fork_src_missing_exits(self, tmp_path):
        with pytest.raises(SystemExit) as exc_info:
            publish.materialize_source(
                tmp_path,
                git_tag=None,
                fork_src="/nonexistent/path",
            )
        assert exc_info.value.code == 1
