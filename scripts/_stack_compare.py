import json, os, sys

lock = json.load(open(os.environ["STACK_LOCK_PATH"]))
got = json.loads(sys.stdin.read())
want = {
    "looma": lock["components"]["looma"]["sha"],
    "thomas": lock["components"]["thomas"]["sha"],
    "gfcc": lock["components"]["gfcc"]["sha"],
    "kit": lock["kit"]["version"],
}

def match(w, g):
    if not w or not g:
        return False
    return g.startswith(w[:7]) or w.startswith(g[:7]) or g == w

print("=== 106 stack status ===")
print(json.dumps(got, indent=2, ensure_ascii=False))
print()
print("| 组件 | 清单 | 现网 | |")
print("|---|---|---|---|")
ok = True
for name, key in (("looma", "looma_sha"), ("thomas", "core_sha"), ("gfcc", "gfcc_sha")):
    w = want[name]
    g = got.get(key, "")
    good = match(w, g)
    ok = ok and good
    ws = (w[:12] + "…") if len(w) > 12 else w
    gs = (g[:12] + "…") if g and len(g) > 12 else (g or "?")
    print(f"| {name} | `{ws}` | `{gs}` | {'OK' if good else 'DRIFT'} |")

# Surface mislabel if health/dir disagree with pin
if got.get("core_pin_file") or got.get("core_release_dir"):
    print()
    print("thomas provenance:")
    print(f"  pin_file:     {got.get('core_pin_file') or '?'}")
    print(f"  health.git:   {got.get('core_health_git_commit') or '?'}")
    print(f"  release_dir:  {got.get('core_release_dir') or '?'}")
    pin = got.get("core_pin_file") or ""
    label = got.get("core_release_dir") or ""
    hg = got.get("core_health_git_commit") or ""
    if pin and label and not (label.startswith(pin[:7]) or pin.startswith(label[:7])):
        print("  note: release_dir label != code pin (known looma-tree mislabel)")
    if pin and hg and not match(pin, hg):
        print("  note: /health.git_commit != THOMAS_CORE_PIN (treat pin as authority)")

kit_ok = got.get("kit_version") == want["kit"]
ok = ok and kit_ok
print(f"| kit | `{want['kit']}` | `{got.get('kit_version') or '?'}` | {'OK' if kit_ok else 'DRIFT'} |")

print()
print("binds:", got.get("bind"))
for port in ("5200", "5211", "5300"):
    gotb = (got.get("bind") or {}).get(port, "")
    if gotb in ("127.0.0.1", "::1"):
        print(f"  :{port} {gotb} OK")
    elif gotb in ("0.0.0.0", "*", "::"):
        print(f"  :{port} {gotb} WARN（期望 127.0.0.1）— stack 对齐项 A")
        ok = False
    else:
        print(f"  :{port} {gotb or 'missing'} WARN")
        ok = False

sys.exit(0 if ok else 2)
