#!/usr/bin/env python3
"""Run before every push: python3 tools/check_version.py
Checks that SD_VERSION in index.html, "current" in version.json and the newest release all match,
and that release numbers go up (newest first, no duplicates)."""
import json, re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
html = (root / 'index.html').read_text(encoding='utf-8')
m = re.search(r"const SD_VERSION='(\d+\.\d+\.\d+)'", html)
data = json.loads((root / 'version.json').read_text(encoding='utf-8'))
rel = data.get('releases', [])
key = lambda v: tuple(int(x) for x in v.split('.'))
errs = []
if not m: errs.append("SD_VERSION not found in index.html")
elif m.group(1) != data.get('current'): errs.append(f"index.html SD_VERSION {m.group(1)} != version.json current {data.get('current')}")
if not rel or rel[0].get('v') != data.get('current'): errs.append("newest release (top of the list) must equal 'current'")
vs = [r.get('v', '0.0.0') for r in rel]
if len(set(vs)) != len(vs): errs.append("duplicate version numbers: " + ", ".join(vs))
if vs != sorted(vs, key=key, reverse=True): errs.append("releases must be newest first with growing numbers")
for r in rel:
    if not (r.get('new') or r.get('fixed')): errs.append(f"v{r.get('v')} has no 'new' or 'fixed' lines")
print("\n".join("✗ " + e for e in errs) if errs else f"✓ version {data.get('current')} OK ({len(rel)} releases)")
sys.exit(1 if errs else 0)
