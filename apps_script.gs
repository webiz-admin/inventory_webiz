/**
 * Webiz Inventory Agent – Google Apps Script
 *
 * HOW TO DEPLOY (one-time setup by IT admin):
 *  1. Open your Google Sheet → Extensions → Apps Script
 *  2. Paste this entire file, replacing the default code
 *  3. Click Deploy → New deployment
 *     Type: Web app
 *     Execute as: Me
 *     Who has access: Anyone          ← required so devices can POST
 *  4. Click Deploy → copy the Web App URL
 *  5. Project Settings → Script Properties → add:
 *       AGENT_TOKEN   = long random string (must match "agent_token" in webiz_config.json)
 *       ADMIN_EMAIL   = IT admin address that receives all notifications
 *  6. Put the Web App URL + token into webiz_config.json (NOT into any committed file)
 *     and rebuild the installers (build_installers.sh / build_macos_pkg.sh / Build_Windows_EXE.cmd)
 *  7. To update: make changes → Deploy → Manage deployments → edit existing → New version
 *     (the first deploy after adding email sending asks to authorize the "send email" scope)
 *
 * SECURITY: this file is public. Never put tokens, passwords or URLs in it —
 * secrets live only in Script Properties.
 */

// ── Sheet names ───────────────────────────────────────────────────────────────
const SHEET_NAME     = "Inventory";
const CHANGELOG_NAME = "Change Log";
const MONITORS_NAME  = "Monitors";

// ── Email policy ──────────────────────────────────────────────────────────────
// The user's confirmation copy is only sent to these domains; everything else
// goes to ADMIN_EMAIL only (prevents the public endpoint being used as a spam relay).
const ALLOWED_USER_EMAIL_DOMAINS = ["webiz.com"];
const MAX_EMAILS_PER_DAY         = 200;
const CANCEL_RETRY_HOURS         = 24;   // keep in sync with the agents (display only)

// ── Field limits ──────────────────────────────────────────────────────────────
const MAX_FIELD_LEN = 200;

// ── Inventory columns ─────────────────────────────────────────────────────────
const HEADERS = [
  "Timestamp", "First Name", "Last Name", "Email", "Project",
  "Hostname", "IP Address", "Brand", "Model", "Serial Number",
  "CPU", "RAM", "Storage", "OS", "External Monitors"
];

// 0-based column indices for Inventory
const COL = {
  TIMESTAMP:     0,
  FIRST_NAME:    1,
  LAST_NAME:     2,
  EMAIL:         3,
  PROJECT:       4,
  HOSTNAME:      5,
  IP_ADDRESS:    6,
  BRAND:         7,
  MODEL:         8,
  SERIAL_NUMBER: 9,
  CPU:           10,
  RAM:           11,
  STORAGE:       12,
  OS:            13,
  MONITORS:      14,   // summary only — not part of the "did the device change" comparison
};

// ── Monitors sheet: one row per physical monitor ──────────────────────────────
const MONITOR_HEADERS = [
  "Last Seen", "Device Serial", "Hostname", "Owner", "Email", "Project",
  "Brand", "Model", "Monitor Serial", "Size (in)", "Resolution", "Connection",
  "Year", "First Seen"
];
const MCOL = {
  LAST_SEEN: 0, DEVICE_SERIAL: 1, HOSTNAME: 2, OWNER: 3, EMAIL: 4, PROJECT: 5,
  BRAND: 6, MODEL: 7, SERIAL: 8, SIZE: 9, RESOLUTION: 10, CONNECTION: 11,
  YEAR: 12, FIRST_SEEN: 13,
};
const MAX_MONITORS = 8;

// EDID manufacturer (PNP) id → brand. Unknown ids are shown as the raw code.
const PNP_BRANDS = {
  DEL: "Dell", GSM: "LG", LGD: "LG", SAM: "Samsung", SEC: "Samsung", HWP: "HP", HPN: "HP",
  LEN: "Lenovo", ACI: "ASUS", AUS: "ASUS", ACR: "Acer", PHL: "Philips", BNQ: "BenQ",
  AOC: "AOC", VSC: "ViewSonic", APP: "Apple", MSI: "MSI", GBT: "Gigabyte", IVM: "iiyama",
  EIZ: "EIZO", NEC: "NEC", SNY: "Sony", XMI: "Xiaomi", HKC: "HKC", KTC: "KTC",
  HUW: "Huawei", MEI: "Panasonic", FUS: "Fujitsu", SHP: "Sharp", TOS: "Toshiba",
};

