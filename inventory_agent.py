#!/usr/bin/env python3
"""
Webiz Inventory Agent v2.0
Cross-platform (macOS + Linux) — zero pip dependencies.
Config is loaded from config.json in the state dir (written by the installer):
  macOS: ~/Library/Application Support/WebizInventory/config.json
  Linux: ~/.webiz_inventory/config.json

SECURITY: this file is published in a public repo and self-updates from it.
Never put URLs, tokens or passwords here — they live only in config.json.
Emails are sent server-side by the Apps Script; the agent holds no SMTP secret.
"""

import os, sys, json, platform, subprocess, datetime, hashlib, socket, re, time, argparse
import urllib.request, urllib.error
from pathlib import Path
import tkinter as tk
from tkinter import ttk, messagebox
import logging

# ─── Paths ────────────────────────────────────────────────────────────────────
_sys = platform.system()
if _sys == "Darwin":
    STATE_DIR = Path.home() / "Library" / "Application Support" / "WebizInventory"
else:
    STATE_DIR = Path.home() / ".webiz_inventory"

CONFIG_FILE = STATE_DIR / "config.json"
STATE_FILE  = STATE_DIR / "state.json"
QUEUE_FILE  = STATE_DIR / "queue.json"
LOG_FILE    = STATE_DIR / "agent.log"
STATE_DIR.mkdir(parents=True, exist_ok=True)

# ─── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ]
)
log = logging.getLogger("webiz")

# ─── Config ───────────────────────────────────────────────────────────────────
_cfg: dict = {}
if CONFIG_FILE.exists():
    try:
        _cfg = json.loads(CONFIG_FILE.read_text())
    except Exception:
        pass

APPS_SCRIPT_URL  = _cfg.get("apps_script_url", "")
AGENT_TOKEN      = _cfg.get("agent_token", "")
GITHUB_RAW_URL   = _cfg.get("github_raw_url", "")

INTERVAL_MONTHS  = 6
CANCEL_RETRY_H   = 24

