#!/usr/bin/env python3
"""
publish.py — re-publish catalyst-dapr-chart:<UPSTREAM>-catalyst.<N> to 709 AMMP ECR.

Mechanism (see README.md):
  1. Materialize the Diagrid Dapr fork source (clone or --fork-src).
  2. Run fork's set_helm_dapr_version.sh to sync parent+sub-chart versions.
  3. Apply patches.yaml (rename chart, set registry+tag).
  4. Validation gates (helm lint, helm template image-source check, etc.).
  5. Either --dry-run (helm-package only) or make helm-push.

Out of scope: building the catalyst-dapr image, submitting AMMP
AddDeliveryOptions, registering repos with AMMP.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

import yaml

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CHART_NAME_EXPECTED = "catalyst-dapr-chart"
DAPR_CHART_SUBPATH = "charts/dapr"
VERSION_SCRIPT_RELPATH = ".github/scripts/set_helm_dapr_version.sh"

# Matches "1.17.5-catalyst.7" (no leading 'v')
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+-catalyst\.\d+$")


# ---------------------------------------------------------------------------
# Runtime config
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Config:
    catalyst_version: str
    image_tag: str
    registry: str
    repo: str
    dry_run: bool
    git_tag: str | None
    fork_src: str | None

    @property
    def chart_registry(self) -> str:
        return f"{self.registry}/{self.repo}"


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------


def step(msg: str) -> None:
    print(f">>> {msg}")


def _user_error(msg: str) -> NoReturn:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def _subprocess_error(msg: str) -> NoReturn:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------------------
# Subprocess helper
# ---------------------------------------------------------------------------


def _run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict | None = None,
    capture_output: bool = False,
) -> subprocess.CompletedProcess:
    """Run a command; exit 2 on non-zero return code."""
    result = subprocess.run(
        cmd,
        check=False,
        cwd=str(cwd) if cwd else None,
        env=env,
        capture_output=capture_output,
        text=capture_output,
    )
    if result.returncode != 0:
        _subprocess_error(f"Command failed (exit {result.returncode}): {' '.join(cmd)}")
    return result


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="publish.py",
        description="Publish catalyst-dapr-chart to 709 AMMP ECR.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Required (one of):
  --git-tag v<UPSTREAM>-catalyst.<N>   Fork tag to clone from diagridio/dapr-dapr.
  --fork-src <path>                    Operator-pre-cloned fork tree (skip clone).

Env:
  GH_TOKEN   If set with --git-tag, uses HTTPS clone; else SSH.
""",
    )

    source_group = parser.add_mutually_exclusive_group()
    source_group.add_argument(
        "--git-tag",
        metavar="TAG",
        help="Fork tag (e.g. v1.17.5-catalyst.7); clones diagridio/dapr-dapr.",
    )
    source_group.add_argument(
        "--fork-src",
        metavar="PATH",
        help="Path to a pre-cloned fork tree; skips clone.",
    )

    parser.add_argument(
        "--catalyst-version",
        required=True,
        metavar="VERSION",
        help="Chart version to publish (e.g. 1.17.5-catalyst.7).",
    )
    parser.add_argument(
        "--image-tag",
        required=True,
        metavar="TAG",
        help="catalyst-dapr image tag (e.g. 1.17.5-catalyst.7-multi).",
    )
    parser.add_argument(
        "--registry",
        required=True,
        metavar="REGISTRY",
        help="OCI registry (e.g. 709825985650.dkr.ecr.us-east-1.amazonaws.com).",
    )
    parser.add_argument(
        "--repo",
        required=True,
        metavar="REPO",
        help="Repository prefix (e.g. diagrid).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Package locally only; skip helm push.",
    )
    return parser


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = build_parser()
    args = parser.parse_args(argv)

    # argparse handles "both", but we need to handle "neither" manually.
    if args.git_tag is None and args.fork_src is None:
        parser.error("one of --git-tag or --fork-src is required.")

    return args


# ---------------------------------------------------------------------------
# Version string validation
# ---------------------------------------------------------------------------


def validate_version_string(version: str) -> None:
    """Raise ValueError if version does not match <upstream>-catalyst.<N>."""
    if not VERSION_RE.match(version):
        raise ValueError(
            f"catalyst-version '{version}' does not match "
            "<MAJOR>.<MINOR>.<PATCH>-catalyst.<N> format (no leading 'v')."
        )


