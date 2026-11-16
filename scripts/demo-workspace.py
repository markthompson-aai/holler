#!/usr/bin/env python3
"""Sets up (or tears down) a Herdr "demo" workspace for showing Holler.

Four small Claude agents work on throwaway projects in ~/holler-demo, each
seeded so the summary has something different to say:

  web    writes a README, then sits idle            -> "done"
  docs   translates a long guide                    -> "working"
  api    stops to ask which option you prefer       -> "waiting on you"
  infra  needs approval to run the test script      -> "blocked"

Usage:
  scripts/demo-workspace.py            print the plan (dry run)
  scripts/demo-workspace.py --run      create the projects, workspace and agents
  scripts/demo-workspace.py --teardown close the demo workspace and delete the
                                       projects, so the next --run starts fresh

Then set HOLLER_WORKSPACES=demo in .env so Holler sees only these.
This starts real Claude Code sessions on your subscription.

The first time, Claude asks whether to trust ~/holler-demo. Answer it in the
demo workspace's first tab; the script waits. Trusting the parent folder covers
every project in it, including agents Holler starts there during the demo.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path.home() / "holler-demo"
WORKSPACE = "demo"
HERDR = shutil.which("herdr") or str(Path.home() / ".local/bin/herdr")

# Claude Code flags per agent. acceptEdits lets agents write files unprompted
# while shell commands still need approval, which is what blocks "infra".
EDITS_OK = ["--permission-mode", "acceptEdits"]

PROJECTS = {
    "web": {
        "files": {
            "index.html": "<!doctype html>\n<title>Orders</title>\n<script src=app.js></script>\n",
            "app.js": "fetch('/api/orders').then(r => r.json()).then(console.log)\n",
        },
        "task": "Write a short README.md for this project: what it is, and how to open it locally. "
        "Keep it under 15 lines. Don't run any commands.",
    },
    "docs": {
        "files": {
            "guide.md": "\n\n".join(
                f"## Step {n}\n\nThis step explains part {n} of setting up the orders service, "
                "including configuration, environment variables and how to verify it worked."
                for n in range(1, 13)
            )
            + "\n",
        },
        "task": "Translate guide.md into French (guide.fr.md) and Spanish (guide.es.md). "
        "Work section by section, and after each section append one line to progress.md "
        "saying which section you finished. Don't run any commands.",
    },
    "api": {
        "files": {
            "orders.py": "def parse_order(raw):\n    qty, sku = raw.split(':')\n    return {'sku': sku, 'qty': int(qty)}\n",
        },
        "task": "parse_order() in orders.py crashes on bad input. Read it, then propose two fixes: "
        "(1) raise a ValueError with a clear message, or (2) return None and log a warning. "
        "Don't change any code yet: describe both options briefly and ask me which one I want.",
    },
    "infra": {
        "files": {
            "run_tests.sh": "#!/bin/sh\necho 'Running 42 tests...'\nsleep 1\necho 'All 42 tests passed.'\n",
            "deploy.md": "Deploys go out after ./run_tests.sh passes.\n",
        },
        "task": "Run ./run_tests.sh and tell me whether it's safe to deploy.",
    },
}


def herdr(*args, check=True):
    result = subprocess.run([HERDR, *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"herdr {' '.join(args[:2])} failed: {result.stderr or result.stdout}")
    return result.stdout


def find_key(value, key):
    """First value for `key` anywhere in parsed JSON (Herdr's shapes vary by command)."""
    if isinstance(value, dict):
        if key in value:
            return value[key]
        children = value.values()
    elif isinstance(value, list):
        children = value
    else:
        return None
    for child in children:
        found = find_key(child, key)
        if found is not None:
            return found
    return None


def demo_workspace_id():
    workspaces = json.loads(herdr("workspace", "list"))["result"]["workspaces"]
    return next((w["workspace_id"] for w in workspaces if w.get("label") == WORKSPACE), None)


def write_projects():
    for name, project in PROJECTS.items():
        directory = ROOT / name
        directory.mkdir(parents=True, exist_ok=True)
        for filename, contents in project["files"].items():
            path = directory / filename
            path.write_text(contents)
            if filename.endswith(".sh"):
                path.chmod(0o755)


def start_claude(name, pane_id, flags, tab):
    """Starts Claude in a pane. If it stops to ask whether to trust the folder,
    waits for the user to answer in Herdr; this script never answers it."""
    args = ["agent", "start", name, "--kind", "claude", "--pane", pane_id, *(["--", *flags] if flags else [])]
    result = subprocess.run([HERDR, *args], capture_output=True, text=True)
    if result.returncode == 0:
        return
    if "agent_not_ready" not in result.stdout + result.stderr:
        sys.exit(f"herdr agent start failed: {result.stderr or result.stdout}")
    print(f'Claude is asking whether to trust the folder. In Herdr, open the "{WORKSPACE}" workspace, '
          f'tab "{tab}", and choose "Yes, I trust this folder". Waiting up to 5 minutes...')
    herdr("agent", "wait", name, "--until", "idle", "--timeout", "300000")


def trust_root(pane_id, tab):
    """Opens Claude once in ~/holler-demo so the trust question comes up
    there, once, then exits it so it isn't counted as a fifth agent."""
    start_claude("demo-setup", pane_id, [], tab)
    herdr("agent", "prompt", "demo-setup", "/exit")


def plan():
    print(f"projects in {ROOT}: {', '.join(PROJECTS)}")
    print(f"herdr workspace create --label {WORKSPACE} --cwd {ROOT}")
    print(f"herdr agent start demo-setup --kind claude --pane <root pane>   # trust {ROOT} once, then /exit")
    for name, project in PROJECTS.items():
        flags = [] if name == "infra" else EDITS_OK
        print(f"herdr tab create --workspace <demo> --cwd {ROOT / name} --label {name}")
        print(f"herdr agent start {name} --kind claude --pane <new pane> -- {' '.join(flags)}".rstrip(" -"))
        print(f"herdr agent prompt {name} {project['task']!r}")


def run():
    if demo_workspace_id():
        sys.exit(f'A "{WORKSPACE}" workspace already exists; run --teardown first.')
    write_projects()
    created = json.loads(herdr("workspace", "create", "--label", WORKSPACE, "--cwd", str(ROOT)))
    workspace_id = find_key(created, "workspace_id") or demo_workspace_id()
    if not workspace_id:
        sys.exit(f"could not find the new workspace id in: {created}")
    root = created.get("result", {})
    root_pane = find_key(root.get("root_pane"), "pane_id")
    if not root_pane:
        sys.exit(f"could not find the new workspace's pane id in: {created}")
    trust_root(root_pane, find_key(root.get("tab"), "label") or "1")

    for name, project in PROJECTS.items():
        tab = json.loads(
            herdr("tab", "create", "--workspace", workspace_id, "--cwd", str(ROOT / name), "--label", name)
        )
        # The new tab's own pane; other pane ids may appear elsewhere in the reply.
        pane_id = find_key(tab.get("result", {}).get("root_pane"), "pane_id") or find_key(tab, "pane_id")
        if not pane_id:
            sys.exit(f"could not find the new pane id in: {tab}")
        flags = [] if name == "infra" else EDITS_OK
        start_claude(name, pane_id, flags, name)
        # A prompt sent the instant an agent starts can be dropped; wait for it to settle.
        herdr("agent", "wait", name, "--until", "idle", "--timeout", "30000", check=False)
        time.sleep(1)
        herdr("agent", "prompt", name, project["task"])
        print(f"started {name} in {pane_id}")
    print(f'\nDone. Set HOLLER_WORKSPACES={WORKSPACE} in .env, then ask "what are my agents up to?"')


def teardown():
    """Closes the workspace, then deletes the projects (and anything the agents
    wrote in them, including agents Holler started there). ~/holler-demo itself
    stays, so Claude still trusts it next time."""
    workspace_id = demo_workspace_id()
    if workspace_id:
        herdr("workspace", "close", workspace_id)
        print(f"closed {workspace_id}")
    else:
        print(f'no "{WORKSPACE}" workspace open')
    for name in PROJECTS:
        directory = ROOT / name
        if directory.exists():
            shutil.rmtree(directory)
            print(f"deleted {directory}")


if __name__ == "__main__":
    if "--run" in sys.argv:
        run()
    elif "--teardown" in sys.argv:
        teardown()
    else:
        plan()
        print("\n(dry run: pass --run to do it)")
