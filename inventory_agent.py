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

# ─── External monitors ────────────────────────────────────────────────────────
# Each monitor: manufacturer_id (3-letter PNP code, mapped to a brand by the
# Apps Script), name, product_code, serial, size_in, resolution, connection, year.
# USB-C / Thunderbolt monitors use DisplayPort Alt Mode, so they are reported
# as "DisplayPort/USB-C" — the OS cannot tell them apart from a DP cable.
MAX_MONITORS = 8

def _pnp(vendor: int) -> str:
    """16-bit EDID/EISA vendor number → 3-letter PNP id (e.g. 0x10AC → DEL)."""
    return "".join(chr(((vendor >> sh) & 31) + 64) for sh in (10, 5, 0)) if vendor else ""

def _diag_in(w_mm: float, h_mm: float, decimals: int = 0):
    """Diagonal in inches from the panel's physical size (mm)."""
    if not (w_mm and h_mm):
        return ""
    d = round((w_mm ** 2 + h_mm ** 2) ** 0.5 / 25.4, decimals)
    return int(d) if decimals == 0 else d

def _connection(raw: str) -> str:
    r = (raw or "").lower()
    if "hdmi" in r:
        return "HDMI"
    if r in ("dp", "displayport") or "displayport" in r:
        return "DisplayPort/USB-C"
    if "dvi" in r:
        return "DVI"
    if "vga" in r:
        return "VGA"
    if "airplay" in r:
        return "AirPlay"
    return raw or ""

def _mac_cg_displays(builtin: bool = False) -> list:
    """Displays via CoreGraphics (Intel + Apple Silicon): external ones, or the built-in panel."""
    import ctypes, ctypes.util
    cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))

    class CGSize(ctypes.Structure):
        _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]

    u32 = ctypes.c_uint32
    cg.CGGetOnlineDisplayList.argtypes = [u32, ctypes.POINTER(u32), ctypes.POINTER(u32)]
    for fn in ("CGDisplayIsBuiltin", "CGDisplayVendorNumber",
               "CGDisplayModelNumber", "CGDisplaySerialNumber"):
        getattr(cg, fn).argtypes = [u32]
        getattr(cg, fn).restype = u32
    cg.CGDisplayScreenSize.argtypes = [u32]
    cg.CGDisplayScreenSize.restype = CGSize

    ids, n = (u32 * 32)(), u32()
    if cg.CGGetOnlineDisplayList(32, ids, ctypes.byref(n)) != 0:
        return []
    out = []
    for d in ids[:n.value]:
        if bool(cg.CGDisplayIsBuiltin(d)) != builtin:
            continue
        size = cg.CGDisplayScreenSize(d)
        out.append({
            "id": int(d),
            "vendor": cg.CGDisplayVendorNumber(d),
            "model": cg.CGDisplayModelNumber(d),
            "serial_num": cg.CGDisplaySerialNumber(d),
            "size_in": _diag_in(size.width, size.height),
            "w_mm": size.width, "h_mm": size.height,
        })
    return out

