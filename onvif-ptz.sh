#!/usr/bin/env bash
# Minimal ONVIF PTZ client for Tapo cameras, using only curl + openssl (no
# python/onvif libraries required). Speaks WS-Security UsernameToken auth
# directly since that's all the camera's tiny embedded ONVIF service needs.
#
# Usage:
#   onvif-ptz.sh move <host> <user> <password> <up|down|left|right>
#   onvif-ptz.sh stop <host> <user> <password>
#
# Talks to http://<host>:2020/onvif/service (the standard Tapo ONVIF port),
# profile "profile_1" (the only profile Tapo cameras expose).
set -euo pipefail

cmd="${1:?command required}"
host="${2:?host required}"
user="${3:?user required}"
pass="${4:?password required}"
url="http://${host}:2020/onvif/service"

# WS-Security PasswordDigest = Base64(SHA1(nonce_bytes || created || password)).
# Built from files, not bash string concatenation, since the random nonce is
# raw binary and bash strings truncate at embedded NUL bytes.
soap_request() {
  local body="$1"
  local nonce_file created digest nonce_b64
  nonce_file=$(mktemp)
  trap 'rm -f "$nonce_file"' RETURN
  openssl rand 16 > "$nonce_file"
  nonce_b64=$(openssl base64 -A -in "$nonce_file")
  created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  digest=$(cat "$nonce_file" <(printf '%s' "${created}${pass}") \
    | openssl dgst -sha1 -binary | openssl base64 -A)

  curl -s --max-time 6 -X POST "$url" \
    -H "Content-Type: application/soap+xml; charset=utf-8" \
    -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">
<s:Header>
<Security xmlns=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd\">
<UsernameToken>
<Username>${user}</Username>
<Password Type=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest\">${digest}</Password>
<Nonce EncodingType=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary\">${nonce_b64}</Nonce>
<Created xmlns=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\">${created}</Created>
</UsernameToken>
</Security>
</s:Header>
<s:Body>
${body}
</s:Body>
</s:Envelope>"
}

case "$cmd" in
  move)
    direction="${5:?direction required (up|down|left|right)}"
    # Full velocity: smaller magnitudes were unreliable in testing — the
    # camera needs a strong-enough signal to actually move at all.
    case "$direction" in
      up)    x=0;  y=1  ;;
      down)  x=0;  y=-1 ;;
      left)  x=-1; y=0  ;;
      right) x=1;  y=0  ;;
      *) echo "unknown direction: $direction" >&2; exit 1 ;;
    esac
    soap_request "<ContinuousMove xmlns=\"http://www.onvif.org/ver20/ptz/wsdl\">
<ProfileToken>profile_1</ProfileToken>
<Velocity><PanTilt xmlns=\"http://www.onvif.org/ver10/schema\" x=\"${x}\" y=\"${y}\"/></Velocity>
</ContinuousMove>" > /dev/null
    ;;
  stop)
    soap_request "<Stop xmlns=\"http://www.onvif.org/ver20/ptz/wsdl\">
<ProfileToken>profile_1</ProfileToken>
<PanTilt>true</PanTilt>
</Stop>" > /dev/null
    ;;
  *)
    echo "unknown command: $cmd" >&2
    exit 1
    ;;
esac
