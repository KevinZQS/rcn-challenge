#!/usr/bin/env python3
"""
render.py -- Network Source of Truth config renderer.

Reads every device YAML in data/, renders it through the Jinja2 template
matching its 'vendor' field, and writes the result to configs/.

Usage:
    python3 scripts/render.py            # render all devices
    python3 scripts/render.py R1 S3      # render only named devices
"""
import sys
from pathlib import Path
import yaml
from jinja2 import Environment, FileSystemLoader

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
TEMPLATES = ROOT / "templates"
OUT = ROOT / "configs"


def render_device(path, env):
    device = yaml.safe_load(path.read_text())
    vendor = device.get("vendor", "arista_eos")
    template = env.get_template(f"{vendor}.j2")
    text = template.render(**device)
    # collapse the blank lines Jinja's block tags leave behind
    lines = [l.rstrip() for l in text.splitlines()]
    cleaned = "\n".join(l for l in lines if l != "") + "\n"
    return device["hostname"], cleaned


def main():
    OUT.mkdir(exist_ok=True)
    env = Environment(
        loader=FileSystemLoader(str(TEMPLATES)),
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )

    wanted = sys.argv[1:]
    files = sorted(DATA.glob("*.yml"))
    if wanted:
        files = [f for f in files if f.stem in wanted]
        if not files:
            print(f"!! no device YAML matched: {wanted}")
            sys.exit(1)

    for path in files:
        hostname, config = render_device(path, env)
        dest = OUT / f"{hostname}.cfg"
        dest.write_text(config)
        print(f"[render] {path.name} -> configs/{hostname}.cfg ({len(config)} bytes)")

    print(f"[render] {len(files)} device(s) rendered")


if __name__ == "__main__":
    main()