def _collect_monitors_mac() -> list:
    # system_profiler: name, native resolution, year — keyed by CoreGraphics display id
    sp = {}
    try:
        data = json.loads(_run(["system_profiler", "SPDisplaysDataType", "-json"]) or "{}")
        for gpu in data.get("SPDisplaysDataType", []):
            for m in gpu.get("spdisplays_ndrvs", []):
                if m.get("_spdisplays_displayID"):
                    sp[str(m["_spdisplays_displayID"])] = m
    except Exception:
        pass

    # IORegistry (Apple Silicon): product name, alphanumeric serial, link type
    io = []
    try:
        import plistlib
        raw = subprocess.run(["ioreg", "-arw0", "-k", "DisplayAttributes"],
                             capture_output=True, timeout=15).stdout
        for e in plistlib.loads(raw) if raw else []:
            pa = e.get("DisplayAttributes", {}).get("ProductAttributes", {})
            io.append((pa, (e.get("Transport") or {}).get("Downstream", "")))
    except Exception:
        pass

    monitors = []
    for d in _mac_cg_displays():
        m = sp.get(str(d["id"]), {})
        pa, link = {}, ""
        candidates = [(a, t) for a, t in io
                      if a.get("LegacyManufacturerID") == d["vendor"] and a.get("ProductID") == d["model"]]
        for a, t in candidates:   # identical models: pick the one with the same numeric serial
            if len(candidates) == 1 or a.get("SerialNumber") == d["serial_num"]:
                pa, link = a, t
                break
        pixels = (m.get("_spdisplays_pixels") or "").replace(" ", "")
        monitors.append({
            "manufacturer_id": pa.get("ManufacturerID") or _pnp(d["vendor"]),
            "name":            pa.get("ProductName") or m.get("_name", ""),
            "product_code":    f"{d['model']:04X}" if d["model"] else "",
            "serial":          str(pa.get("AlphanumericSerialNumber") or (d["serial_num"] or "")),
            "size_in":         d["size_in"],
            "resolution":      pixels,
            "connection":      _connection(link),
            "year":            pa.get("YearOfManufacture") or m.get("_spdisplays_display-year", ""),
        })
    return monitors