# ---------------------------------------------------------------------------
# patches.yaml loading
# ---------------------------------------------------------------------------


def load_patches(patches_file: Path) -> list[dict]:
    """Load and validate patches.yaml. Returns the list of patch entries."""
    with patches_file.open() as fh:
        data = yaml.safe_load(fh)

    if not isinstance(data, dict) or "patches" not in data:
        raise ValueError(f"patches.yaml missing top-level 'patches' key: {patches_file}")

    patches = data["patches"]
    if not isinstance(patches, list):
        raise ValueError(f"patches.yaml 'patches' must be a list, got {type(patches)}")

    for i, entry in enumerate(patches):
        if not isinstance(entry, dict):
            raise ValueError(f"patches.yaml entry {i} is not a dict")
        if "file" not in entry:
            raise ValueError(f"patches.yaml entry {i} missing 'file' key")
        if "ops" not in entry:
            raise ValueError(f"patches.yaml entry {i} missing 'ops' key")
        if not isinstance(entry["ops"], list) or not entry["ops"]:
            raise ValueError(f"patches.yaml entry {i} 'ops' must be a non-empty list")

    return patches


# ---------------------------------------------------------------------------
# Pipeline steps
# ---------------------------------------------------------------------------


def prepare_source(workdir: Path, cfg: Config) -> tuple[Path, Path]:
    """Clone or copy fork into workdir. Returns (src_root, chart_root)."""
    src_root = materialize_source(workdir, git_tag=cfg.git_tag, fork_src=cfg.fork_src)

    chart_root = src_root / DAPR_CHART_SUBPATH
    if not chart_root.is_dir():
        _user_error(f"expected chart source at {chart_root} — fork layout mismatch?")

    # Gate 7 — tag fidelity (only with --git-tag)
    if cfg.git_tag:
        gate_tag_fidelity(src_root, cfg.git_tag)

    # Gate 6 — fork fidelity (BEFORE patching, so we reject upstream dapr/dapr early)
    gate_fork_fidelity(chart_root)

    return src_root, chart_root


def apply_patches(
    patches: list[dict],
    src_root: Path,
    *,
    chart_name: str,
    chart_registry: str,
    image_tag: str,
) -> None:
    """Apply all patch ops using yq, with env vars exported for strenv()."""
    env = os.environ.copy()
    env["CHART_NAME"] = chart_name
    env["CHART_REGISTRY"] = chart_registry
    env["IMAGE_TAG"] = image_tag

    for i, entry in enumerate(patches):
        rel_file = entry["file"]
        target = src_root / rel_file
        if not target.is_file():
            _user_error(f"patches.yaml entry {i} references missing file: {target}")
        for op in entry["ops"]:
            print(f"    [{rel_file}] {op}")
            _run(["yq", "-i", op, str(target)], env=env)


def validate_gates(chart_root: Path, cfg: Config) -> None:
    """Run all 5 post-patch validation gates in order."""
    gate_helm_lint(chart_root)
    gate_image_sources(chart_root, cfg.chart_registry)
    gate_chart_name(chart_root)
    gate_registry(chart_root, cfg.chart_registry)
    gate_image_tag(chart_root, cfg.image_tag)


def package_chart(charts_dir: Path, chart_root: Path, cfg: Config) -> None:
    """dry_run_package: helm-package only, no push. Preserves .tgz to /tmp."""
    step("--dry-run: helm-package only (no push) ...")

    keep_dest = Path(f"/tmp/catalyst-dapr-chart-publish-{cfg.catalyst_version}-dist")
    keep_dest.mkdir(parents=True, exist_ok=True)

    _run([
        "make",
        "-C", str(charts_dir),
        "helm-package",
        f"CHART_DIR={chart_root}",
        f"CHART_NAME={CHART_NAME_EXPECTED}",
        f"VERSION={cfg.catalyst_version}",
    ])

    tgz = chart_root / "dist" / f"{CHART_NAME_EXPECTED}-{cfg.catalyst_version}.tgz"
    if not tgz.is_file():
        _user_error(f"dry-run failed — expected {tgz} not found.")

    dest_tgz = keep_dest / tgz.name
    shutil.copy2(str(tgz), str(dest_tgz))
    step(f"DRY-RUN OK. Local package: {tgz}")
    step(f"Preserved copy: {dest_tgz}")


