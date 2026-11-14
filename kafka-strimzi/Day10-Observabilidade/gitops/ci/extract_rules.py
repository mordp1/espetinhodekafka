#!/usr/bin/env python3
"""Turn the PrometheusRule CRs of a rendered manifest stream into a plain Prometheus rules file (what `promtool` understands).

usage: kubectl kustomize manifests/observability | extract_rules.py > rules.yml
"""
import re
import sys

import yaml

groups = []
# Parse ONLY the PrometheusRule documents: the stream also carries the dashboard ConfigMaps (huge JSON blobs) that we do not need.
for chunk in re.split(r"^---\s*$", sys.stdin.read(), flags=re.M):
    if re.search(r"^kind:\s*PrometheusRule\s*$", chunk, flags=re.M):
        groups.extend(yaml.safe_load(chunk)["spec"]["groups"])
if not groups:
    sys.exit("no PrometheusRule found in the rendered manifests")
yaml.safe_dump({"groups": groups}, sys.stdout, sort_keys=False, width=1000)