def _purge_legacy_secret():
    """Older versions stored the SMTP password in the macOS Keychain — remove it."""
    if _sys != "Darwin":
        return
    try:
        r = subprocess.run(
            ["security", "delete-generic-password", "-s", "WebizInventoryAgent"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            log.info("Removed legacy SMTP password from Keychain.")
    except Exception:
        pass

PROJECTS = ["Webiz ERP", "Fundbox", "Playtika", "Artlist", "The5%ers", "Other"]

BRAND_COLOR  = "#1A2B5A"
ACCENT_COLOR = "#E8303A"
BG_COLOR     = "#F5F7FA"

# ─── State ────────────────────────────────────────────────────────────────────
def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    except Exception:
        return {}

def save_state(state: dict):
    STATE_FILE.write_text(json.dumps(state, indent=2))

# ─── 6-month + 24 h guard ─────────────────────────────────────────────────────
def _months_diff(d1: datetime.datetime, d2: datetime.datetime) -> float:
    return (d2.year - d1.year) * 12 + d2.month - d1.month + (d2.day - d1.day) / 30.0

def should_show_form(state: dict) -> bool:
    now = datetime.datetime.now()

    last_run = state.get("last_run")
    if last_run:
        diff = _months_diff(datetime.datetime.fromisoformat(last_run), now)
        if diff < INTERVAL_MONTHS:
            log.info(f"Last check-in {diff:.1f} months ago — not due yet. Exiting.")
            return False

    cancelled_at = state.get("cancelled_at")
    if cancelled_at:
        diff_h = (now - datetime.datetime.fromisoformat(cancelled_at)).total_seconds() / 3600
        if diff_h < CANCEL_RETRY_H:
            log.info(f"Cancelled {diff_h:.1f} h ago — retry window not reached. Exiting.")
            return False

    return True

# ─── Self-update ──────────────────────────────────────────────────────────────
def self_update():
    if not GITHUB_RAW_URL:
        return
    try:
        log.info("Checking for updates…")
        if not GITHUB_RAW_URL.startswith("https://"):
            log.warning("Update check skipped: github_raw_url must be https.")
            return
        req  = urllib.request.Request(GITHUB_RAW_URL, headers={"Cache-Control": "no-cache"})
        resp = urllib.request.urlopen(req, timeout=8)
        new_bytes = resp.read()
        me = Path(sys.argv[0])
        if hashlib.sha256(new_bytes).hexdigest() != hashlib.sha256(me.read_bytes()).hexdigest():
            # Never replace a working agent with something that is not a valid agent
            # (truncated download, HTML error page, wrong file).
            if b"Webiz Inventory Agent" not in new_bytes:
                log.warning("Update rejected: downloaded file is not the inventory agent.")
                return
            try:
                compile(new_bytes, str(me), "exec")
            except SyntaxError as e:
                log.warning(f"Update rejected: downloaded file does not compile ({e}).")
                return
            log.info("Update found — applying and restarting.")
            me.write_bytes(new_bytes)
            os.execv(sys.executable, [sys.executable] + sys.argv)
    except Exception as e:
        log.warning(f"Update check skipped: {e}")

# ─── Hardware collection ──────────────────────────────────────────────────────
def _run(cmd: list, sudo: bool = False) -> str:
    try:
        if sudo:
            cmd = ["sudo", "-n"] + cmd
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return r.stdout.strip()
    except Exception:
        return ""

def _clean(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip()) or "N/A"

def get_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return "N/A"

def collect_hardware() -> dict:
    hw = {
        "hostname":   socket.gethostname(),
        "ip_address": get_ip(),
    }

    if _sys == "Darwin":
        raw = _run(["system_profiler", "SPHardwareDataType"])

        def _e(label: str) -> str:
            m = re.search(rf"{label}:\s*(.+)", raw, re.IGNORECASE)
            return _clean(m.group(1)) if m else "N/A"

        hw["brand"]         = "Apple"
        hw["model"]         = _e("Model Name") or _e("Model Identifier")
        hw["serial_number"] = _e(r"Serial Number \(system\)") or _e("Serial Number")
        hw["cpu"]           = _run(["sysctl", "-n", "machdep.cpu.brand_string"]) or _e("Chip")
        ram_b               = int(_run(["sysctl", "-n", "hw.memsize"]) or 0)
        hw["ram"]           = f"{round(ram_b / 1024**3)} GB" if ram_b else _e("Memory")
        df                  = _run(["df", "-Hl", "/"])
        lines               = df.splitlines()
        hw["storage"]       = lines[1].split()[1] if len(lines) > 1 else "N/A"
        hw["os"]            = f"macOS {platform.mac_ver()[0]}"

    else:  # Linux
        def _dmi(key: str) -> str:
            # Try sudo dmidecode first, then /sys fallback
            out = _run(["dmidecode", "-s", key], sudo=True)
            if not out:
                out = _run(["dmidecode", "-s", key])
            if not out:
                _sys_map = {
                    "system-manufacturer":  "/sys/class/dmi/id/sys_vendor",
                    "system-product-name":  "/sys/class/dmi/id/product_name",
                    "system-serial-number": "/sys/class/dmi/id/product_serial",
                }
                try:
                    out = Path(_sys_map[key]).read_text().strip()
                except Exception:
                    pass
            return _clean(out)

        hw["brand"]         = _dmi("system-manufacturer")
        hw["model"]         = _dmi("system-product-name")
        hw["serial_number"] = _dmi("system-serial-number")

        cpu_raw = _run(["cat", "/proc/cpuinfo"])
        m = re.search(r"model name\s*:\s*(.+)", cpu_raw)
        hw["cpu"] = _clean(m.group(1)) if m else "N/A"

        mem_raw = _run(["cat", "/proc/meminfo"])
        m = re.search(r"MemTotal:\s*(\d+)", mem_raw)
        hw["ram"] = f"{round(int(m.group(1)) / 1024**2)} GB" if m else "N/A"

        blk = _run(["lsblk", "-d", "-o", "NAME,SIZE,MODEL", "--noheadings"])
        hw["storage"] = _clean(blk.splitlines()[0]) if blk else "N/A"
        hw["os"]      = f"Linux {platform.release()}"

    hw["timestamp"] = datetime.datetime.now().isoformat(timespec="seconds")
    return hw

# ─── Offline queue ────────────────────────────────────────────────────────────
def _enqueue(payload: dict):
    items: list = []
    if QUEUE_FILE.exists():
        try:
            items = json.loads(QUEUE_FILE.read_text())
        except Exception:
            pass
    items.append(payload)
    QUEUE_FILE.write_text(json.dumps(items, indent=2))
    log.info(f"Saved to offline queue (total queued: {len(items)})")

def flush_queue():
    if not QUEUE_FILE.exists():
        return
    try:
        items: list = json.loads(QUEUE_FILE.read_text())
    except Exception:
        return
    if not items:
        return

    log.info(f"Flushing {len(items)} queued submission(s)…")
    pending = []
    for payload in items:
        payload["submission_type"] = "queued"
        if _post_to_sheets(payload):
            log.info(f"  Flushed entry from {payload.get('timestamp','?')}")
        else:
            pending.append(payload)

    if pending:
        QUEUE_FILE.write_text(json.dumps(pending, indent=2))
        log.warning(f"  {len(pending)} entries still pending (still offline?).")
    else:
        QUEUE_FILE.unlink(missing_ok=True)
        log.info("  Queue fully flushed.")

def _post_to_sheets(payload: dict) -> bool:
    """POSTs to the Apps Script. The token is added here so it is never stored in the queue."""
    if not APPS_SCRIPT_URL.startswith("https://"):
        log.error("apps_script_url missing or not https in config.json — cannot submit.")
        return False
    try:
        data = json.dumps({**payload, "token": AGENT_TOKEN}).encode()
        req  = urllib.request.Request(
            APPS_SCRIPT_URL, data=data,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "Mozilla/5.0",
            },
            method="POST",
        )
        resp   = urllib.request.urlopen(req, timeout=15)
        result = json.loads(resp.read().decode())
        return result.get("status") == "ok"
    except Exception as e:
        log.warning(f"HTTP submit failed: {e}")
        return False

def submit_to_sheets(user_data: dict, hw: dict) -> bool:
    """Returns True if submitted immediately, False if queued offline."""
    payload = {"type": "checkin", "submission_type": "online", **user_data, **hw}
    if _post_to_sheets(payload):
        return True
    log.warning("No internet — saving to offline queue.")
    _enqueue(payload)
    return False

# ─── GUI ──────────────────────────────────────────────────────────────────────
class InventoryForm(tk.Tk):
    def __init__(self, hw: dict):
        super().__init__()
        self.hw        = hw
        self.submitted = False
        self.user_data: dict = {}

        self.title("Webiz Inventory Agent")
        self.configure(bg=BG_COLOR)
        self.resizable(False, False)
        self._center()
        self._build()
        self.protocol("WM_DELETE_WINDOW", self._on_cancel)
        self.after(150, self._raise_to_front)

    def _raise_to_front(self):
        try:
            from AppKit import NSApplication
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        except Exception:
            # osascript fallback — always available on macOS
            try:
                subprocess.Popen(
                    ["osascript", "-e",
                     f'tell application "System Events" to set frontmost of '
                     f'first process whose unix id is {os.getpid()} to true'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass
        self.lift()
        self.attributes("-topmost", True)
        self.after(200, lambda: self.attributes("-topmost", False))
        self.focus_force()

    def _center(self):
        w, h = 520, 644
        self.update_idletasks()
        x = (self.winfo_screenwidth()  - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry(f"{w}x{h}+{x}+{y}")

    def _build(self):
        # ── Header bar ────────────────────────────────────────────────────────
        hdr = tk.Frame(self, bg=BRAND_COLOR, height=80)
        hdr.pack(fill="x")
        hdr.pack_propagate(False)

        logo_shown = False
        logo_file = Path(__file__).parent / "webiz_logo.png"
        if logo_file.exists():
            try:
                self._logo_img = tk.PhotoImage(file=str(logo_file))
                tk.Label(hdr, image=self._logo_img, bg=BRAND_COLOR).pack(
                    side="left", padx=22, pady=14)
                logo_shown = True
            except Exception:
                pass

        if not logo_shown:
            tk.Label(hdr, text="WEBIZ", fg="white", bg=BRAND_COLOR,
                     font=("Helvetica", 30, "bold")).pack(side="left", padx=22, pady=16)

        # Red accent line
        tk.Frame(self, bg=ACCENT_COLOR, height=4).pack(fill="x")

        # ── Welcome text ──────────────────────────────────────────────────────
        wf = tk.Frame(self, bg=BG_COLOR)
        wf.pack(fill="x", padx=26, pady=(18, 4))
        tk.Label(
            wf,
            text="Hello, I am Inventory Agent of Webiz and I need following information",
            wraplength=468, justify="left",
            font=("Helvetica", 12), fg="#1C1C1E", bg=BG_COLOR,
        ).pack(anchor="w")

        # ── Form ──────────────────────────────────────────────────────────────
        form = tk.Frame(self, bg=BG_COLOR)
        form.pack(fill="both", expand=True, padx=26, pady=4)
        form.columnconfigure(1, weight=1)

        self._e_first   = self._field(form, "First Name *",  0)
        self._e_last    = self._field(form, "Last Name *",   1)
        self._e_email   = self._field(form, "Email *",        2)

        tk.Label(form, text="Project *", font=("Helvetica", 11, "bold"),
                 bg=BG_COLOR, anchor="w").grid(row=3, column=0, sticky="w", pady=(10, 2))
        self._v_project = tk.StringVar(value=PROJECTS[0])
        ttk.Combobox(
            form, textvariable=self._v_project, values=PROJECTS,
            state="readonly", font=("Helvetica", 11), width=36,
        ).grid(row=3, column=1, sticky="ew", padx=(8, 0), pady=(10, 2))

        self._e_screen  = self._field(form, 'Screen Size (in.) *', 4)

        # ── Device info preview ───────────────────────────────────────────────
        tk.Frame(self, bg="#D0D5DD", height=1).pack(fill="x", padx=26, pady=(12, 6))
        pf = tk.Frame(self, bg=BG_COLOR)
        pf.pack(fill="x", padx=26)
        tk.Label(pf, text="Device information that will be recorded:",
                 font=("Helvetica", 9, "italic"), fg="#6B7280", bg=BG_COLOR).pack(anchor="w")
        hw = self.hw
        preview = (
            f"  {hw['brand']} {hw['model']}  •  SN: {hw.get('serial_number','?')}  •  {hw['os']}\n"
            f"  CPU: {hw['cpu']}  •  RAM: {hw['ram']}  •  Storage: {hw['storage']}\n"
            f"  Host: {hw['hostname']}  •  IP: {hw['ip_address']}"
        )
        tk.Label(pf, text=preview, font=("Helvetica", 9), fg="#374151",
                 bg=BG_COLOR, justify="left", wraplength=468).pack(anchor="w")

        # ── Buttons ───────────────────────────────────────────────────────────
        bf = tk.Frame(self, bg=BG_COLOR)
        bf.pack(fill="x", padx=26, pady=(10, 20))
        tk.Button(
            bf, text="Cancel", command=self._on_cancel,
            font=("Helvetica", 11), fg="#6B7280", bg="#E5E7EB",
            relief="flat", padx=18, pady=7, cursor="hand2", activebackground="#D1D5DB",
        ).pack(side="right", padx=(8, 0))
        tk.Button(
            bf, text="Submit →", command=self._on_submit,
            font=("Helvetica", 11, "bold"), fg="white", bg=ACCENT_COLOR,
            relief="flat", padx=18, pady=7, cursor="hand2", activebackground="#C0252E",
        ).pack(side="right")

    def _field(self, parent: tk.Frame, label: str, row: int) -> tk.Entry:
        tk.Label(parent, text=label, font=("Helvetica", 11, "bold"),
                 bg=BG_COLOR, anchor="w").grid(row=row, column=0, sticky="w", pady=(10, 2))
        e = tk.Entry(parent, font=("Helvetica", 11), relief="solid", bd=1, width=38)
        e.grid(row=row, column=1, sticky="ew", padx=(8, 0), pady=(10, 2))
        return e

    # ── Validation ────────────────────────────────────────────────────────────
    def _validate(self) -> bool:
        if not self._e_first.get().strip():
            messagebox.showwarning("Missing field", "Please enter your First Name.", parent=self)
            return False
        if not self._e_last.get().strip():
            messagebox.showwarning("Missing field", "Please enter your Last Name.", parent=self)
            return False
        if not re.match(r"[^@]+@[^@]+\.[^@]+", self._e_email.get().strip()):
            messagebox.showwarning("Invalid email", "Please enter a valid email address.", parent=self)
            return False
        if not self._e_screen.get().strip():
            messagebox.showwarning("Missing field", "Please enter the screen size (inches).", parent=self)
            return False
        return True

    def _on_submit(self):
        if not self._validate():
            return
        self.user_data = {
            "first_name":  self._e_first.get().strip(),
            "last_name":   self._e_last.get().strip(),
            "email":       self._e_email.get().strip(),
            "project":     self._v_project.get(),
            "screen_size": self._e_screen.get().strip(),
        }
        self.submitted = True
        self.destroy()

    def _on_cancel(self):
        if messagebox.askyesno(
            "Cancel check-in",
            "Are you sure you want to skip?\n\n"
            "• IT will be notified\n"
            "• You'll be reminded again in 24 hours",
            parent=self,
        ):
            self.submitted = False
            self.destroy()


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Webiz Inventory Agent")
    parser.add_argument("--force", action="store_true",
                        help="Bypass the 6-month interval guard and show the form immediately.")
    args = parser.parse_args()

    log.info("=== Webiz Inventory Agent v2.0 started ===")

    # When launched as a background service (LaunchAgent / systemd), stdout is not
    # a TTY. Wait briefly so the desktop session is fully ready before showing a GUI.
    if not sys.stdout.isatty():
        log.info("Background launch detected — waiting 15 s for desktop to settle…")
        time.sleep(15)

    # 1. Self-update (silent, restarts if new version found)
    self_update()
    _purge_legacy_secret()

    # 2. Flush any offline-queued submissions
    flush_queue()

    # 3. Guard: exit early if not due (skipped when --force is passed)
    state = load_state()
    if not args.force and not should_show_form(state):
        sys.exit(0)

    # 4. Collect hardware
    log.info("Collecting hardware information…")
    hw = collect_hardware()
    log.info(json.dumps(hw, indent=2))

    # 5. Show GUI
    app = InventoryForm(hw)
    app.mainloop()

    # ── Cancelled ─────────────────────────────────────────────────────────────
    if not app.submitted:
        state["cancelled_at"] = datetime.datetime.now().isoformat()
        save_state(state)
        # Admin notification is sent by the Apps Script (best effort, not queued)
        _post_to_sheets({"type": "cancelled", **hw})
        log.warning(f"Form cancelled. Will retry in {CANCEL_RETRY_H}h.")
        sys.exit(0)

    # ── Submitted ─────────────────────────────────────────────────────────────
    log.info("Submitting data to Google Sheets…")
    immediate = submit_to_sheets(app.user_data, hw)

    state["last_run"] = datetime.datetime.now().isoformat()
    state.pop("cancelled_at", None)
    save_state(state)

    # Confirmation email (admin + user) is sent by the Apps Script on receipt.

    # Success dialog
    dialog_msg = f"Thank you, {app.user_data['first_name']}!\n\nYour device has been registered."
    if not immediate:
        dialog_msg += "\n\n(Offline — data will sync automatically.)"
    messagebox.showinfo("Webiz Inventory – Done", dialog_msg)

    log.info("=== Completed successfully ===")


if __name__ == "__main__":
    main()
