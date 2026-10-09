import os
import sys
import re
import json
import uuid
import sqlite3
import smtplib
import subprocess
from datetime import datetime, timezone, timedelta
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.utils import formatdate, make_msgid
from flask import Flask, request, jsonify, render_template_string

app = Flask(__name__)

HERMES_BIN = os.path.expanduser("~/.local/bin/hermes")
CERT_FILE = os.path.expanduser("~/.hermes/cert.pem")
KEY_FILE = os.path.expanduser("~/.hermes/key.pem")
DB_FILE = os.path.expanduser("~/.hermes/varatron_auth.db")
CONFIG_FILE = os.path.expanduser("~/.hermes/smtp_config.json")

# Allowed team email domains
ALLOWED_DOMAINS = ("@projectvara.com", "@edvara.com", "@zenzig.com")

# Known Team Member Profiles
TEAM_PROFILES = {
    "rich@zenzig.com": {"name": "Rich", "full_name": "Richard Olson", "role": "Founder & CEO"},
    "richolson@zenzig.com": {"name": "Rich", "full_name": "Richard Olson", "role": "Founder & CEO"},
    "rich@projectvara.com": {"name": "Rich", "full_name": "Richard Olson", "role": "Founder & CEO"},
    "richolson@edvara.com": {"name": "Rich", "full_name": "Richard Olson", "role": "Founder & CEO"},
    "craig@projectvara.com": {"name": "Craig", "full_name": "Craig", "role": "Executive Leadership"},
    "craig@edvara.com": {"name": "Craig", "full_name": "Craig", "role": "Executive Leadership"},
    "aaron@projectvara.com": {"name": "Aaron", "full_name": "Aaron", "role": "Executive Leadership"},
    "aaron@edvara.com": {"name": "Aaron", "full_name": "Aaron", "role": "Executive Leadership"},
    "info@projectvara.com": {"name": "Operations", "full_name": "Project Vara Team", "role": "Operations"},
    "social@projectvara.com": {"name": "Marketing", "full_name": "Social Team", "role": "Marketing"}
}

def resolve_user_profile(email: str):
    email = email.lower().strip()
    if email in TEAM_PROFILES:
        return TEAM_PROFILES[email]
    username = email.split("@")[0].replace(".", " ").replace("_", " ").title()
    first_name = username.split()[0] if username else "Associate"
    return {"name": first_name, "full_name": username, "role": "Associate"}

def is_allowed_email(email: str) -> bool:
    email = email.lower().strip()
    return any(email.endswith(dom) for dom in ALLOWED_DOMAINS)

# Initialize Auth SQLite Database
def init_db():
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("""
        CREATE TABLE IF NOT EXISTS device_keys (
            key TEXT PRIMARY KEY,
            email TEXT NOT NULL,
            name TEXT,
            device_info TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_used_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            is_active INTEGER DEFAULT 1
        )
    """)
    cols = [col[1] for col in c.execute("PRAGMA table_info(device_keys)").fetchall()]
    if "name" not in cols:
        c.execute("ALTER TABLE device_keys ADD COLUMN name TEXT")

    c.execute("""
        CREATE TABLE IF NOT EXISTS otp_codes (
            code TEXT PRIMARY KEY,
            email TEXT NOT NULL,
            expires_at TIMESTAMP NOT NULL,
            used INTEGER DEFAULT 0
        )
    """)
    conn.commit()
    conn.close()

init_db()

def get_smtp_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "host": "mail.zenzig.com",
        "port": 465,
        "use_ssl": True,
        "user": os.getenv("SMTP_USER", "varatron@projectvara.com"),
        "password": os.getenv("SMTP_PASSWORD", ""),
        "from": "Varatron <varatron@projectvara.com>"
    }

