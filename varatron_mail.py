#!/usr/bin/env python3
"""
Varatron Mail CLI: Secure IMAP/SMTP tool for Varatron (Project Vara CMO)
Reads credentials from /home/rich/.secrets/varatron-mail.env
"""

import os
import sys
import argparse
import json
import smtplib
import imaplib
import email
import ssl
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.utils import formatdate, make_msgid
from email.header import decode_header

ENV_PATH = os.path.expanduser("~/.secrets/varatron-mail.env")

def load_config():
    cfg = {
        "user": "varatron@projectvara.com",
        "pass": "",
        "smtp_host": "mail.zenzig.com",
        "smtp_port": 465,
        "imap_host": "mail.zenzig.com",
        "imap_port": 993,
    }
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.split("#")[0].strip()
                    if k == "MAIL_USER": cfg["user"] = v
                    elif k == "MAIL_PASS": cfg["pass"] = v
                    elif k == "SMTP_HOST": cfg["smtp_host"] = v
                    elif k == "SMTP_PORT": cfg["smtp_port"] = int(v)
                    elif k == "IMAP_HOST": cfg["imap_host"] = v
                    elif k == "IMAP_PORT": cfg["imap_port"] = int(v)
    return cfg

def decode_mime_words(s):
    if not s:
        return ""
    decoded_fragments = decode_header(s)
    out = []
    for frag, enc in decoded_fragments:
        if isinstance(frag, bytes):
            out.append(frag.decode(enc or "utf-8", errors="replace"))
        else:
            out.append(str(frag))
    return "".join(out)

def send_email(to_addr, subject, body, html_body=None):
    cfg = load_config()
    if not cfg["pass"]:
        print(json.dumps({"error": "MAIL_PASS not found in ~/.secrets/varatron-mail.env"}))
        sys.exit(1)

    # Clean to_addr
    to_addr = to_addr.strip()
    if "," in to_addr or ";" in to_addr:
        print(json.dumps({"error": "Only one-to-one individual recipient allowed to preserve domain reputation."}))
        sys.exit(1)

    msg = MIMEMultipart("alternative") if html_body else MIMEText(body, "plain", "utf-8")
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain="projectvara.com")
    msg["Subject"] = subject
    msg["From"] = f"Varatron <{cfg['user']}>"
    msg["To"] = to_addr

    if html_body:
        msg.attach(MIMEText(body, "plain", "utf-8"))
        msg.attach(MIMEText(html_body, "html", "utf-8"))

    context = ssl.create_default_context()
    try:
        with smtplib.SMTP_SSL(cfg["smtp_host"], cfg["smtp_port"], context=context, timeout=15) as s:
            s.login(cfg["user"], cfg["pass"])
            s.sendmail(cfg["user"], [to_addr], msg.as_string())
        print(json.dumps({
            "status": "success",
            "from": cfg["user"],
            "to": to_addr,
            "subject": subject,
            "message_id": msg["Message-ID"]
        }))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        sys.exit(1)

def list_inbox(limit=10, unread_only=False):
    cfg = load_config()
    try:
        M = imaplib.IMAP4_SSL(cfg["imap_host"], cfg["imap_port"])
        M.login(cfg["user"], cfg["pass"])
        M.select("INBOX")
        criterion = "UNSEEN" if unread_only else "ALL"
        status, data = M.search(None, criterion)
        
        ids = data[0].split()
        ids = ids[-limit:] # Get newest
        ids.reverse()

        messages = []
        for mid in ids:
            status, msg_data = M.fetch(mid, "(RFC822.HEADER)")
            for response_part in msg_data:
                if isinstance(response_part, tuple):
                    parsed = email.message_from_bytes(response_part[1])
                    messages.append({
                        "id": mid.decode(),
                        "from": decode_mime_words(parsed.get("From", "")),
                        "to": decode_mime_words(parsed.get("To", "")),
                        "subject": decode_mime_words(parsed.get("Subject", "")),
                        "date": parsed.get("Date", "")
                    })
        M.logout()
        print(json.dumps({"status": "success", "count": len(messages), "messages": messages}, indent=2))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        sys.exit(1)

def read_message(msg_id):
    cfg = load_config()
    try:
        M = imaplib.IMAP4_SSL(cfg["imap_host"], cfg["imap_port"])
        M.login(cfg["user"], cfg["pass"])
        M.select("INBOX")
        status, msg_data = M.fetch(str(msg_id).encode(), "(RFC822)")
        if status != "OK" or not msg_data or not msg_data[0]:
            print(json.dumps({"status": "error", "error": f"Message {msg_id} not found."}))
            return

        parsed = email.message_from_bytes(msg_data[0][1])
        body = ""
        if parsed.is_multipart():
            for part in parsed.walk():
                ctype = part.get_content_type()
                cdispo = str(part.get("Content-Disposition"))
                if ctype == "text/plain" and "attachment" not in cdispo:
                    payload = part.get_payload(decode=True)
                    if payload:
                        body = payload.decode(errors="replace")
                        break
        else:
            payload = parsed.get_payload(decode=True)
            if payload:
                body = payload.decode(errors="replace")

        M.logout()
        print(json.dumps({
            "status": "success",
            "id": str(msg_id),
            "from": decode_mime_words(parsed.get("From", "")),
            "subject": decode_mime_words(parsed.get("Subject", "")),
            "date": parsed.get("Date", ""),
            "body": body.strip()
        }, indent=2))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Varatron Mail CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Send
    send_parser = subparsers.add_parser("send", help="Send email")
    send_parser.add_argument("--to", required=True, help="Recipient email")
    send_parser.add_argument("--subject", required=True, help="Subject line")
    send_parser.add_argument("--body", required=True, help="Plaintext body")
    send_parser.add_argument("--html", help="Optional HTML body")

    # Inbox
    inbox_parser = subparsers.add_parser("inbox", help="List inbox messages")
    inbox_parser.add_argument("--limit", type=int, default=10, help="Number of messages to list")
    inbox_parser.add_argument("--unread", action="store_true", help="Only list unread messages")

    # Read
    read_parser = subparsers.add_parser("read", help="Read message body by ID")
    read_parser.add_argument("--id", required=True, help="Message ID")

    args = parser.parse_args()
    if args.command == "send":
        send_email(args.to, args.subject, args.body, args.html)
    elif args.command == "inbox":
        list_inbox(args.limit, args.unread)
    elif args.command == "read":
        read_message(args.id)

if __name__ == "__main__":
    main()
