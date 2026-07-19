#!/usr/bin/env python3
"""Self-check for the manifest rewrite + the shim. Run: python3 test/test_manifest_fix.py"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "lib"))
import manifest_fix as mf  # noqa: E402


def sample():
    return {
        "manifest_version": 2,
        "name": "Test",
        "update_url": "https://clients2.google.com/...",
        "key": "ABC",
        "minimum_chrome_version": "100",
        "permissions": ["storage", "tabGroups", "debugger", "tabs"],
        "background": {"scripts": ["bg.js"], "type": "module", "persistent": True},
        "browser_specific_settings": {"safari": {"strict_max_version": "18.0"}},
        "content_scripts": [{"matches": ["<all_urls>"], "js": ["cs.js"]}],
    }


def test_rewrite():
    new, changes = mf.process(sample(), shim="shim.js")
    types = {(c["type"], c["target"]) for c in changes}

    # Chrome-only keys gone
    for k in mf.CHROME_ONLY_KEYS:
        assert k not in new, f"{k} should be stripped"
    # Unsupported perms gone, supported kept
    assert new["permissions"] == ["storage", "tabs"], new["permissions"]
    assert ("removed_permission", "tabGroups") in types
    assert ("removed_permission", "debugger") in types
    # background fixed
    assert "type" not in new["background"], "background.type:module should be stripped"
    assert new["background"]["persistent"] is False, "MV2 background must be non-persistent"
    # version cap dropped, min set
    safari = new["browser_specific_settings"]["safari"]
    assert "strict_max_version" not in safari, "max cap must be dropped"
    assert safari["strict_min_version"] == "15.4", safari
    # shim registered first
    assert new["content_scripts"][0]["js"][0] == "shim.js", "shim must run first"
    print("ok: rewrite")


def test_keep_module():
    new, _ = mf.process(sample(), keep_module=True)
    assert new["background"].get("type") == "module", "--keep-module must preserve it"
    print("ok: keep_module")


def test_mv3_and_report():
    m = {"manifest_version": 3, "name": "X", "permissions": ["sidePanel", "storage"]}
    new, changes = mf.process(m, shim="shim.js")
    assert new["manifest_version"] == 3
    assert new["permissions"] == ["storage"], "sidePanel perm stripped"
    txt = mf.analyze_report(m, changes, as_json=False)
    assert "MV3" in txt, txt
    assert "[shimmed]" in txt, "sidePanel/storage should show as shimmed"
    js = mf.analyze_report(m, changes, as_json=True)
    assert '"manifest_version": 3' in js
    print("ok: mv3_and_report")


def test_shim_aliases_storage_sync():
    with open(os.path.join(ROOT, "lib", "shim.js"), encoding="utf-8") as f:
        src = f.read()
    assert "storage.sync = api.storage.local" in src, "shim must alias storage.sync"
    for api in ["sidePanel", "identity", "notifications", "tabGroups", "offscreen", "debugger"]:
        assert api in src, f"shim must stub {api}"
    print("ok: shim_aliases")


if __name__ == "__main__":
    test_rewrite()
    test_keep_module()
    test_mv3_and_report()
    test_shim_aliases_storage_sync()
    print("\nAll checks passed.")