def clean_hermes_output(text: str):
    ansi_escape = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]')
    cleaned = ansi_escape.sub('', text)

    session_match = re.search(r'session_id:\s*([a-zA-Z0-9_-]+)', cleaned)
    session_id = session_match.group(1) if session_match else None

    cleaned = re.sub(r'\n*session_id:\s*[a-zA-Z0-9_-]+.*$', '', cleaned, flags=re.DOTALL)
    cleaned = re.sub(r'┌─\s*Reasoning.*?└─[^\n]*┘', '', cleaned, flags=re.DOTALL)
    cleaned = re.sub(r'╭─[^\n]*╮\s*\n', '', cleaned)
    cleaned = re.sub(r'\n╰─[^\n]*╯', '', cleaned)
    cleaned = re.sub(r'<think>.*?</think>', '', cleaned, flags=re.DOTALL)
    cleaned = re.sub(r'^[╭┌└╰]─+[^\n]*\n?', '', cleaned, flags=re.MULTILINE)
    cleaned = re.sub(r'─{10,}', '', cleaned)

    return cleaned.strip() or "Varatron is ready.", session_id

def validate_device_key(key: str) -> tuple[bool, str, str]:
    if not key:
        return False, "", ""
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("SELECT email, is_active, name FROM device_keys WHERE key = ?", (key,))
    row = c.fetchone()
    if row and row[1] == 1:
        email = row[0]
        name = row[2] or resolve_user_profile(email)["name"]
        c.execute("UPDATE device_keys SET last_used_at = CURRENT_TIMESTAMP WHERE key = ?", (key,))
        conn.commit()
        conn.close()
        return True, email, name
    conn.close()
    return False, "", ""

def register_device(email: str, name: str = "", device_info: str = "Web Browser") -> str:
    key = f"vk_{uuid.uuid4().hex}"
    if not name:
        name = resolve_user_profile(email)["name"]
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("INSERT INTO device_keys (key, email, name, device_info) VALUES (?, ?, ?, ?)",
              (key, email.lower().strip(), name, device_info))
    conn.commit()
    conn.close()
    return key

HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
  <title>Varatron · Project Vara</title>
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
  <style>
    :root {
      --bg: #090d16;
      --card: #131b2e;
      --card-border: #1e293b;
      --user-bubble: #2563eb;
      --bot-bubble: #172136;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #38bdf8;
      --accent-glow: rgba(56, 189, 248, 0.25);
    }
    * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
      height: 100dvh;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    header {
      background: rgba(19, 27, 46, 0.9);
      backdrop-filter: blur(12px);
      border-bottom: 1px solid var(--card-border);
      padding: 12px 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      z-index: 10;
    }
    .brand { display: flex; align-items: center; gap: 12px; }
    .avatar {
      width: 38px; height: 38px; border-radius: 10px;
      background: linear-gradient(135deg, #38bdf8, #6366f1);
      display: flex; align-items: center; justify-content: center;
      font-weight: 800; font-size: 19px; color: #fff;
      box-shadow: 0 0 12px var(--accent-glow);
    }
    .brand-text h1 { font-size: 16px; font-weight: 700; letter-spacing: -0.3px; color: #fff; }
    .brand-text p { font-size: 11px; color: var(--accent); font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
    .header-actions { display: flex; align-items: center; gap: 8px; }
    .auth-badge {
      display: none; align-items: center; gap: 6px;
      font-size: 12px; color: #34d399; background: rgba(52, 211, 153, 0.1);
      padding: 5px 12px; border-radius: 20px; border: 1px solid rgba(52, 211, 153, 0.25);
      font-weight: 600;
    }
    .status-dot { width: 7px; height: 7px; border-radius: 50%; background: #34d399; box-shadow: 0 0 8px #34d399; }
    .btn-icon {
      background: transparent; border: 1px solid var(--card-border); color: var(--text-muted);
      border-radius: 8px; width: 34px; height: 34px; display: flex; align-items: center;
      justify-content: center; cursor: pointer; transition: all 0.2s; font-size: 15px;
    }
    .btn-icon:hover { color: #fff; border-color: var(--accent); background: rgba(56, 189, 248, 0.1); }

    #chat {
      flex: 1; overflow-y: auto; padding: 18px 16px;
      display: flex; flex-direction: column; gap: 16px;
    }
    .msg {
      max-width: 85%; padding: 12px 18px; border-radius: 18px;
      line-height: 1.55; font-size: 14.5px; word-break: break-word;
    }
    .user { align-self: flex-end; background: var(--user-bubble); color: #fff; border-bottom-right-radius: 4px; box-shadow: 0 4px 14px rgba(37, 99, 235, 0.25); }
    .bot { align-self: flex-start; background: var(--bot-bubble); border: 1px solid var(--card-border); border-bottom-left-radius: 4px; color: #f1f5f9; }
    .bot p { margin-bottom: 8px; }
    .bot p:last-child { margin-bottom: 0; }
    .bot ul, .bot ol { padding-left: 20px; margin: 8px 0; }
    .bot strong { color: #fff; font-weight: 700; }
    .bot code { background: rgba(0,0,0,0.35); padding: 2px 6px; border-radius: 4px; font-size: 13px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #38bdf8; }
    .bot pre { background: rgba(0,0,0,0.5); padding: 10px 14px; border-radius: 8px; overflow-x: auto; margin: 8px 0; border: 1px solid #1e293b; }
    .bot pre code { background: none; padding: 0; color: #f8fafc; }

    #typing {
      display: none; align-self: flex-start; background: var(--bot-bubble);
      border: 1px solid var(--card-border); padding: 10px 16px; border-radius: 18px;
      font-size: 12.5px; color: var(--text-muted); align-items: center; gap: 8px;
    }
    .spinner { width: 14px; height: 14px; border: 2px solid var(--accent); border-top-color: transparent; border-radius: 50%; animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }

    .input-bar {
      padding: 12px 16px; background: rgba(19, 27, 46, 0.95);
      border-top: 1px solid var(--card-border); display: flex; gap: 10px; align-items: flex-end;
    }
    textarea {
      flex: 1; background: #0b0f19; border: 1px solid var(--card-border);
      border-radius: 20px; padding: 10px 16px; color: #fff; font-size: 15px;
      outline: none; resize: none; max-height: 120px; line-height: 1.4;
    }
    textarea:focus { border-color: var(--accent); }
    button.send-btn {
      width: 42px; height: 42px; border-radius: 50%; border: none;
      background: linear-gradient(135deg, #38bdf8, #6366f1);
      color: #fff; font-size: 16px; cursor: pointer; display: flex;
      align-items: center; justify-content: center; flex-shrink: 0;
      box-shadow: 0 0 10px var(--accent-glow); transition: transform 0.1s;
    }
    button.send-btn:active { transform: scale(0.95); }

    /* Auth Modal */
    #authModal {
      position: fixed; inset: 0; background: rgba(9, 13, 22, 0.96);
      backdrop-filter: blur(10px);
      display: none; align-items: center; justify-content: center; z-index: 100; padding: 20px;
    }
    .auth-card {
      background: var(--card); border: 1px solid var(--card-border);
      border-radius: 24px; padding: 32px 28px; width: 100%; max-width: 380px;
      text-align: center; box-shadow: 0 12px 40px rgba(0,0,0,0.7);
    }
    .auth-icon {
      width: 54px; height: 54px; border-radius: 16px; margin: 0 auto 16px;
      background: linear-gradient(135deg, #38bdf8, #6366f1);
      display: flex; align-items: center; justify-content: center;
      font-size: 26px; color: #fff; box-shadow: 0 0 20px var(--accent-glow);
    }
    .auth-card h2 { font-size: 19px; font-weight: 700; margin-bottom: 6px; }
    .auth-card p { font-size: 13px; color: var(--text-muted); line-height: 1.45; margin-bottom: 20px; }
    .auth-alert {
      display: none; background: rgba(239, 68, 68, 0.15); border: 1px solid rgba(239, 68, 68, 0.35);
      color: #fca5a5; padding: 10px 14px; border-radius: 10px; font-size: 12.5px;
      margin-bottom: 16px; text-align: left; line-height: 1.4;
    }
    .auth-input {
      width: 100%; padding: 13px 14px; border-radius: 12px;
      border: 1px solid var(--card-border); background: #0b0f19; color: #fff;
      font-size: 15px; outline: none; margin-bottom: 14px; text-align: center;
      transition: border-color 0.2s;
    }
    .auth-input:focus { border-color: var(--accent); }
    .auth-btn {
      width: 100%; padding: 13px; border-radius: 12px; border: none;
      background: linear-gradient(135deg, #38bdf8, #6366f1);
      color: #fff; font-weight: 700; font-size: 14.5px; cursor: pointer;
      box-shadow: 0 4px 14px rgba(56, 189, 248, 0.3); transition: opacity 0.2s;
    }
    .auth-btn:hover { opacity: 0.95; }
    .auth-btn:disabled { opacity: 0.6; cursor: not-allowed; }
    .auth-footer { font-size: 11px; color: #64748b; margin-top: 14px; }
  </style>
</head>
<body>
  <header>
    <div class="brand">
      <div class="avatar">⚡</div>
      <div class="brand-text">
        <h1>Varatron</h1>
        <p>Project Vara Growth CMO</p>
      </div>
    </div>
    <div class="header-actions">
      <div class="auth-badge" id="authBadge" title="Click to view details">
        <div class="status-dot"></div>
        <span id="badgeName">Authorized</span>
      </div>
      <button class="btn-icon" id="newChatBtn" title="New Session"><i class="bi bi-arrow-counterclockwise"></i></button>
      <button class="btn-icon" id="logoutBtn" title="Log Out / Switch User"><i class="bi bi-box-arrow-right"></i></button>
    </div>
  </header>

  <div id="chat">
    <div class="msg bot" id="welcomeMsg">
      <strong>Varatron online.</strong> Ready to strategize on Project Vara, pitch enterprise triage, or map institutional capital. What are we attacking today?
    </div>
    <div id="typing"><div class="spinner"></div> Varatron is thinking...</div>
  </div>

  <div class="input-bar">
    <textarea id="promptInput" rows="1" placeholder="Ask Varatron anything..."></textarea>
    <button class="send-btn" id="sendBtn"><i class="bi bi-arrow-up"></i></button>
  </div>

  <div id="authModal">
    <div class="auth-card">
      <div class="auth-icon">🛡️</div>
      <h2>Varatron Access</h2>
      <p>Enter your official team email address to authenticate. Once verified, this device is authorized permanently.</p>

      <div id="authAlert" class="auth-alert"></div>

      <form id="emailForm" onsubmit="event.preventDefault(); submitEmail();">
        <input type="email" id="emailInput" class="auth-input" placeholder="you@projectvara.com" autocomplete="email" required>
        <button type="submit" class="auth-btn" id="requestBtn">Send Access Code</button>
      </form>

      <form id="codeForm" style="display:none;" onsubmit="event.preventDefault(); submitCode();">
        <p style="font-size:12.5px; color:#38bdf8; margin-bottom:12px;" id="codePrompt">Enter the 6-digit code sent to your email:</p>
        <input type="text" id="codeInput" class="auth-input" placeholder="6-digit code" maxlength="6" inputmode="numeric" required>
        <button type="submit" class="auth-btn" id="verifyBtn">Verify & Authorize Device</button>
        <p class="auth-footer" style="cursor:pointer; text-decoration:underline; margin-top:14px;" id="backBtn">Use different email</p>
      </form>

      <div class="auth-footer">Key stored locally · Zero passwords needed next visit</div>
    </div>
  </div>

  <script>
    let activeSessionId = null;
    let deviceKey = localStorage.getItem("varatron_device_key") || "";
    let userName = localStorage.getItem("varatron_user_name") || "";
    let userEmail = localStorage.getItem("varatron_user_email") || "";

    const authModal = document.getElementById("authModal");
    const authAlert = document.getElementById("authAlert");
    const authBadge = document.getElementById("authBadge");
    const badgeName = document.getElementById("badgeName");
    const emailForm = document.getElementById("emailForm");
    const codeForm = document.getElementById("codeForm");
    const emailInput = document.getElementById("emailInput");
    const codeInput = document.getElementById("codeInput");
    const requestBtn = document.getElementById("requestBtn");
    const verifyBtn = document.getElementById("verifyBtn");
    const backBtn = document.getElementById("backBtn");
    const chat = document.getElementById("chat");
    const typing = document.getElementById("typing");
    const promptInput = document.getElementById("promptInput");
    const sendBtn = document.getElementById("sendBtn");
    const newChatBtn = document.getElementById("newChatBtn");
    const logoutBtn = document.getElementById("logoutBtn");
    const welcomeMsg = document.getElementById("welcomeMsg");

    function showAlert(text) {
      authAlert.innerText = text;
      authAlert.style.display = "block";
    }

    function clearAlert() {
      authAlert.innerText = "";
      authAlert.style.display = "none";
    }

    async function checkAuth() {
      if (!deviceKey) {
        authModal.style.display = "flex";
        setTimeout(() => emailInput.focus(), 100);
        return;
      }

      try {
        const res = await fetch("/api/auth/verify-device", {
          headers: { "X-Device-Key": deviceKey }
        });
        const data = await res.json();
        if (data.valid) {
          authModal.style.display = "none";
          authBadge.style.display = "flex";
          userName = data.name || "Associate";
          userEmail = data.email || "";
          badgeName.innerText = userName;
          authBadge.title = userEmail;
          welcomeMsg.innerHTML = `<strong>Varatron online.</strong> Good to have you, <strong>${userName}</strong>. Ready to strategize on Project Vara, pitch enterprise triage, or map institutional capital. What are we attacking today?`;
        } else {
          localStorage.removeItem("varatron_device_key");
          localStorage.removeItem("varatron_user_name");
          localStorage.removeItem("varatron_user_email");
          deviceKey = "";
          authModal.style.display = "flex";
          setTimeout(() => emailInput.focus(), 100);
        }
      } catch (err) {
        authModal.style.display = "none";
      }
    }

    async function submitEmail() {
      const val = emailInput.value.trim().toLowerCase();
      if (!val) return;

      clearAlert();
      requestBtn.innerText = "Sending Code...";
      requestBtn.disabled = true;

      try {
        const res = await fetch("/api/auth/request-code", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({ email: val })
        });
        const data = await res.json();
        requestBtn.innerText = "Send Access Code";
        requestBtn.disabled = false;

        if (data.status === "ok") {
          emailForm.style.display = "none";
          codeForm.style.display = "block";
          document.getElementById("codePrompt").innerText = `Enter the 6-digit code sent to ${val}:`;
          setTimeout(() => codeInput.focus(), 100);
        } else {
          showAlert(data.error || "Unable to send authorization code.");
        }
      } catch (err) {
        requestBtn.innerText = "Send Access Code";
        requestBtn.disabled = false;
        showAlert("Network error connecting to verification server.");
      }
    }

    async function submitCode() {
      const email = emailInput.value.trim().toLowerCase();
      const code = codeInput.value.trim();
      if (!code) return;

      clearAlert();
      verifyBtn.innerText = "Verifying...";
      verifyBtn.disabled = true;

      try {
        const res = await fetch("/api/auth/verify-code", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({ email, code })
        });
        const data = await res.json();
        verifyBtn.innerText = "Verify & Authorize Device";
        verifyBtn.disabled = false;

        if (data.status === "ok") {
          deviceKey = data.device_key;
          userName = data.name || "Associate";
          userEmail = data.email || email;

          localStorage.setItem("varatron_device_key", deviceKey);
          localStorage.setItem("varatron_user_name", userName);
          localStorage.setItem("varatron_user_email", userEmail);

          authModal.style.display = "none";
          authBadge.style.display = "flex";
          badgeName.innerText = userName;
          authBadge.title = userEmail;
          welcomeMsg.innerHTML = `<strong>Varatron online.</strong> Welcome aboard, <strong>${userName}</strong>! Ready to strategize on Project Vara, pitch enterprise triage, or map institutional capital. What are we attacking today?`;
        } else {
          showAlert(data.error || "Invalid verification code.");
        }
      } catch (err) {
        verifyBtn.innerText = "Verify & Authorize Device";
        verifyBtn.disabled = false;
        showAlert("Network error during code verification.");
      }
    }

    backBtn.addEventListener("click", () => {
      clearAlert();
      codeForm.style.display = "none";
      emailForm.style.display = "block";
      emailInput.focus();
    });

    logoutBtn.addEventListener("click", () => {
      if (confirm("Log out of this device?")) {
        localStorage.removeItem("varatron_device_key");
        localStorage.removeItem("varatron_user_name");
        localStorage.removeItem("varatron_user_email");
        location.reload();
      }
    });

    function appendMessage(text, isUser = false) {
      const msg = document.createElement("div");
      msg.className = "msg " + (isUser ? "user" : "bot");
      if (isUser) {
        msg.innerText = text;
      } else {
        msg.innerHTML = marked.parse(text);
      }
      chat.insertBefore(msg, typing);
      chat.scrollTop = chat.scrollHeight;
    }

    async function sendMessage() {
      const text = promptInput.value.trim();
      if (!text) return;
      promptInput.value = "";
      promptInput.style.height = "auto";

      appendMessage(text, true);
      typing.style.display = "flex";
      chat.scrollTop = chat.scrollHeight;

      try {
        const res = await fetch("/api/chat", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Device-Key": deviceKey
          },
          body: JSON.stringify({
            prompt: text,
            session_id: activeSessionId
          })
        });

        if (res.status === 401) {
          authModal.style.display = "flex";
          typing.style.display = "none";
          return;
        }

        const data = await res.json();
        typing.style.display = "none";
        if (data.session_id) activeSessionId = data.session_id;
        appendMessage(data.response || "Varatron is ready.");
      } catch (err) {
        typing.style.display = "none";
        appendMessage("⚠️ Connection error. Please try again.");
      }
    }

    sendBtn.addEventListener("click", sendMessage);
    promptInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        sendMessage();
      }
    });

    promptInput.addEventListener("input", function() {
      this.style.height = "auto";
      this.style.height = Math.min(this.scrollHeight, 120) + "px";
    });

    newChatBtn.addEventListener("click", () => {
      activeSessionId = null;
      while (chat.children.length > 2) {
        chat.removeChild(chat.firstChild);
      }
      appendMessage(`✨ Starting fresh discussion thread. What's on deck, ${userName}?`, false);
    });

    checkAuth();
  </script>
</body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(HTML_PAGE)

@app.route("/api/auth/verify-device", methods=["GET"])
def verify_device():
    key = request.headers.get("X-Device-Key") or request.args.get("key", "")
    valid, email, name = validate_device_key(key)
    return jsonify({"valid": valid, "email": email, "name": name})

@app.route("/api/auth/request-code", methods=["POST"])
def request_code():
    data = request.get_json() or {}
    email = data.get("email", "").strip().lower()
    if not email:
        return jsonify({"status": "error", "error": "Email is required."}), 400

    if not is_allowed_email(email):
        return jsonify({
            "status": "error",
            "error": "Access restricted. Please use an authorized @projectvara.com, @edvara.com, or @zenzig.com address."
        }), 400

    profile = resolve_user_profile(email)
    user_name = profile["name"]

    code = f"{uuid.uuid4().int % 900000 + 100000}"
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=15)

    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("INSERT INTO otp_codes (code, email, expires_at) VALUES (?, ?, ?)",
              (code, email, expires_at.strftime("%Y-%m-%d %H:%M:%S")))
    conn.commit()
    conn.close()

    # Dispatch Email via Node1 Postfix
    cfg = get_smtp_config()
    try:
        msg = MIMEMultipart("alternative")
        msg["Date"] = formatdate(localtime=True)
        msg["Message-ID"] = make_msgid(domain="projectvara.com")
        msg["Subject"] = f"Your Varatron Access Code: {code}"
        msg["From"] = cfg.get("from", "varatron@projectvara.com")
        msg["To"] = email

        text_content = f"Hi {user_name},\n\nYour Varatron verification code is: {code}\n\nThis code expires in 15 minutes.\n\n— Varatron"
        html_content = f"""
        <div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif; background:#090d16; color:#f8fafc; padding:32px; border-radius:14px; max-width:480px; border:1px solid #1e293b;">
          <div style="display:flex; align-items:center; gap:10px; margin-bottom:16px;">
            <div style="width:36px; height:36px; border-radius:10px; background:linear-gradient(135deg,#38bdf8,#6366f1); display:flex; align-items:center; justify-content:center; font-weight:800; font-size:18px; color:#fff; text-align:center; line-height:36px;">⚡</div>
            <h2 style="color:#38bdf8; margin:0; font-size:18px;">Varatron Authorization</h2>
          </div>
          <p style="font-size:15px; margin:0 0 12px 0;">Hi <strong>{user_name}</strong>,</p>
          <p style="font-size:14px; color:#94a3b8; line-height:1.5; margin:0 0 20px 0;">Here is your one-time device verification code to access the Varatron Executive Gateway:</p>
          <div style="font-size:32px; font-weight:800; letter-spacing:8px; background:#131b2e; border:1px solid #1e293b; padding:18px; border-radius:10px; text-align:center; color:#38bdf8; margin:20px 0;">
            {code}
          </div>
          <p style="font-size:12px; color:#64748b; line-height:1.4; margin:0;">Entering this code will securely bind this device to your identity ({email}). Subsequent visits will recognize you automatically with zero passwords.</p>
        </div>
        """
        msg.attach(MIMEText(text_content, "plain"))
        msg.attach(MIMEText(html_content, "html"))

        host = cfg.get("host", "mail.zenzig.com")
        port = int(cfg.get("port", 465))
        user = cfg.get("user", "varatron@projectvara.com")
        password = cfg.get("password", "")

        import ssl
        context = ssl.create_default_context()
        with smtplib.SMTP_SSL(host, port, context=context, timeout=12) as s:
            if password:
                s.login(user, password)
            s.sendmail(user, [email], msg.as_string())

        return jsonify({"status": "ok"})
    except Exception as e:
        return jsonify({"status": "error", "error": f"Mail dispatch failed: {str(e)}"}), 500

@app.route("/api/auth/verify-code", methods=["POST"])
def verify_code():
    data = request.get_json() or {}
    email = data.get("email", "").strip().lower()
    code = data.get("code", "").strip()

    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("SELECT expires_at, used FROM otp_codes WHERE code = ? AND email = ?", (code, email))
    row = c.fetchone()
    if not row:
        conn.close()
        return jsonify({"status": "error", "error": "Invalid verification code."}), 400

    expires_at_dt = datetime.strptime(row[0].split(".")[0], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    if datetime.now(timezone.utc) > expires_at_dt or row[1] == 1:
        conn.close()
        return jsonify({"status": "error", "error": "Code has expired or already been used."}), 400

    c.execute("UPDATE otp_codes SET used = 1 WHERE code = ?", (code,))
    conn.commit()
    conn.close()

    profile = resolve_user_profile(email)
    user_name = profile["name"]
    device_key = register_device(email, name=user_name, device_info=request.headers.get("User-Agent", "Web Browser"))
    return jsonify({"status": "ok", "device_key": device_key, "email": email, "name": user_name})

@app.route("/api/chat", methods=["POST"])
def chat():
    # Verify Device Key
    key = request.headers.get("X-Device-Key", "")
    valid, email, name = validate_device_key(key)
    if not valid:
        return jsonify({"status": "unauthorized", "error": "Invalid or missing device authorization key."}), 401

    data = request.get_json() or {}
    prompt = data.get("prompt", "").strip()
    session_id = data.get("session_id")

    if not prompt:
        return jsonify({"status": "error", "error": "Empty prompt"}), 400

    profile = resolve_user_profile(email)
    
    # Inject user identity into prompt turn so Varatron addresses them directly by name
    personalized_prompt = f"[User: {profile['name']} ({profile['full_name']}), {profile['role']} - {email}]\n\n{prompt}"

    cmd = [
        HERMES_BIN,
        "chat",
        "-q", personalized_prompt,
        "-Q",
        "--reasoning", "none",
        "--source", "varatron-web"
    ]

    if session_id:
        cmd.extend(["--resume", session_id])

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        raw_output = proc.stdout
        if proc.returncode != 0 and not raw_output:
            raw_output = proc.stderr or "Error running Hermes"

        clean_text, new_session_id = clean_hermes_output(raw_output)
        return jsonify({
            "status": "ok",
            "response": clean_text,
            "session_id": new_session_id or session_id
        })
    except subprocess.TimeoutExpired:
        return jsonify({"status": "timeout", "response": "Request timed out after 120 seconds."}), 504
    except Exception as e:
        return jsonify({"status": "error", "response": f"Server error: {str(e)}"}), 500

if __name__ == "__main__":
    ssl_context = (CERT_FILE, KEY_FILE) if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE) else None
    app.run(host="0.0.0.0", port=8080, ssl_context=ssl_context)
