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
  "CPU", "RAM", "Storage", "OS"
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
  if (sheet.getLastRow() === 0) {
    sheet.appendRow(headers);
    const hdr = sheet.getRange(1, 1, 1, headers.length);
    hdr.setFontWeight("bold")
       .setBackground(headerBg || "#1A2B5A")
       .setFontColor("#FFFFFF")
       .setHorizontalAlignment("center");
    sheet.setFrozenRows(1);
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
         `Timestamp : ${f.timestamp}\n`;
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
    ];

    const existing = findExistingRow(invSheet, sn, hostname);

    if (!existing) {
      // ── New device: add a full row, no Change Log entry ──────────────────
      invSheet.appendRow(newRowValues.map(sheetSafe));
      invSheet.autoResizeColumns(1, HEADERS.length);

    } else {
      // ── Known device: compare all fields except Timestamp ────────────────
      const allMatch = HEADERS.slice(1).every((_, i) => {
        const col = i + 1; // skip Timestamp (index 0)
        return String(newRowValues[col]).trim() === String(existing.values[col]).trim();
      });

      if (allMatch) {
        // Nothing changed — skip Inventory update, log to Change Log only
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
