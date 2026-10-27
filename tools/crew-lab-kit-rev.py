#!/usr/bin/env python3
"""Prints the UNIT_KIT_REV the lab chart's unit-kit pack should carry.

The revision is a checksum of everything the init container installs: the
rendered crew-lab-unit-kit ConfigMap and the init container's own spec without
its revision. A pod only restarts, and so only re-reads the pack, when the
revision changes, so a hand-bumped number can be forgotten; this one cannot,
because the chart tests compare it with the value in values.yaml.

usage: crew-lab-kit-rev.py [--write]
  --write  put the revision into charts/crew-lab/values.yaml
"""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

import yaml

CHART = pathlib.Path(__file__).resolve().parent.parent / "charts" / "crew-lab"
VALUES = CHART / "values.yaml"
REV_LINE = re.compile(r'(- name: UNIT_KIT_REV\n\s+value: )"[^"\n]*"')


def revision() -> str:
    rendered = subprocess.run(
        ["helm", "template", "crew-lab", str(CHART), "--namespace", "jdwillmsen-prd", "-f", str(VALUES)],
        check=True, capture_output=True, text=True,
    ).stdout
    docs = [d for d in yaml.safe_load_all(rendered) if d]
    kit = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "crew-lab-unit-kit")
    init = next(
        c for d in docs if d["kind"] in ("Deployment", "StatefulSet")
        for c in d["spec"]["template"]["spec"].get("initContainers", []) if c["name"] == "install-unit-kit"
    )
    init = {**init, "env": [e for e in init.get("env", []) if e["name"] != "UNIT_KIT_REV"]}
    blob = json.dumps({"kit": {k: kit.get(k) for k in ("data", "binaryData")}, "init": init}, sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()[:12]


def main() -> None:
    rev = revision()
    if "--write" not in sys.argv[1:]:
        print(rev)
        return
    text = VALUES.read_text()
    new, n = REV_LINE.subn(lambda m: f'{m.group(1)}"{rev}"', text)
    if n != 1:
        sys.exit("could not find the UNIT_KIT_REV line in values.yaml")
    VALUES.write_text(new)
    print(rev)


if __name__ == "__main__":
    main()