def _parse_edid(edid: bytes) -> dict:
    """Minimal EDID 1.x parser (base block only)."""
    if len(edid) < 128 or edid[:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
        return {}
    info = {
        "manufacturer_id": _pnp((edid[8] << 8) | edid[9]),
        "product_code":    f"{edid[10] | (edid[11] << 8):04X}",
        "serial":          "",
        "name":            "",
        "size_in":         _diag_in(edid[21] * 10, edid[22] * 10),   # cm; refined from the timing below
        "resolution":      "",
        "year":            1990 + edid[17] if edid[17] else "",
    }
    serial_num = int.from_bytes(edid[12:16], "little")
    for off in (54, 72, 90, 108):
        blk = edid[off:off + 18]
        if blk[0] == 0 and blk[1] == 0:          # display descriptor
            text = blk[5:18].split(b"\x0a")[0].decode("ascii", "ignore").strip()
            if blk[3] == 0xFC:
                info["name"] = text
            elif blk[3] == 0xFF:
                info["serial"] = text
        elif off == 54:                           # first detailed timing = preferred mode
            h = blk[2] | ((blk[4] & 0xF0) << 4)
            v = blk[5] | ((blk[7] & 0xF0) << 4)
            if h and v:
                info["resolution"] = f"{h}x{v}"
            w_mm = blk[12] | ((blk[14] & 0xF0) << 4)    # image size in mm (more precise than cm)
            h_mm = blk[13] | ((blk[14] & 0x0F) << 8)
            if w_mm and h_mm:
                info["size_in"] = _diag_in(w_mm, h_mm)
                info["w_mm"], info["h_mm"] = w_mm, h_mm
    if not info["serial"] and serial_num:
        info["serial"] = str(serial_num)
    return info

def _linux_connectors(builtin: bool):
    for conn in sorted(Path("/sys/class/drm").glob("card*-*")):
        port = conn.name.split("-", 1)[1]                 # e.g. HDMI-A-1, DP-2, eDP-1
        if port.startswith(("eDP", "LVDS", "DSI")) == builtin:
            yield conn, port

def _collect_monitors_linux() -> list:
    monitors = []
    for conn, port in _linux_connectors(builtin=False):
        try:
            if (conn / "status").read_text().strip() != "connected":
                continue
            info = _parse_edid((conn / "edid").read_bytes())
        except Exception:
            continue
        if info:
            info["connection"] = _connection("HDMI" if port.startswith("HDMI") else
                                             "DisplayPort" if port.startswith("DP") else port)
            monitors.append(info)
    return monitors

def collect_monitors() -> list:
    """Never raises — a monitor problem must not block the check-in."""
    try:
        mons = _collect_monitors_mac() if _sys == "Darwin" else _collect_monitors_linux()
    except Exception as e:
        log.warning(f"Monitor detection failed: {e}")
        return []
    return [{k: (_clean(str(v)) if v not in ("", None) else "") for k, v in m.items()
             if k not in ("w_mm", "h_mm")}
            for m in mons[:MAX_MONITORS]]

# Marketed laptop sizes. The diagonal of the panel's active area is slightly smaller
# (a 15.6" panel measures ~15.55"), so the measured value is snapped to the nearest
# marketed size within 0.2".
APPLE_LAPTOP_SIZES   = (11.6, 12.0, 13.3, 13.6, 14.2, 15.3, 15.4, 16.0, 16.2)
COMMON_LAPTOP_SIZES  = (11.6, 12.0, 12.3, 12.5, 13.0, 13.3, 13.4, 13.5, 14.0, 14.5,
                        15.0, 15.6, 16.0, 17.3, 18.0)

def _snap_size(d: float, sizes) -> float:
    nearest = min(sizes, key=lambda x: abs(x - d))
    return nearest if abs(nearest - d) <= 0.2 else d

def builtin_screen_size() -> str:
    """Laptop panel diagonal in inches (1 decimal), "" when there is no built-in screen."""
    try:
        if _sys == "Darwin":
            panels = _mac_cg_displays(builtin=True)
        else:
            panels = []
            for conn, _ in _linux_connectors(builtin=True):
                if (conn / "status").read_text().strip() == "connected":
                    panels.append(_parse_edid((conn / "edid").read_bytes()))
        for p in panels:
            size = _diag_in(p.get("w_mm"), p.get("h_mm"), decimals=2)
            if size:
                sizes = APPLE_LAPTOP_SIZES if _sys == "Darwin" else COMMON_LAPTOP_SIZES
                return f"{_snap_size(size, sizes):g}"
    except Exception as e:
        log.warning(f"Built-in screen size detection failed: {e}")
    return ""

def monitors_summary(monitors: list) -> str:
    if not monitors:
        return "none detected"
    return "; ".join(
        " ".join(x for x in (m.get("name") or m.get("manufacturer_id", ""),
                             f'{m["size_in"]}"' if m.get("size_in") else "",
                             f'({m["connection"]})' if m.get("connection") else "") if x)
        for m in monitors)

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

    hw["monitors"]  = collect_monitors()
    hw["screen_size"] = builtin_screen_size()   # detected, not asked from the user
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
        w, h = 520, 600
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


        # ── Device info preview ───────────────────────────────────────────────
        tk.Frame(self, bg="#D0D5DD", height=1).pack(fill="x", padx=26, pady=(12, 6))
        pf = tk.Frame(self, bg=BG_COLOR)
        pf.pack(fill="x", padx=26)
        tk.Label(pf, text="Device information that will be recorded:",
                 font=("Helvetica", 9, "italic"), fg="#6B7280", bg=BG_COLOR).pack(anchor="w")
        hw = self.hw
        screen = f' {hw["screen_size"]}"' if hw.get("screen_size") else ""
        preview = (
            f"  {hw['brand']} {hw['model']}{screen}  •  SN: {hw.get('serial_number','?')}  •  {hw['os']}\n"
            f"  CPU: {hw['cpu']}  •  RAM: {hw['ram']}  •  Storage: {hw['storage']}\n"
            f"  Host: {hw['hostname']}  •  IP: {hw['ip_address']}\n"
            f"  Monitors: {monitors_summary(hw.get('monitors', []))}"
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
        return True

    def _on_submit(self):
        if not self._validate():
            return
        self.user_data = {
            "first_name":  self._e_first.get().strip(),
            "last_name":   self._e_last.get().strip(),
            "email":       self._e_email.get().strip(),
            "project":     self._v_project.get(),
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
