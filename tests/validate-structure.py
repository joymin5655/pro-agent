#!/usr/bin/env python3
"""Structure checks for the pro-agent plugin (stdlib only)."""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
errors = []


def fail(msg):
    errors.append(msg)
    print("FAIL " + msg)


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def frontmatter(path):
    """Parse simple `key: value` frontmatter; strips one layer of quotes."""
    text = read(path)
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        fail("%s: missing frontmatter" % path)
        return {}
    data = {}
    for line in m.group(1).split("\n"):
        k, sep, v = line.partition(":")
        if not sep:
            continue
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        data[k.strip()] = v
    return data


# manifests
plugin = marketplace = {}
try:
    plugin = json.loads(read(".claude-plugin/plugin.json"))
    marketplace = json.loads(read(".claude-plugin/marketplace.json"))
except (OSError, ValueError) as e:
    fail("manifest parse error: %s" % e)

if plugin.get("name") != "pro-agent":
    fail("plugin name must be pro-agent")
if not re.match(r"^\d+\.\d+\.\d+$", str(plugin.get("version", ""))):
    fail("plugin version is not semver")
mp_plugins = marketplace.get("plugins") or [{}]
versions = {plugin.get("version"), marketplace.get("metadata", {}).get("version"),
            mp_plugins[0].get("version")}
if len(versions) != 1:
    fail("versions differ across manifests: %s" % sorted(map(str, versions)))
if mp_plugins[0].get("source") != "./":
    fail("marketplace plugin source must be ./")

# agents
expected_models = {"scout": "haiku", "reviewer": "sonnet", "judge": "opus"}
for name, model in expected_models.items():
    path = "agents/%s.md" % name
    if not os.path.exists(os.path.join(ROOT, path)):
        fail("missing " + path)
        continue
    fm = frontmatter(path)
    for key in ("name", "description", "model"):
        if not fm.get(key):
            fail("%s: missing %s" % (path, key))
    if fm.get("name") != name:
        fail("%s: name must be %s" % (path, name))
    if fm.get("model") != model:
        fail("%s: model must be %s, got %s" % (path, model, fm.get("model")))
    tools = [t.strip() for t in fm.get("tools", "").split(",") if t.strip()]
    for bad in ("Edit", "Write", "Bash"):
        if bad in tools:
            fail("%s: tools must not include %s" % (path, bad))

# skills
for name in ("setup", "plan", "do", "check", "decide", "research", "save"):
    path = "skills/%s/SKILL.md" % name
    if not os.path.exists(os.path.join(ROOT, path)):
        fail("missing " + path)
        continue
    fm = frontmatter(path)
    if fm.get("name") != name:
        fail("%s: name must equal directory (%s)" % (path, name))
    if not fm.get("description"):
        fail("%s: missing description" % path)
    if len(fm.get("description", "")) + len(fm.get("when_to_use", "")) > 1536:
        fail("%s: description + when_to_use over 1536 chars" % path)
    if name == "setup" and fm.get("disable-model-invocation") != "true":
        fail("setup must set disable-model-invocation: true")

# hooks
try:
    hooks = json.loads(read("hooks/hooks.json"))
    for event, groups in hooks.get("hooks", {}).items():
        for group in groups:
            for h in group.get("hooks", []):
                cmd = h.get("command", "")
                for rel in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\s\"]+)", cmd):
                    if not os.path.exists(os.path.join(ROOT, rel)):
                        fail("hooks.json (%s) references missing %s" % (event, rel))
except (OSError, ValueError) as e:
    fail("hooks.json error: %s" % e)

# rules
try:
    n = len(read("rules/operating-rules.md").splitlines())
    if n > 40:
        fail("rules/operating-rules.md has %d lines (max 40)" % n)
except OSError:
    fail("missing rules/operating-rules.md")

if errors:
    print("%d failure(s)" % len(errors))
    sys.exit(1)
print("structure OK")
