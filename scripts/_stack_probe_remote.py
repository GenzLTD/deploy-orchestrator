import json, re, subprocess, urllib.request
from pathlib import Path

def health(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return json.loads(r.read().decode())
    except Exception:
        return {}

def unit_sha(path):
    p = Path(path)
    if not p.exists():
        return ""
    for line in p.read_text().splitlines():
        if line.startswith("GIT_COMMIT="):
            return line.split("=", 1)[1].strip()
    return ""

def is_active(u):
    try:
        return subprocess.check_output(
            ["systemctl", "is-active", u], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return "inactive"

def binds():
    out = subprocess.check_output(["ss", "-ltn"], text=True)
    hit = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        local = parts[3]
        for port in ("5200", "5211", "5300"):
            suf = ":" + port
            if local.endswith(suf):
                hit[port] = local[: -len(suf)]
    return hit

kit = ""
bp = Path("/home/ubuntu/106-deploy-kit/bootstrap.sh")
if bp.exists():
    m = re.search(r'KIT_VERSION="([^"]+)"', bp.read_text(errors="ignore"))
    kit = m.group(1) if m else ""

gfcc = ""
cur = Path("/home/ubuntu/gfcc-kernel/current")
if cur.exists():
    gfcc = cur.resolve().name

print(json.dumps({
    "looma_sha": health("http://127.0.0.1:5200/health").get("git_commit")
                 or unit_sha("/home/ubuntu/looma/deploy.env"),
    "core_sha": health("http://127.0.0.1:5300/health").get("git_commit")
                or unit_sha("/home/ubuntu/thomas/deploy.env"),
    "gfcc_sha": gfcc,
    "bind": binds(),
    "kit_version": kit,
    "units": {u: is_active(u) for u in ["looma-backend", "thomas-core", "gfcc-kernel", "nginx"]},
}, ensure_ascii=False))
