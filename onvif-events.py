#!/usr/bin/env python3
"""
Long-running ONVIF motion/person/vehicle/pet detection listener for a
single Tapo camera. Prints one JSON line per detection event to stdout
(unbuffered) and otherwise runs forever, reconnecting on any error.

Usage:
    ONVIF_PASSWORD=<password> onvif-events.py <host> <user>

The password comes from the environment, not argv, for the same reason
onvif-ptz.sh does: command-line arguments end up in /proc/<pid>/cmdline,
which is world-readable, and this process runs for as long as the plugin
does.

Uses ONVIF's standard Events/PullPoint mechanism (CreatePullPointSubscription
+ repeated long-polling PullMessages calls) -- the same local, no-cloud-
account mechanism Home Assistant's Tapo integration uses for motion
sensors. Person/pet/vehicle *classification* on top of plain motion is a
vendor extension in ONVIF terms; this makes a best effort to recognize it
from the notification topic and falls back to generic "motion" if it
doesn't recognize the shape, but hasn't been verified against a real Tapo
camera's actual event topics/schema -- test against real hardware before
relying on it.
"""
import base64
import hashlib
import os
import re
import signal
import sys
import time
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET

HOST = sys.argv[1] if len(sys.argv) > 1 else None
USER = sys.argv[2] if len(sys.argv) > 2 else None
PASSWORD = os.environ.get("ONVIF_PASSWORD")

if not HOST or not USER or not PASSWORD:
    print("Usage: ONVIF_PASSWORD=<password> onvif-events.py <host> <user>", file=sys.stderr)
    sys.exit(1)

BASE_URL = f"http://{HOST}:2020/onvif/service"
NS = {
    "s": "http://www.w3.org/2003/05/soap-envelope",
    "tev": "http://www.onvif.org/ver10/events/wsdl",
    "wsnt": "http://docs.oasis-open.org/wsn/b-2",
    "wsa": "http://www.w3.org/2005/08/addressing",
    "tt": "http://www.onvif.org/ver10/schema",
}


def ws_security_header():
    nonce = os.urandom(16)
    created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    digest = base64.b64encode(
        hashlib.sha1(nonce + created.encode() + PASSWORD.encode()).digest()
    ).decode()
    nonce_b64 = base64.b64encode(nonce).decode()
    return f"""<Security xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
<UsernameToken>
<Username>{USER}</Username>
<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest}</Password>
<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{nonce_b64}</Nonce>
<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">{created}</Created>
</UsernameToken>
</Security>"""


def soap_call(url, body, timeout=25):
    envelope = f"""<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>{ws_security_header()}</s:Header>
<s:Body>{body}</s:Body>
</s:Envelope>"""
    req = urllib.request.Request(
        url, data=envelope.encode("utf-8"), method="POST",
        headers={"Content-Type": "application/soap+xml; charset=utf-8"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return ET.fromstring(resp.read())


def create_subscription():
    body = ('<tev:CreatePullPointSubscription xmlns:tev="http://www.onvif.org/ver10/events/wsdl">'
            '<tev:InitialTerminationTime>PT10M</tev:InitialTerminationTime>'
            '</tev:CreatePullPointSubscription>')
    root = soap_call(BASE_URL, body)
    address_el = root.find(".//wsa:Address", NS)
    if address_el is None or not address_el.text:
        raise RuntimeError("No SubscriptionReference/Address in CreatePullPointSubscription response")
    address = address_el.text.strip()
    # Some cameras return a bare path or a reference that doesn't include
    # the real host (embedded ONVIF stacks are often sloppy about this) --
    # fall back to the main service URL if it doesn't look usable.
    if not address.startswith("http"):
        address = BASE_URL
    return address


DETECTION_KEYWORDS = [
    (re.compile(r"people|human|person", re.I), "Person"),
    (re.compile(r"vehicle|car", re.I), "Vehicle"),
    (re.compile(r"pet|animal", re.I), "Pet"),
    (re.compile(r"motion|cellmotion", re.I), "Motion"),
]


def classify_topic(topic_text):
    for pattern, label in DETECTION_KEYWORDS:
        if pattern.search(topic_text or ""):
            return label
    return "Motion"


def is_detection_true(message_el):
    for item in message_el.findall(".//tt:SimpleItem", NS):
        value = (item.get("Value") or "").strip().lower()
        if value in ("true", "1"):
            return True
    return False


def unsubscribe(address):
    # Best-effort: this embedded camera's ONVIF stack appears to only allow
    # a small number of concurrent PullPoint subscriptions (observed a 400
    # on CreatePullPointSubscription after two earlier ones were left open
    # rather than explicitly torn down), so leaving one dangling on every
    # reconnect/restart would eventually lock this camera's events out
    # entirely -- worth trying even if it fails, never worth crashing over.
    try:
        soap_call(address, '<wsnt:Unsubscribe xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"/>', timeout=5)
    except Exception:
        pass


def poll_loop(subscription_address):
    body = ('<tev:PullMessages xmlns:tev="http://www.onvif.org/ver10/events/wsdl">'
            '<tev:Timeout>PT20S</tev:Timeout>'
            '<tev:MessageLimit>50</tev:MessageLimit>'
            '</tev:PullMessages>')
    while True:
        root = soap_call(subscription_address, body, timeout=30)
        for notif in root.findall(".//wsnt:NotificationMessage", NS):
            topic_el = notif.find("wsnt:Topic", NS)
            topic_text = topic_el.text if topic_el is not None else ""
            message_el = notif.find(".//tt:Message", NS) or notif
            if is_detection_true(message_el):
                label = classify_topic(topic_text)
                print(label, flush=True)


current_address = [None]  # single-element list: mutable from the signal handler's closure


def handle_shutdown(signum, frame):
    if current_address[0]:
        unsubscribe(current_address[0])
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)

    backoff = 5
    while True:
        try:
            address = create_subscription()
            current_address[0] = address
            backoff = 5  # reset after a successful (re)connect
            poll_loop(address)
        except (urllib.error.URLError, ET.ParseError, RuntimeError, OSError, TimeoutError) as e:
            print(f"[retrying in {backoff}s: {e}]", file=sys.stderr, flush=True)
            if current_address[0]:
                unsubscribe(current_address[0])
                current_address[0] = None
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    main()
