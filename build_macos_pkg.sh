#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════
#  Webiz Inventory Agent — macOS PKG Builder
#
#  Requires: Xcode Command Line Tools  (xcode-select --install)
#  Output:   dist/WebizInventory_macOS.pkg
#
#  Usage:  chmod +x build_macos_pkg.sh && ./build_macos_pkg.sh
# ════════════════════════════════════════════════════════════════════════════════

#  Values come from webiz_config.json (git-ignored, see webiz_config.example.json).
#  This script is public — never put real values here.
#  The built .pkg contains the Apps Script URL + token: distribute it internally only.
# ════════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_JSON="$SCRIPT_DIR/webiz_config.json"
if [[ ! -f "$CONFIG_JSON" ]]; then
    echo "[ERROR] $CONFIG_JSON not found — copy webiz_config.example.json and fill it in."
    exit 1
fi
_cfg() { /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CONFIG_JSON" "$1"; }
APPS_SCRIPT_URL="$(_cfg apps_script_url)"
AGENT_TOKEN="$(_cfg agent_token)"
GITHUB_RAW_URL="$(_cfg github_raw_url)"
BUILD_DIR="$SCRIPT_DIR/build_pkg"
DIST_DIR="$SCRIPT_DIR/dist"
PKG_ID="com.webiz.inventory"
PKG_VERSION="2.0"
PKG_NAME="WebizInventory_macOS"

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│   Webiz Inventory PKG Builder — macOS   │"
echo "└─────────────────────────────────────────┘"
echo ""

# ── Preflight ────────────────────────────────────────────────────────────────
for tool in pkgbuild; do
    if ! command -v "$tool" &>/dev/null; then
        echo "[ERROR] '$tool' not found. Install Xcode Command Line Tools:"
        echo "        xcode-select --install"
        exit 1
    fi
done

if [[ ! -f "$SCRIPT_DIR/inventory_agent.py" ]]; then
    echo "[ERROR] inventory_agent.py not found in $SCRIPT_DIR"
    exit 1
fi

# ── Clean build dirs ─────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/payload/usr/local/lib/WebizInventory"
mkdir -p "$BUILD_DIR/scripts"
mkdir -p "$DIST_DIR"

# ── Bundle the agent ─────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/inventory_agent.py" "$BUILD_DIR/payload/usr/local/lib/WebizInventory/"

# Bundle logo if present
[[ -f "$SCRIPT_DIR/webiz_logo.png" ]] && \
    cp "$SCRIPT_DIR/webiz_logo.png" "$BUILD_DIR/payload/usr/local/lib/WebizInventory/"

echo "[1/3] Agent bundled."

# ── Write postinstall script ─────────────────────────────────────────────────
cat > "$BUILD_DIR/scripts/postinstall" << POSTINSTALL
#!/usr/bin/env bash
# Runs as root after pkg installation. Installs per-user LaunchAgent.
set -uo pipefail

AGENT_SRC="/usr/local/lib/WebizInventory/inventory_agent.py"
APPS_SCRIPT_URL="${APPS_SCRIPT_URL}"
AGENT_TOKEN="${AGENT_TOKEN}"
GITHUB_RAW_URL="${GITHUB_RAW_URL}"
PLIST_LABEL="com.webiz.inventory"

# ── Identify the console user ────────────────────────────────────────────────
CURRENT_USER=\$(stat -f%Su /dev/console 2>/dev/null || echo "")
if [[ -z "\$CURRENT_USER" || "\$CURRENT_USER" == "root" ]]; then
    echo "postinstall: no interactive user found — skipping per-user setup."
    exit 0
fi

USER_HOME=\$(dscl . -read "/Users/\$CURRENT_USER" NFSHomeDirectory 2>/dev/null | awk '{print \$2}')
[[ -z "\$USER_HOME" ]] && USER_HOME="/Users/\$CURRENT_USER"

AGENT_DIR="\$USER_HOME/Library/Application Support/WebizInventory"
CONFIG_FILE="\$AGENT_DIR/config.json"
PLIST_DIR="\$USER_HOME/Library/LaunchAgents"
PLIST_FILE="\$PLIST_DIR/\$PLIST_LABEL.plist"

# ── Locate Python 3 with working tkinter ─────────────────────────────────────
PYTHON3=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [[ -x "\$candidate" ]]; then
        if sudo -u "\$CURRENT_USER" "\$candidate" -c \
               "import tkinter; r=tkinter.Tk(); r.destroy()" &>/dev/null; then
            PYTHON3="\$candidate"
            break
        fi
    fi
done

if [[ -z "\$PYTHON3" ]]; then
    echo "postinstall: Python 3 with tkinter not found — agent will not function."
    exit 1
fi
echo "postinstall: Using Python: \$PYTHON3"

# ── Create agent directory and config ────────────────────────────────────────
sudo -u "\$CURRENT_USER" mkdir -p "\$AGENT_DIR"

# Copy bundled files to user directory
sudo -u "\$CURRENT_USER" cp "\$AGENT_SRC" "\$AGENT_DIR/inventory_agent.py"
[[ -f /usr/local/lib/WebizInventory/webiz_logo.png ]] && \
    sudo -u "\$CURRENT_USER" cp /usr/local/lib/WebizInventory/webiz_logo.png "\$AGENT_DIR/"

sudo -u "\$CURRENT_USER" bash -c "umask 077; cat > '\$CONFIG_FILE'" << JSON
{
  "apps_script_url": "\$APPS_SCRIPT_URL",
  "agent_token":     "\$AGENT_TOKEN",
  "github_raw_url":  "\$GITHUB_RAW_URL"
}
JSON
chmod 600 "\$CONFIG_FILE"

# ── Remove the SMTP password left in the Keychain by older versions ──────────
sudo -u "\$CURRENT_USER" security delete-generic-password -s "WebizInventoryAgent" &>/dev/null || true

# ── Install LaunchAgent ───────────────────────────────────────────────────────
sudo -u "\$CURRENT_USER" mkdir -p "\$PLIST_DIR"

sudo -u "\$CURRENT_USER" bash -c "cat > '\$PLIST_FILE'" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>\${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>\${PYTHON3}</string>
        <string>\${AGENT_DIR}/inventory_agent.py</string>
    </array>

    <key>WorkingDirectory</key>
    <string>\${AGENT_DIR}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>3600</integer>

    <key>StandardOutPath</key>
    <string>\${AGENT_DIR}/launchd_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>\${AGENT_DIR}/launchd_stderr.log</string>

    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST

# ── Load the LaunchAgent ──────────────────────────────────────────────────────
sudo -u "\$CURRENT_USER" launchctl unload "\$PLIST_FILE" 2>/dev/null || true
sudo -u "\$CURRENT_USER" launchctl load -w "\$PLIST_FILE"

echo "postinstall: Webiz Inventory Agent installed for \$CURRENT_USER."
exit 0
POSTINSTALL
chmod +x "$BUILD_DIR/scripts/postinstall"

echo "[2/3] Postinstall script written."

# ── Build the PKG ─────────────────────────────────────────────────────────────
pkgbuild \
    --root       "$BUILD_DIR/payload" \
    --scripts    "$BUILD_DIR/scripts" \
    --identifier "$PKG_ID" \
    --version    "$PKG_VERSION" \
    --install-location "/" \
    "$DIST_DIR/$PKG_NAME.pkg"

echo "[3/3] Package built."
echo ""
echo "✔  Output: $DIST_DIR/$PKG_NAME.pkg"
echo ""
echo "   Distribute this file to users INTERNALLY only (it contains the endpoint token)."
echo "   Double-click to install — no setup required."
echo ""
echo "   To sign with a Developer ID (removes Gatekeeper warning):"
echo "   productsign --sign 'Developer ID Installer: YOUR NAME (TEAMID)' \\"
echo "     $DIST_DIR/$PKG_NAME.pkg $DIST_DIR/${PKG_NAME}_signed.pkg"
echo ""