// ── Change Log columns ────────────────────────────────────────────────────────
const CHANGELOG_HEADERS = ["Timestamp", "Serial Number", "Hostname", "Comment"];

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Current timestamp in Tbilisi time (UTC+4), human-readable.
 * Example: "21 Apr 2026, 14:30:00"
 */
function getTbilisiTimestamp() {
  const now   = new Date();
  const local = new Date(now.getTime() + 4 * 60 * 60 * 1000);

  const months = ["Jan","Feb","Mar","Apr","May","Jun",
                  "Jul","Aug","Sep","Oct","Nov","Dec"];

  const dd  = String(local.getUTCDate()).padStart(2, "0");
  const mon = months[local.getUTCMonth()];
  const yy  = local.getUTCFullYear();
  const hh  = String(local.getUTCHours()).padStart(2, "0");
  const mm  = String(local.getUTCMinutes()).padStart(2, "0");
  const ss  = String(local.getUTCSeconds()).padStart(2, "0");

  return `${dd} ${mon} ${yy}, ${hh}:${mm}:${ss}`;
}

/**
 * Ensures a sheet exists with the given headers and styling, returns it.
 */
function getOrCreateSheet(ss, name, headers, headerBg) {
  let sheet = ss.getSheetByName(name);
  if (!sheet) {
    sheet = ss.insertSheet(name);
  }
  const styleHeader = range => range.setFontWeight("bold")
       .setBackground(headerBg || "#1A2B5A")
       .setFontColor("#FFFFFF")
       .setHorizontalAlignment("center");
  if (sheet.getLastRow() === 0) {
    sheet.appendRow(headers);
    styleHeader(sheet.getRange(1, 1, 1, headers.length));
    sheet.setFrozenRows(1);
  } else if (sheet.getLastColumn() < headers.length) {
    // Columns added in a later version: extend the existing header row
    const from = sheet.getLastColumn() + 1;
    const missing = headers.slice(from - 1);
    styleHeader(sheet.getRange(1, from, 1, missing.length).setValues([missing]));
  }
  return sheet;
}

/**
 * Finds the existing Inventory row for a device.
 * Returns { rowNum, values } (1-based sheet row) or null if not found.
 *
 * Match priority:
 *   1. Serial Number  (most reliable)
 *   2. Hostname       (fallback when serial is absent)
 *
 * First Name / Last Name / Email / Project are NOT part of the lookup key —
 * they are compared afterwards to detect ownership changes.
 */
function findExistingRow(sheet, serialNumber, hostname) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 1) return null; // only header or empty

  const data = sheet.getRange(2, 1, lastRow - 1, HEADERS.length).getValues();

  for (let i = data.length - 1; i >= 0; i--) {
    const sn   = String(data[i][COL.SERIAL_NUMBER]).trim();
    const host = String(data[i][COL.HOSTNAME]).trim();

    if (serialNumber && sn && sn === serialNumber) {
      return { rowNum: i + 2, values: data[i] }; // +2: 1-based + header offset
    }
    if (!serialNumber && hostname && host === hostname) {
      return { rowNum: i + 2, values: data[i] };
    }
  }
  return null;
}

/**
 * Appends one row to the Change Log sheet.
 */
function appendChangeLog(ss, serialNumber, hostname, comment) {
  const sheet = getOrCreateSheet(ss, CHANGELOG_NAME, CHANGELOG_HEADERS, "#2E4057");
  sheet.appendRow([getTbilisiTimestamp(), serialNumber, hostname, comment]);
  sheet.autoResizeColumns(1, CHANGELOG_HEADERS.length);
}

/**
 * Normalises an incoming value: string, no control characters, trimmed, length-capped.
 */
function clean(value, maxLen) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001F\u007F]/g, " ")
    .trim()
    .slice(0, maxLen || MAX_FIELD_LEN);
}

