#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════
#  Webiz Inventory Agent — macOS Installer
#  Single-file: just run this once.  Everything else is automatic.
#
#  Usage:  chmod +x WebizInventory_macOS.sh && ./WebizInventory_macOS.sh
# ════════════════════════════════════════════════════════════════════════════════

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
# This file is PUBLIC — never put real values here. build_installers.sh stamps
# them from webiz_config.json into dist/WebizInventory_macOS.sh.
# Emails are sent by the Apps Script; the agent holds no SMTP secret.
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

set -uo pipefail   # note: -e removed so we can show real errors before exiting

# ── Error trap: show what failed and keep window open ────────────────────────
_die() {
    local line="$1"
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✗  Installation failed (line $line)                    "
    echo "║     Check the error above, fix it, and re-run.          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    read -rp "Press Enter to close…" _
    exit 1
}
trap '_die $LINENO' ERR

AGENT_DIR="$HOME/Library/Application Support/WebizInventory"
AGENT_FILE="$AGENT_DIR/inventory_agent.py"
CONFIG_FILE="$AGENT_DIR/config.json"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.webiz.inventory"
PLIST_FILE="$PLIST_DIR/$PLIST_LABEL.plist"

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│   Webiz Inventory Agent – macOS Setup   │"
echo "└─────────────────────────────────────────┘"
echo ""

# ── Step 1: Python 3 with a working tkinter (auto-installed if missing) ──────
echo "[1/5] Checking Python 3…"

# Official python.org build: universal2, bundles a Tcl/Tk that works on current macOS.
PY_VERSION="3.13.15"
PY_PKG_URL="https://www.python.org/ftp/python/${PY_VERSION}/python-${PY_VERSION}-macos11.pkg"
PY_FWK="/Library/Frameworks/Python.framework/Versions/${PY_VERSION%.*}"
PSF_SIGNER="Developer ID Installer: Python Software Foundation (BMM5U3QVKW)"

# Must actually open a window: Apple's system Python imports tkinter fine but
# aborts ("Abort trap: 6") on Tk() under macOS 26+. The nested subshell keeps
# the shell's job-control message out of the terminal.
_tkinter_works() {
    { ( "$1" -c "import tkinter; r=tkinter.Tk(); r.destroy()" 2>/dev/null ); } 2>/dev/null
}

_find_python() {
    local c candidates=("$PY_FWK/bin/python3" /usr/local/bin/python3 /opt/homebrew/bin/python3)
    # /usr/bin/python3 is only a stub that pops up the Xcode tools dialog unless they are installed
    xcode-select -p &>/dev/null && candidates+=(/usr/bin/python3)
    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]] && _tkinter_works "$c"; then echo "$c"; return 0; fi
    done
    return 1
}

_install_python_org() {
    local tmp sig
    tmp=$(mktemp -d)
    echo "      Downloading Python ${PY_VERSION} from python.org…"
    if ! curl -fsSL --retry 3 --connect-timeout 15 "$PY_PKG_URL" -o "$tmp/python.pkg"; then
        echo "      Download failed."; rm -rf "$tmp"; return 1
    fi
    # Only install a package signed by the PSF and notarized by Apple
    sig=$(pkgutil --check-signature "$tmp/python.pkg" 2>/dev/null || true)
    if [[ "$sig" != *"$PSF_SIGNER"* ]] || ! spctl --assess --type install "$tmp/python.pkg" &>/dev/null; then
        echo "      [ERROR] Python installer signature check failed — not installing."
        rm -rf "$tmp"; return 1
    fi
    # Don't let the installer edit the user's shell profile
    printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><dict><key>attributeSetting</key><integer>0</integer><key>choiceAttribute</key><string>selected</string><key>choiceIdentifier</key><string>org.python.Python.PythonProfileChanges-'"${PY_VERSION%.*}"'</string></dict></array></plist>' > "$tmp/choices.xml"
    echo "      Installing Python ${PY_VERSION} (administrator password required)…"
    if ! sudo installer -pkg "$tmp/python.pkg" -target / -applyChoiceChangesXML "$tmp/choices.xml" >/dev/null; then
        echo "      [ERROR] Python installation failed (is this account an administrator?)."
        rm -rf "$tmp"; return 1
    fi
    # python.org builds ship without CA certificates — use the macOS system bundle
    sudo ln -sf /etc/ssl/cert.pem "$PY_FWK/etc/openssl/cert.pem"
    rm -rf "$tmp"
}