def push_chart(charts_dir: Path, chart_root: Path, cfg: Config) -> None:
    """Push chart to AMMP ECR via make helm-push."""
    step("Pushing chart via make helm-push ...")
    _run([
        "make",
        "-C", str(charts_dir),
        "helm-push",
        f"CHART_DIR={chart_root}",
        f"CHART_NAME={CHART_NAME_EXPECTED}",
        f"VERSION={cfg.catalyst_version}",
        f"REGISTRY={cfg.registry}",
        f"REPO={cfg.repo}",
    ])
    chart_registry_uri = f"oci://{cfg.chart_registry}/"
    step(f"DONE. Published {CHART_NAME_EXPECTED}:{cfg.catalyst_version} to {chart_registry_uri}")


# ---------------------------------------------------------------------------
# Source materialization
# ---------------------------------------------------------------------------


def materialize_source(
    workdir: Path,
    *,
    git_tag: str | None,
    fork_src: str | None,
) -> Path:
    """Clone or copy fork into workdir/dapr-dapr. Returns src_root path."""
    src_root = workdir / "dapr-dapr"

    if fork_src:
        fork_path = Path(fork_src)
        if not fork_path.is_dir():
            _user_error(f"--fork-src path does not exist: {fork_src}")
        step(f"Copying pre-cloned fork from {fork_src} ...")
        shutil.copytree(str(fork_path), str(src_root))
    else:
        assert git_tag is not None, "git_tag must be set when fork_src is None"
        step(f"Cloning diagridio/dapr-dapr at tag {git_tag} ...")
        gh_token = os.environ.get("GH_TOKEN", "")
        if gh_token:
            url = f"https://x-access-token:{gh_token}@github.com/diagridio/dapr-dapr.git"
        else:
            url = "git@github.com:diagridio/dapr-dapr.git"
        _run(["git", "clone", "--depth", "1", "-b", git_tag, url, str(src_root)])

    return src_root


# ---------------------------------------------------------------------------
# Individual validation gates
# ---------------------------------------------------------------------------


def gate_tag_fidelity(src_root: Path, git_tag: str) -> None:
    step(f"Gate 7: verifying clone is at tag {git_tag} ...")
    _run(["git", "-C", str(src_root), "rev-parse", "--verify", git_tag])


def gate_fork_fidelity(chart_root: Path) -> None:
    """Reject upstream dapr/dapr — fork-only fields must be present (before patching)."""
    step("Gate 6: source-fidelity check (fork-only fields must be present) ...")
    values_file = chart_root / "values.yaml"
    with values_file.open() as fh:
        values = yaml.safe_load(fh)

    global_section = values.get("global", {}) if isinstance(values, dict) else {}
    rbac = global_section.get("rbac", {})
    operator = global_section.get("operator", {})

    if rbac.get("skipClusterRBAC") is None or operator.get("disableWebhooks") is None:
        _user_error(
            "source does NOT look like the Diagrid Dapr fork — fork-only fields\n"
            "       skipClusterRBAC/disableWebhooks are missing from charts/dapr/values.yaml.\n"
            "       Did you accidentally point --fork-src at upstream dapr/dapr?\n"
            "       The fork source must be diagridio/dapr-dapr, not the upstream dapr/dapr chart."
        )


def gate_helm_lint(chart_root: Path) -> None:
    step(f"Gate 1: helm lint {chart_root} ...")
    _run(["helm", "lint", str(chart_root)])


def gate_image_sources(chart_root: Path, chart_registry: str) -> None:
    """Every image in helm template output must come from chart_registry."""
    step(f"Gate 2: helm template image-source check (every image must come from {chart_registry}) ...")
    result = subprocess.run(
        ["helm", "template", "release-name", str(chart_root)],
        capture_output=True,
        text=True,
    )
    render = result.stdout

    bad_images = [
        line.strip()[len("image:"):].strip().strip('"').strip("'")
        for line in render.splitlines()
        if line.strip().startswith("image:")
        and not line.strip()[len("image:"):].strip().strip('"').strip("'").startswith(f"{chart_registry}/")
        and line.strip()[len("image:"):].strip().strip('"').strip("'")
    ]

    if bad_images:
        print(f"ERROR: helm template rendered image refs NOT under {chart_registry}/:", file=sys.stderr)
        for img in bad_images:
            print(f"  {img}", file=sys.stderr)
        sys.exit(1)


