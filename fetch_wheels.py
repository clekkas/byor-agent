"""
Download dependency wheels on your HOST (where pip works) so the Docker build can
install them with no network access.

    python fetch_wheels.py                       # minimal set (echo mode) - default
    python fetch_wheels.py --full                # includes openai + azure-identity
    python fetch_wheels.py -r requirements.txt   # explicit file

Then build:

    docker build --platform linux/amd64 -f Dockerfile.offline -t byor-agent:0.1 .

Why platform tags matter: wheels are published per platform + Python version + ABI.
Compiled packages (jiter, pydantic-core) only exist for specific tag combinations, so
this tries several and keeps whatever each attempt manages to download.
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WHEELS = ROOT / "wheels"

# Tried in order; each run adds to wheels/. Newer manylinux tags first because
# Rust-built packages (jiter) typically publish only those.
PLATFORM_TAGS = [
    "manylinux_2_28_x86_64",
    "manylinux_2_17_x86_64",
    "manylinux2014_x86_64",
]


def required_names(req_file: Path):
    names = []
    for line in req_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        for sep in ("[", "==", ">=", "<=", "~=", "<", ">", ";"):
            if sep in line:
                line = line.split(sep)[0]
        names.append(line.strip().lower().replace("-", "_"))
    return names


def attempt(req_file: Path, platform: str, abi: str | None):
    cmd = [
        sys.executable, "-m", "pip", "download",
        "-r", str(req_file),
        "-d", str(WHEELS),
        "--only-binary=:all:",
        "--python-version", "3.12",
        "--implementation", "cp",
        "--platform", platform,
    ]
    if abi:
        cmd += ["--abi", abi]
    print(f"\n==> platform={platform} abi={abi or 'default'}")
    return subprocess.run(cmd).returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-r", "--requirements", default=None)
    ap.add_argument("--full", action="store_true",
                    help="use requirements.txt (adds openai + azure-identity)")
    ap.add_argument("--keep", action="store_true", help="do not clear wheels/ first")
    args = ap.parse_args()

    if args.requirements:
        req = ROOT / args.requirements
    elif args.full:
        req = ROOT / "requirements.txt"
    else:
        req = ROOT / "requirements-min.txt"

    if not req.exists():
        print(f"ERROR: {req} not found")
        return 1

    print(f"==> fetch_wheels.py rev 2 (platform tags: {', '.join(PLATFORM_TAGS)})")
    print(f"==> Requirements: {req.name}")
    print(f"    {', '.join(required_names(req))}")

    if WHEELS.exists() and not args.keep:
        shutil.rmtree(WHEELS)
    WHEELS.mkdir(parents=True, exist_ok=True)

    for platform in PLATFORM_TAGS:
        for abi in ("cp312", None):
            if attempt(req, platform, abi):
                break

    wheels = sorted(p.name for p in WHEELS.glob("*.whl"))
    print("\n-------------------------------")
    if not wheels:
        print("  No wheels downloaded.")
        print("  pip could not reach an index from this machine either. Options:")
        print("    - connect to VPN")
        print("    - PIP_INDEX_URL pointing at an internal mirror or a JFrog PyPI remote")
        return 1

    print(f"  {len(wheels)} wheels in wheels/")
    for w in wheels:
        print(f"    {w}")

    # Warn about anything in the requirements file with no matching wheel.
    have = " ".join(wheels).lower().replace("-", "_")
    missing = [n for n in required_names(req) if n not in have]
    if missing:
        print(f"\n  WARNING: no wheel found for: {', '.join(missing)}")
        print("  The offline build will fail on these. Try --full only if you need model mode,")
        print("  or use Dockerfile.proxy with PIP_INDEX_URL pointing at a mirror.")
        return 1

    print("\n  Next - the requirements file MUST match what the build installs:")
    if req.name == "requirements-min.txt":
        print("    docker build --platform linux/amd64 -f Dockerfile.offline -t byor-agent:0.1 .")
    else:
        print("    docker build --platform linux/amd64 -f Dockerfile.offline -t byor-agent:0.1 \\")
        print(f"      --build-arg REQUIREMENTS_FILE={req.name} .")
    return 0


if __name__ == "__main__":
    sys.exit(main())
