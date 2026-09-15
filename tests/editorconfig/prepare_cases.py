"""Convert the vendored upstream CMake glob cases to deterministic JSON fixtures.

Upstream fixtures and expectations: BSD-2-Clause, see LICENSE.txt and REVISION.
The explicit overrides below follow the newer EditorConfig 0.17.2 specification.
"""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent
source = (root / "CMakeLists.txt").read_text(encoding="utf-8")
# 0.17.2 treats bracket contents as literal characters, including hyphens.
overrides = {
    "brackets_range": {},
    "brackets_nrange2": {"range": "false"},
    "brackets_range_and_choice": {},
    "brackets_slash_inside1": {"slash_inside": "true"},
    "brackets_slash_inside2": {"slash_inside": "true"},
    "brackets_slash_inside3": {},
}
cases = []
for call in re.finditer(r"new_ec_test(?:_multiline)?\((.*?)\)", source, re.S):
    tokens = re.findall(r'"((?:\\.|[^"\\])*)"|([^\s]+)', call.group(1))
    name, fixture, path, expected = [a or b for a, b in tokens]
    path = path.replace(r"\\", "\\").replace(r'\"', '"')
    legacy = dict(re.findall(r"(\w+)=(\w+)", expected))
    cases.append({"name": name, "fixture": fixture, "path": path,
                  "expected": overrides.get(name, legacy),
                  "upstream_expected": legacy})
(root / "cases.json").write_text(json.dumps(cases, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"Prepared {len(cases)} upstream glob cases ({len(overrides)} explicit specification updates)")