if PYTHON3=$(_find_python); then
    echo "      Found: $PYTHON3  ($("$PYTHON3" --version 2>&1))"
else
    echo "      No Python 3 with a working tkinter found — installing automatically."
    if ! _install_python_org || ! PYTHON3=$(_find_python); then
        echo ""
        echo "  [ERROR] Could not install Python automatically."
        echo "  Install it manually from https://www.python.org/downloads/macos/ and re-run,"
        echo "  or contact IT."
        exit 1
    fi
    echo "      Installed: $PYTHON3"
fi
echo "      Python + tkinter: OK"

# ── Step 2: Download the agent ────────────────────────────────────────────────
echo ""
echo "[2/5] Downloading inventory agent from GitHub…"
echo "      URL: $GITHUB_RAW_URL"
mkdir -p "$AGENT_DIR"

DOWNLOAD_OK=false
if command -v curl &>/dev/null; then
    # -f: fail on HTTP errors  -L: follow redirects  --retry 3: retry on network glitch
    # -v removed from -s so errors print to terminal
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

# Validate: file must exist and not be empty HTML (GitHub 404 page)
if [[ ! -s "$AGENT_FILE" ]]; then
    echo "  [ERROR] Downloaded file is empty."
    exit 1
fi
if head -1 "$AGENT_FILE" | grep -qi "<!DOCTYPE\|<html"; then
    echo "  [ERROR] GitHub returned an HTML page instead of the Python file."
    echo "  The URL is probably wrong or the repo/file does not exist yet:"
    echo "  $GITHUB_RAW_URL"
    rm -f "$AGENT_FILE"
    exit 1
fi

chmod +x "$AGENT_FILE"
echo "      ✔  Agent saved to: $AGENT_FILE"

# ── Step 3: Write config & store credentials securely ────────────────────────
echo ""
echo "[3/5] Writing configuration…"

# Remove the SMTP password left in the Keychain by older versions
security delete-generic-password -s "WebizInventoryAgent" &>/dev/null || true

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

# ── Step 4: First manual run ──────────────────────────────────────────────────
echo ""
echo "[4/5] Running agent for the first time…"
"$PYTHON3" "$AGENT_FILE" --force || true   # --force bypasses 6-month guard on manual/re-runs

# ── Step 5: Install LaunchAgent ───────────────────────────────────────────────
echo ""
echo "[5/5] Installing LaunchAgent (runs at every login)…"
mkdir -p "$PLIST_DIR"

cat > "$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON3}</string>
        <string>${AGENT_FILE}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${AGENT_DIR}</string>

    <!-- Run at login, then repeat every hour so the 24-h cancel retry fires reliably -->
    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>3600</integer>

    <key>StandardOutPath</key>
    <string>${AGENT_DIR}/launchd_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${AGENT_DIR}/launchd_stderr.log</string>

    <!-- Only launch when a GUI session is active -->
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST

# Unload any existing version, then load new one
launchctl unload "$PLIST_FILE" 2>/dev/null || true
launchctl load -w "$PLIST_FILE"

# ── Ad-hoc code signing (prevents Gatekeeper quarantine) ─────────────────────
echo ""
echo "      Signing agent script (ad-hoc)…"
if command -v codesign &>/dev/null; then
    codesign --force --sign - "$AGENT_FILE" 2>/dev/null && \
        echo "      Signed: $AGENT_FILE" || \
        echo "      [WARN] codesign failed — agent will still run."
else
    echo "      [WARN] codesign not found (Xcode CLT not installed). Skipping signing."
fi

# Clear quarantine flag from this installer script itself
xattr -r -d com.apple.quarantine "$AGENT_FILE" 2>/dev/null || true

echo ""
echo "✔  Installation complete."
echo ""
echo "   The agent runs silently at every login."
echo "   It shows the form only when 6 months have passed since the last check-in."
echo ""
echo "   Useful commands:"
echo "   launchctl list | grep webiz            # check if loaded"
echo "   launchctl start $PLIST_LABEL           # trigger manually"
echo "   tail -f \"$AGENT_DIR/agent.log\"        # live log"
echo ""
echo "   To uninstall:"
echo "   launchctl unload ~/Library/LaunchAgents/$PLIST_LABEL.plist"
echo "   rm ~/Library/LaunchAgents/$PLIST_LABEL.plist"
echo ""
read -rp "Press Enter to close…" _
