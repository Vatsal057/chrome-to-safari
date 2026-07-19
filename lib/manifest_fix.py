#!/usr/bin/env python3
"""Rewrite a WebExtension manifest.json for Safari, or report what would change.

Two modes over the same rules:
  fix (default): mutate manifest.json in place, print a change summary to stderr.
  --analyze:     print a report (text, or --json) and write nothing.

Every rule fixes a *silent* Safari failure — the extension would still install
without it, then quietly not work. Logic here is our own; the rule set mirrors
what any Chrome->Safari converter has to handle.
"""
import argparse
import json
import sys

# Chrome-only top-level keys Safari ignores or trips over.
CHROME_ONLY_KEYS = ["update_url", "key", "minimum_chrome_version"]

# Permissions Safari does not implement — kept, they show as broken grants.
UNSUPPORTED_PERMS = ["tabGroups", "offscreen", "sidePanel", "debugger"]

# chrome.* namespaces the runtime shim (lib/shim.js) emulates or stubs.
SHIMMED_APIS = ["storage.sync", "sidePanel", "identity",
                "notifications", "tabGroups", "offscreen", "debugger"]


def process(manifest, shim=None, keep_module=False, min_safari="15.4"):
    """Pure: return (new_manifest, changes). Does not mutate the input.

    changes is a list of {"type", "target", "note"} dicts.
    """
    m = json.loads(json.dumps(manifest))  # deep copy, stdlib only
    changes = []

    def note(t, target, note_):
        changes.append({"type": t, "target": target, "note": note_})

    # Chrome-only keys
    for k in CHROME_ONLY_KEYS:
        if k in m:
            del m[k]
            note("removed_key", k, "Chrome-only; Safari ignores or rejects it")

    # Background: strip type:module, force non-persistent for MV2
    bg = m.get("background")
    if isinstance(bg, dict):
        if bg.get("type") == "module" and not keep_module:
            del bg["type"]
            note("fixed_background", "background.type",
                 'removed "module" (a known cause of silent popup failures)')
        if m.get("manifest_version") == 2 and bg.get("persistent") is not False:
            bg["persistent"] = False
            note("fixed_background", "background.persistent",
                 "forced false (Safari rejects a persistent background)")

    # browser_specific_settings.safari: drop a max cap, ensure a min
    bss = m.setdefault("browser_specific_settings", {})
    safari = bss.setdefault("safari", {})
    if "strict_max_version" in safari:
        capped = safari.pop("strict_max_version")
        note("dropped_max_version", "browser_specific_settings.safari.strict_max_version",
             f"removed cap {capped!r} (an 18.* cap hides the extension on Safari 18+)")
    if "strict_min_version" not in safari:
        safari["strict_min_version"] = min_safari
        note("set_min_version", "browser_specific_settings.safari.strict_min_version",
             f"set to {min_safari}")

    # Unsupported permissions
    perms = m.get("permissions")
    if isinstance(perms, list):
        kept = [p for p in perms if p not in UNSUPPORTED_PERMS]
        for p in perms:
            if p in UNSUPPORTED_PERMS:
                note("removed_permission", p, "Safari does not implement it")
        m["permissions"] = kept

    # Register the shim as the FIRST content script in every entry
    if shim:
        cs = m.get("content_scripts")
        if isinstance(cs, list):
            for entry in cs:
                js = entry.get("js")
                if isinstance(js, list) and shim not in js:
                    js.insert(0, shim)
                    note("registered_shim", "content_scripts",
                         f"prepended {shim} so chrome.* gaps are filled first")

    return m, changes


def shimmed_present(manifest):
    """APIs the shim covers that this extension actually uses (best-effort)."""
    perms = manifest.get("permissions", []) or []
    hits = []
    for api in SHIMMED_APIS:
        top = api.split(".")[0]
        if top in perms or (top == "storage" and "storage" in perms):
            hits.append(api)
    return hits


def analyze_report(manifest, changes, as_json):
    mv = manifest.get("manifest_version", "?")
    shimmed = shimmed_present(manifest)
    removed_perms = [c["target"] for c in changes if c["type"] == "removed_permission"]
    if as_json:
        auto_fixed = [c for c in changes if c["type"] != "removed_permission"]
        return json.dumps({
            "manifest_version": mv,
            "autoFixed": len(auto_fixed),
            "removedPermissions": removed_perms,
            "shimmed": shimmed,
            "changes": changes,
        }, indent=2)
    lines = [f"Manifest version: {mv} ({'MV3' if mv == 3 else 'MV2' if mv == 2 else 'unknown'})", ""]
    if changes:
        lines.append("Will auto-fix:")
        for c in changes:
            lines.append(f"  [auto-fixed] {c['target']}: {c['note']}")
    else:
        lines.append("No manifest changes needed.")
    if shimmed:
        lines.append("")
        lines.append("Shimmed at runtime (emulated so pages don't blank):")
        for s in shimmed:
            lines.append(f"  [shimmed] chrome.{s}")
    return "\n".join(lines)


def main(argv):
    ap = argparse.ArgumentParser(description="Rewrite/analyze a manifest.json for Safari.")
    ap.add_argument("manifest")
    ap.add_argument("--analyze", action="store_true", help="report only, write nothing")
    ap.add_argument("--json", action="store_true", help="with --analyze, print JSON")
    ap.add_argument("--keep-module", action="store_true", help="keep background.type:module")
    ap.add_argument("--shim", default=None, help="shim filename to register as first content script")
    ap.add_argument("--min-safari", default="15.4")
    args = ap.parse_args(argv)

    try:
        with open(args.manifest, encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: cannot read manifest {args.manifest}: {e}", file=sys.stderr)
        return 1

    new_manifest, changes = process(
        manifest, shim=args.shim, keep_module=args.keep_module, min_safari=args.min_safari)

    if args.analyze:
        print(analyze_report(manifest, changes, args.json))
        return 0

    with open(args.manifest, "w", encoding="utf-8") as f:
        json.dump(new_manifest, f, indent=2)
        f.write("\n")
    for c in changes:
        print(f"    fixed: {c['target']} — {c['note']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
