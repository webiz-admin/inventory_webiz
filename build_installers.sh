#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════
#  Webiz Inventory Agent — Installer Builder (macOS .sh, Linux .sh, Windows .ps1)
#
#  The scripts in the repo are PUBLIC and contain only placeholders.
#  This stamps the real values from webiz_config.json (git-ignored) into dist/.
#  dist/ is git-ignored too — distribute those files INTERNALLY only.
#
#  Usage:  ./build_installers.sh
#  (macOS .pkg → build_macos_pkg.sh,  Windows .exe → Build_Windows_EXE.cmd)
# ════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_JSON="$SCRIPT_DIR/webiz_config.json"
DIST_DIR="$SCRIPT_DIR/dist"

if [[ ! -f "$CONFIG_JSON" ]]; then
    echo "[ERROR] $CONFIG_JSON not found — copy webiz_config.example.json and fill it in."
    exit 1
fi

mkdir -p "$DIST_DIR"

python3 - "$CONFIG_JSON" "$SCRIPT_DIR" "$DIST_DIR" <<'PY'
import json, sys
from pathlib import Path

cfg = json.load(open(sys.argv[1]))
src, dist = Path(sys.argv[2]), Path(sys.argv[3])

url, token = cfg["apps_script_url"], cfg["agent_token"]
if not url.startswith("https://script.google.com/"):
    sys.exit("[ERROR] apps_script_url must be an https://script.google.com/ URL")
if len(token) < 32 or "__WEBIZ_" in token:
    sys.exit("[ERROR] agent_token must be a random string of at least 32 characters")

for name in ("WebizInventory_macOS.sh", "WebizInventory_Linux.sh", "WebizInventory_Windows.ps1"):
    data = (src / name).read_bytes()   # bytes: keeps BOM / CRLF of the .ps1 intact
    for placeholder, value in ((b"__WEBIZ_APPS_SCRIPT_URL__", url), (b"__WEBIZ_AGENT_TOKEN__", token)):
        if data.count(placeholder) != 1:
            sys.exit(f"[ERROR] {name}: expected exactly one {placeholder.decode()}")
        data = data.replace(placeholder, value.encode())
    out = dist / name
    out.write_bytes(data)
    out.chmod(0o755 if name.endswith(".sh") else 0o644)
    print(f"  ✔  {out}")
PY

cp "$SCRIPT_DIR/WebizInventory_Windows.cmd" "$DIST_DIR/"
echo ""
echo "Done. Distribute the files in dist/ internally — they contain the endpoint token."
