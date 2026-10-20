#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════
#  Webiz Inventory Agent — Linux Installer
#  Single-file: just run this once.  Everything else is automatic.
#
#  Usage:  chmod +x WebizInventory_Linux.sh && ./WebizInventory_Linux.sh
#  Note:   Does NOT require root.  dmidecode (serial number) needs sudo — the
#          script configures a passwordless sudoers rule automatically.
# ════════════════════════════════════════════════════════════════════════════════

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
# This file is PUBLIC — never put real values here. build_installers.sh stamps
# them from webiz_config.json into dist/WebizInventory_Linux.sh.
APPS_SCRIPT_URL="__WEBIZ_APPS_SCRIPT_URL__"
AGENT_TOKEN="__WEBIZ_AGENT_TOKEN__"
GITHUB_RAW_URL="https://raw.githubusercontent.com/webiz-admin/inventory_webiz/main/inventory_agent.py"
# ─────────────────────────────────────────────────────────────────────────────

# Refuse to run an unbuilt copy (values are stamped by build_installers.sh)
if [[ "$APPS_SCRIPT_URL" == __WEBIZ_* || "$AGENT_TOKEN" == __WEBIZ_* ]]; then
    echo "[ERROR] This installer has not been built. Run build_installers.sh and"
    echo "        distribute the copy from dist/ instead."
    exit 1
fi

set -uo pipefail   # -e removed so we can show real errors before exiting

# ── Error trap: show what failed and keep terminal open ──────────────────────
_die() {
    local line="$1"
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✗  Installation failed (line $line)                    "
    echo "║     Check the error above, fix it, and re-run.          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
}
trap '_die $LINENO' ERR

AGENT_DIR="$HOME/.webiz_inventory"
AGENT_FILE="$AGENT_DIR/inventory_agent.py"
CONFIG_FILE="$AGENT_DIR/config.json"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="webiz-inventory"

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│   Webiz Inventory Agent – Linux Setup   │"
echo "└─────────────────────────────────────────┘"
echo ""

# ── Step 1: Locate Python 3 ───────────────────────────────────────────────────
echo "[1/6] Locating Python 3…"
PYTHON3=""
for candidate in python3 python; do
    if command -v "$candidate" &>/dev/null; then
        ver=$("$candidate" --version 2>&1 || true)
        if [[ "$ver" == Python\ 3* ]]; then
            PYTHON3=$(command -v "$candidate")
            echo "      Found: $PYTHON3  ($ver)"
            break
        fi
    fi
done

if [[ -z "$PYTHON3" ]]; then
    echo "      Python 3 not found — attempting to install…"
    if   command -v apt-get &>/dev/null; then sudo apt-get install -y python3
    elif command -v dnf     &>/dev/null; then sudo dnf install -y python3
    elif command -v pacman  &>/dev/null; then sudo pacman -S --noconfirm python
    else
        echo "  [ERROR] Cannot auto-install Python 3. Please install it manually."
        exit 1
    fi
    PYTHON3=$(command -v python3)
fi

# Check tkinter
echo "      Checking tkinter…"
if ! "$PYTHON3" -c "import tkinter" 2>/dev/null; then
    echo "      tkinter missing — installing…"
    if   command -v apt-get &>/dev/null; then sudo apt-get install -y python3-tk
    elif command -v dnf     &>/dev/null; then sudo dnf install -y python3-tkinter
    elif command -v pacman  &>/dev/null; then sudo pacman -S --noconfirm tk
    else
        echo "  [WARN] Could not auto-install tkinter. Install python3-tk manually."
    fi
fi
echo "      Python + tkinter: OK"

# ── Step 2: Configure sudo for dmidecode (hardware serial number) ─────────────
echo ""
echo "[2/6] Configuring sudo for dmidecode (serial number collection)…"
# Only these exact read-only queries are allowed. An unrestricted dmidecode rule
# is a root escalation (e.g. --dump-bin writes arbitrary files as root).
DMI=$(PATH="$PATH:/usr/sbin:/sbin" command -v dmidecode || echo /usr/sbin/dmidecode)
SUDOERS_LINE="$USER ALL=(root) NOPASSWD: $DMI -s system-manufacturer, $DMI -s system-product-name, $DMI -s system-serial-number"
SUDOERS_FILE="/etc/sudoers.d/webiz-inventory"
SUDOERS_TMP=$(mktemp)
echo "$SUDOERS_LINE" > "$SUDOERS_TMP"
# Validate with visudo before installing so a bad rule can never break sudo
if sudo visudo -cf "$SUDOERS_TMP" &>/dev/null && \
   sudo install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE" 2>/dev/null; then
    echo "      Sudoers rule created: $SUDOERS_FILE"
else
    echo "      [WARN] Could not create sudoers rule. Serial Number may show as N/A."
    echo "             Rule needed in $SUDOERS_FILE:"
    echo "             $SUDOERS_LINE"
fi
rm -f "$SUDOERS_TMP"

# ── Step 3: Download the agent ────────────────────────────────────────────────
echo ""
echo "[3/6] Downloading inventory agent from GitHub…"
echo "      URL: $GITHUB_RAW_URL"
mkdir -p "$AGENT_DIR"