def gate_chart_name(chart_root: Path) -> None:
    step(f"Gate 3: Chart.yaml .name == {CHART_NAME_EXPECTED} ...")
    with (chart_root / "Chart.yaml").open() as fh:
        chart_yaml = yaml.safe_load(fh)
    name = chart_yaml.get("name", "") if isinstance(chart_yaml, dict) else ""
    if name != CHART_NAME_EXPECTED:
        _user_error(f"Chart.yaml .name = '{name}', expected '{CHART_NAME_EXPECTED}'.")


def gate_registry(chart_root: Path, chart_registry: str) -> None:
    step(f"Gate 4: values.yaml .global.registry == {chart_registry} ...")
    with (chart_root / "values.yaml").open() as fh:
        values = yaml.safe_load(fh)
    reg = (values or {}).get("global", {}).get("registry", "")
    if reg != chart_registry:
        _user_error(f".global.registry = '{reg}', expected '{chart_registry}'.")


def gate_image_tag(chart_root: Path, image_tag: str) -> None:
    step(f"Gate 5: values.yaml .global.tag == {image_tag} ...")
    with (chart_root / "values.yaml").open() as fh:
        values = yaml.safe_load(fh)
    tag = (values or {}).get("global", {}).get("tag", "")
    if str(tag) != image_tag:
        _user_error(f".global.tag = '{tag}', expected '{image_tag}'.")


# ---------------------------------------------------------------------------
# Version sync (fork's script)
# ---------------------------------------------------------------------------


def run_version_script(src_root: Path, catalyst_version: str) -> None:
    version_script = src_root / VERSION_SCRIPT_RELPATH
    if not version_script.exists():
        _user_error(f"fork version script not found at {version_script}")
    step(f"Running fork's set_helm_dapr_version.sh REL_VERSION={catalyst_version} ...")
    env = os.environ.copy()
    env["REL_VERSION"] = catalyst_version
    _run(["bash", f"./{VERSION_SCRIPT_RELPATH}"], cwd=src_root, env=env)


# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------


def _check_tools() -> None:
    for cmd in ("yq", "helm", "git"):
        if not shutil.which(cmd):
            _user_error(f"{cmd} not found in PATH.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    charts_dir = script_dir.parent  # cloudgrid/charts
    patches_file = script_dir / "patches.yaml"

    if not patches_file.is_file():
        _user_error(f"patches.yaml not found at {patches_file}")

    try:
        validate_version_string(args.catalyst_version)
    except ValueError as exc:
        _user_error(str(exc))

    _check_tools()

    cfg = Config(
        catalyst_version=args.catalyst_version,
        image_tag=args.image_tag,
        registry=args.registry,
        repo=args.repo,
        dry_run=args.dry_run,
        git_tag=args.git_tag,
        fork_src=args.fork_src,
    )

    # Load patches early to catch schema errors before any side effects.
    patches = load_patches(patches_file)

    workdir = Path(f"/tmp/catalyst-dapr-chart-publish-{cfg.catalyst_version}")
    keep_workdir = os.environ.get("KEEP_WORKDIR", "false").lower() == "true"

    if workdir.exists():
        shutil.rmtree(workdir)
    workdir.mkdir(parents=True)

    try:
        src_root, chart_root = prepare_source(workdir, cfg)

        run_version_script(src_root, cfg.catalyst_version)

        step("Applying patches.yaml ...")
        apply_patches(
            patches,
            src_root,
            chart_name=CHART_NAME_EXPECTED,
            chart_registry=cfg.chart_registry,
            image_tag=cfg.image_tag,
        )

        validate_gates(chart_root, cfg)

        if cfg.dry_run:
            package_chart(charts_dir, chart_root, cfg)
        else:
            push_chart(charts_dir, chart_root, cfg)

    finally:
        if not keep_workdir:
            shutil.rmtree(workdir, ignore_errors=True)
        else:
            print(f"KEEP_WORKDIR=true; leaving {workdir} for inspection.", file=sys.stderr)


if __name__ == "__main__":
    main()