/**
 * Prevents formula injection: Sheets evaluates any string starting with = + - @
 * as a formula (e.g. =IMPORTXML(...) could exfiltrate sheet data).
 * A leading apostrophe forces plain text and is not displayed.
 */
function sheetSafe(value) {
  return /^[=+\-@]/.test(value) ? "'" + value : value;
}

function jsonResponse(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function getAdminEmail() {
  return PropertiesService.getScriptProperties().getProperty("ADMIN_EMAIL")
      || Session.getEffectiveUser().getEmail();
}

function isAllowedUserEmail(email) {
  const m = /^[^@\s]+@([^@\s]+)$/.exec(email);
  return !!m && ALLOWED_USER_EMAIL_DOMAINS.indexOf(m[1].toLowerCase()) !== -1;
}

/**
 * Sends a plain-text email, bounded by a daily cap. Failures never break the check-in.
 */
function sendNotification(to, subject, body) {
  try {
    const props = PropertiesService.getScriptProperties();
    const key   = "mail_count_" + Utilities.formatDate(new Date(), "Asia/Tbilisi", "yyyyMMdd");
    const count = Number(props.getProperty(key) || 0);
    if (count >= MAX_EMAILS_PER_DAY) {
      console.warn("Daily email cap reached — skipping: " + subject);
      return;
    }
    MailApp.sendEmail({ to: to.join(","), subject: subject, body: body, name: "Webiz Inventory" });
    props.setProperty(key, String(count + 1));
  } catch (err) {
    console.error("Email failed: " + err.message);
  }
}

function deviceSummary(f) {
  return `Device    : ${f.brand} ${f.model}\n` +
         `Serial    : ${f.serial_number || "N/A"}\n` +
         `CPU       : ${f.cpu}\n` +
         `RAM       : ${f.ram}\n` +
         `Storage   : ${f.storage}\n` +
         `OS        : ${f.os}\n` +
         `Hostname  : ${f.hostname}\n` +
         `IP        : ${f.ip_address}\n` +
         `Timestamp : ${f.timestamp}\n` +
         `Monitors  : ${monitorsSummary(f.monitors || [])}\n`;
}

function notifyCheckin(f, queued) {
  const fullName = `${f.first_name} ${f.last_name}`;
  const to = [getAdminEmail()];
  if (isAllowedUserEmail(f.email) && to.indexOf(f.email) === -1) to.push(f.email);

  const body =
    `Hi ${f.first_name},\n\n` +
    `Your device has been successfully registered in the Webiz Inventory.\n\n` +
    `${"─".repeat(44)}\n` +
    `Name      : ${fullName}\n` +
    `Email     : ${f.email}\n` +
    `Project   : ${f.project}\n` +
    `Screen    : ${f.screen_size || "N/A"} in.\n` +
    `${"─".repeat(44)}\n` +
    deviceSummary(f) + "\n" +
    (queued ? "⚠  Device was offline at check-in — data was synced later.\n"
            : "✔  Data submitted to the inventory sheet.\n");

  sendNotification(to, `[Webiz Inventory] ✔ Check-in complete – ${fullName} / ${f.hostname}`, body);
}

function notifyCancelled(f) {
  const body =
    `The inventory form was CANCELLED by the user.\n\n` +
    deviceSummary(f) + "\n" +
    `The agent will prompt again in ${CANCEL_RETRY_HOURS} hours.`;
  sendNotification([getAdminEmail()],
    `[Webiz Inventory] CANCELLED – SN: ${f.serial_number || "N/A"} / ${f.hostname}`, body);
}

// ── Monitors ──────────────────────────────────────────────────────────────────

/** Validates and normalises the agent's monitor list. */
function cleanMonitors(raw) {
  if (!Array.isArray(raw)) return [];
  return raw.slice(0, MAX_MONITORS)
    .filter(m => m && typeof m === "object")
    .map(m => {
      const pnp = clean(m.manufacturer_id, 3).toUpperCase();
      let serial = clean(m.serial, 64);
      if (/^0+$/.test(serial)) serial = "";   // many monitors report 0 instead of a serial
      return {
        brand:      PNP_BRANDS[pnp] || pnp,
        model:      clean(m.name, 100) || clean(m.product_code, 20),
        serial:     serial,
        size:       clean(m.size_in, 5),
        resolution: clean(m.resolution, 20),
        connection: clean(m.connection, 40),
        year:       clean(m.year, 4),
      };
    })
    .filter(m => m.brand || m.model);
}

function monitorLabel(m) {
  // "Dell" + "DELL U2724DE" → "Dell U2724DE"
  const sameBrand = m.brand && m.model.toLowerCase().indexOf(m.brand.toLowerCase()) === 0;
  return [m.brand, sameBrand ? m.model.slice(m.brand.length).trim() : m.model]
           .filter(Boolean).join(" ") +
         (m.size ? ` ${m.size}"` : "") + (m.connection ? ` (${m.connection})` : "");
}

function monitorsSummary(monitors) {
  return monitors.length ? monitors.map(monitorLabel).join("; ") : "None";
}

/**
 * One row per physical monitor. Identified by Brand + Model + Serial; monitors without a
 * serial can only be told apart per device, so they are keyed by Device Serial + Brand + Model.
 * A monitor seen on a different device is updated in place and the move goes to the Change Log.
 */
function upsertMonitors(ss, f, monitors, now) {
  if (!monitors.length) return;
  const sheet = getOrCreateSheet(ss, MONITORS_NAME, MONITOR_HEADERS, "#3B5B92");
  const last  = sheet.getLastRow();
  const rows  = last > 1 ? sheet.getRange(2, 1, last - 1, MONITOR_HEADERS.length).getValues() : [];
  const str   = v => String(v).trim();
  const owner = `${f.first_name} ${f.last_name}`.trim();
  const deviceKey = f.serial_number || f.hostname;

  monitors.forEach(m => {
    const idx = rows.findIndex(r => m.serial
      ? str(r[MCOL.BRAND]) === m.brand && str(r[MCOL.MODEL]) === m.model && str(r[MCOL.SERIAL]) === m.serial
      : !str(r[MCOL.SERIAL]) && str(r[MCOL.DEVICE_SERIAL]) === deviceKey &&
        str(r[MCOL.BRAND]) === m.brand && str(r[MCOL.MODEL]) === m.model);

    const values = [];
    values[MCOL.LAST_SEEN]     = now;
    values[MCOL.DEVICE_SERIAL] = deviceKey;
    values[MCOL.HOSTNAME]      = f.hostname;
    values[MCOL.OWNER]         = owner;
    values[MCOL.EMAIL]         = f.email;
    values[MCOL.PROJECT]       = f.project;
    values[MCOL.BRAND]         = m.brand;
    values[MCOL.MODEL]         = m.model;
    values[MCOL.SERIAL]        = m.serial;
    values[MCOL.SIZE]          = m.size;
    values[MCOL.RESOLUTION]    = m.resolution;
    values[MCOL.CONNECTION]    = m.connection;
    values[MCOL.YEAR]          = m.year;
    values[MCOL.FIRST_SEEN]    = idx === -1 ? now : rows[idx][MCOL.FIRST_SEEN];

    if (idx === -1) {
      sheet.appendRow(values.map(sheetSafe));
      rows.push(values);
    } else {
      const prev = rows[idx];
      if (str(prev[MCOL.DEVICE_SERIAL]) !== deviceKey) {
        appendChangeLog(ss, sheetSafe(m.serial || m.model), sheetSafe(f.hostname),
          sheetSafe(`Monitor ${monitorLabel(m)} moved from ${str(prev[MCOL.HOSTNAME])} ` +
                    `(${str(prev[MCOL.OWNER])}) to ${f.hostname} (${owner}) – ${now}`));
      }
      sheet.getRange(idx + 2, 1, 1, MONITOR_HEADERS.length).setValues([values.map(sheetSafe)]);
      rows[idx] = values;
    }
  });
  sheet.autoResizeColumns(1, MONITOR_HEADERS.length);
}

// ── Web App entry point ───────────────────────────────────────────────────────

function doPost(e) {
  const lock = LockService.getScriptLock();
  try {
    const data = JSON.parse(e.postData.contents);

    // ── Auth: shared token from Script Properties (skipped only if not configured)
    const expected = PropertiesService.getScriptProperties().getProperty("AGENT_TOKEN");
    if (expected && data.token !== expected) {
      return jsonResponse({ status: "error", message: "unauthorized" });
    }

    const f = {};
    ["timestamp", "first_name", "last_name", "email", "project", "screen_size",
     "hostname", "ip_address", "brand", "model", "serial_number",
     "cpu", "ram", "storage", "os"].forEach(k => { f[k] = clean(data[k]); });
    f.email = f.email.toLowerCase();
    f.monitors = cleanMonitors(data.monitors);

    const type = clean(data.type || "checkin", 20);

    if (type === "cancelled") {
      notifyCancelled(f);
      return jsonResponse({ status: "ok" });
    }
    if (type !== "checkin") {
      return jsonResponse({ status: "error", message: "unknown type" });
    }
    if (!f.serial_number && !f.hostname) {
      return jsonResponse({ status: "error", message: "serial_number or hostname required" });
    }

    lock.waitLock(20000);   // serialise sheet read-compare-write between concurrent devices

    const ss       = SpreadsheetApp.getActiveSpreadsheet();
    const invSheet = getOrCreateSheet(ss, SHEET_NAME, HEADERS, "#1A2B5A");

    const sn       = f.serial_number;
    const hostname = f.hostname;
    const now      = getTbilisiTimestamp();

    // Raw values are used for comparison; sheetSafe() is applied only when writing.
    const newRowValues = [
      f.timestamp || now,
      f.first_name,
      f.last_name,
      f.email,
      f.project,
      hostname,
      f.ip_address,
      f.brand,
      f.model,
      sn,
      f.cpu,
      f.ram,
      f.storage,
      f.os,
      monitorsSummary(f.monitors),
    ];

    const existing = findExistingRow(invSheet, sn, hostname);

    if (!existing) {
      // ── New device: add a full row, no Change Log entry ──────────────────
      invSheet.appendRow(newRowValues.map(sheetSafe));
      invSheet.autoResizeColumns(1, HEADERS.length);

    } else {
      // ── Known device: compare device/owner fields (skip Timestamp and the
      //    monitor summary — monitor changes are tracked on the Monitors sheet)
      let allMatch = true;
      for (let col = 1; col <= COL.OS; col++) {
        if (String(newRowValues[col]).trim() !== String(existing.values[col]).trim()) allMatch = false;
      }

      if (allMatch) {
        // Nothing changed — keep the row, only refresh the monitor summary if it differs
        if (String(existing.values[COL.MONITORS]).trim() !== newRowValues[COL.MONITORS]) {
          invSheet.getRange(existing.rowNum, COL.MONITORS + 1)
                  .setValue(sheetSafe(newRowValues[COL.MONITORS]));
        }
        appendChangeLog(ss, sheetSafe(sn), sheetSafe(hostname),
          `Collected nothing changed – ${now}`);

      } else {
        // Data changed — update the existing Inventory row with fresh values
        newRowValues[COL.TIMESTAMP] = now; // refresh timestamp on update
        invSheet.getRange(existing.rowNum, 1, 1, HEADERS.length)
                .setValues([newRowValues.map(sheetSafe)]);
        invSheet.autoResizeColumns(1, HEADERS.length);

        // Log previous owner to Change Log
        const prevFirst = String(existing.values[COL.FIRST_NAME]).trim();
        const prevLast  = String(existing.values[COL.LAST_NAME]).trim();
        appendChangeLog(ss, sheetSafe(sn), sheetSafe(hostname),
          sheetSafe(`Previous Checkin device owner was: ${prevFirst} ${prevLast} – ${now}`));
      }
    }

    upsertMonitors(ss, f, f.monitors, now);

    lock.releaseLock();
    notifyCheckin(f, data.submission_type === "queued");

    return jsonResponse({ status: "ok" });

  } catch (err) {
    // Do not echo internal error details back to unauthenticated callers.
    console.error("doPost failed: " + err.message);
    return jsonResponse({ status: "error", message: "internal error" });
  } finally {
    if (lock.hasLock()) lock.releaseLock();
  }
}

// Simple health-check (open URL in browser to verify deployment is alive)
function doGet(e) {
  return ContentService.createTextOutput("Webiz Inventory API – OK");
}