DOWNLOAD_OK=false
if command -v curl &>/dev/null; then
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
            "$GITHUB_RAW_URL" -o "$AGENT_FILE" 2>&1; then
        DOWNLOAD_OK=true
    fi
fi

if [[ "$DOWNLOAD_OK" == false ]] && command -v wget &>/dev/null; then
    echo "      curl failed — trying wget…"
    if wget --tries=3 --timeout=15 "$GITHUB_RAW_URL" -O "$AGENT_FILE" 2>&1; then
        DOWNLOAD_OK=true
    fi
fi

if [[ "$DOWNLOAD_OK" == false ]]; then
    echo "      curl/wget failed — trying Python urllib…"
    "$PYTHON3" -c "
import urllib.request, sys
try:
    urllib.request.urlretrieve('$GITHUB_RAW_URL', '$AGENT_FILE')
    print('      Downloaded via Python urllib.')
except Exception as e:
    print(f'      urllib failed: {e}', file=sys.stderr)
    sys.exit(1)
" && DOWNLOAD_OK=true
fi

if [[ "$DOWNLOAD_OK" == false ]]; then
    echo ""
    echo "  [ERROR] Could not download inventory_agent.py."
    echo "  Possible causes:"
    echo "    • GitHub repo is private — make it public or check the URL"
    echo "    • File not yet pushed to the repo"
    echo "    • No internet connection"
    echo "  URL tried: $GITHUB_RAW_URL"
    exit 1
fi

if [[ ! -s "$AGENT_FILE" ]]; then
    echo "  [ERROR] Downloaded file is empty."
    exit 1
fi
if head -1 "$AGENT_FILE" | grep -qi "<!DOCTYPE\|<html"; then
    echo "  [ERROR] GitHub returned an HTML page — repo/file may not exist yet."
    echo "  URL: $GITHUB_RAW_URL"
    rm -f "$AGENT_FILE"
    exit 1
fi

chmod +x "$AGENT_FILE"
echo "      ✔  Agent saved to: $AGENT_FILE"

# ── Step 4: Write config ──────────────────────────────────────────────────────
echo ""
echo "[4/6] Writing configuration…"
( umask 077
cat > "$CONFIG_FILE" <<JSON
{
  "apps_script_url": "$APPS_SCRIPT_URL",
  "agent_token":     "$AGENT_TOKEN",
  "github_raw_url":  "$GITHUB_RAW_URL"
}
JSON
)
chmod 600 "$CONFIG_FILE"
echo "      Config (owner-only): $CONFIG_FILE"

# ── Step 5: First manual run ──────────────────────────────────────────────────
echo ""
echo "[5/6] Running agent for the first time…"
DISPLAY="${DISPLAY:-:0}" "$PYTHON3" "$AGENT_FILE" || true

# ── Step 6: Install systemd user service + timer ─────────────────────────────
echo ""
echo "[6/6] Installing systemd user service and timer…"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Webiz Inventory Agent
After=graphical-session.target network-online.target
Wants=graphical-session.target

[Service]
Type=oneshot
# 90-second delay so the desktop session is fully ready
ExecStartPre=-/usr/bin/env sleep 90
ExecStart=${PYTHON3} ${AGENT_FILE}
WorkingDirectory=${AGENT_DIR}
Environment=DISPLAY=:0
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical-session.target
EOF

# Timer: fires at login + re-checks once daily (agent exits immediately if < 6 months)
cat > "$UNIT_DIR/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Webiz Inventory Agent – 6-month check-in timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable lingering so user units survive logout (needed if the user has no active session)
loginctl enable-linger "$USER" 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now "${SERVICE_NAME}.timer"
systemctl --user enable "${SERVICE_NAME}.service"

# ── GPG signing (optional, requires gpg) ─────────────────────────────────────
if command -v gpg &>/dev/null; then
    echo ""
    echo "      GPG found — signing agent script…"
    gpg --batch --yes --armor --detach-sign "$AGENT_FILE" 2>/dev/null && \
        echo "      Signature: ${AGENT_FILE}.asc" || \
        echo "      [WARN] GPG signing failed (no default key?). Agent will still run."
fi

echo ""
echo "✔  Installation complete."
echo ""
echo "   The agent runs at every login via systemd timer."
echo "   It shows the form only when 6 months have passed since the last check-in."
echo ""
echo "   Useful commands:"
echo "   systemctl --user status  ${SERVICE_NAME}.timer    # check timer status"
echo "   systemctl --user start   ${SERVICE_NAME}.service  # trigger manually"
echo "   journalctl --user -u     ${SERVICE_NAME}.service  # view logs"
echo "   tail -f ${AGENT_DIR}/agent.log                     # live log"
echo ""
echo "   To uninstall:"
echo "   systemctl --user disable --now ${SERVICE_NAME}.timer ${SERVICE_NAME}.service"
echo "   rm ~/.config/systemd/user/${SERVICE_NAME}.*"
echo "   sudo rm /etc/sudoers.d/webiz-inventory"
echo ""
