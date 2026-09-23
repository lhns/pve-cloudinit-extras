#!/usr/bin/env python3
"""Parse a vendor snippet the way cloud-init does (email + yaml.safe_load); print JSON."""
import email
import json
import sys

import yaml

raw = open(sys.argv[1], "rb").read().decode("utf-8")
assert "mime-version:" in raw[:4096].lower()  # cloud-init's multipart detection
msg = email.message_from_string(raw)
parts = []
for p in msg.walk():
    if p.is_multipart():
        continue
    ctype = p.get_content_type()
    body = p.get_payload(decode=True).decode("utf-8")
    entry = {"type": ctype, "source": p.get("X-PVE-Source")}
    if ctype == "text/cloud-config":
        entry["config"] = yaml.safe_load(body)
    else:
        entry["body"] = body
    parts.append(entry)
print(json.dumps({"managed": msg.get("X-Managed-By"), "parts": parts}))
