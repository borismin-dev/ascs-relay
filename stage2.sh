#!/bin/bash
# ASCS Micro stage 2: install Xray + Hysteria2 via GitHub Pages relay (the VM is IPv6-only
# and cannot reach github.com directly), then fix cloudflared for IPv6-only egress.
exec > /var/log/ascs-stage2.log 2>&1
set -x
BASE=https://borismin-dev.github.io/ascs-relay
XRAY_SHA=b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82
HY2_SHA=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691

. /root/vpn/creds.txt

# ---------- Xray ----------
curl -fsSL $BASE/xray.zip -o /root/xray.zip
echo "$XRAY_SHA  /root/xray.zip" | sha256sum -c -
rm -rf /tmp/xrayx && mkdir -p /tmp/xrayx
unzip -o /root/xray.zip -d /tmp/xrayx >/dev/null
install -m 755 /tmp/xrayx/xray /usr/local/bin/xray
mkdir -p /usr/local/share/xray
cp -f /tmp/xrayx/geoip.dat /tmp/xrayx/geosite.dat /usr/local/share/xray/ 2>/dev/null || true

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable xray 2>/dev/null
systemctl restart xray
sleep 2
systemctl is-active xray

# ---------- Hysteria2 ----------
curl -fsSL $BASE/hysteria -o /usr/local/bin/hysteria
echo "$HY2_SHA  /usr/local/bin/hysteria" | sha256sum -c -
chmod 755 /usr/local/bin/hysteria
if [ ! -f /root/vpn/hy2.crt ]; then
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /root/vpn/hy2.key -out /root/vpn/hy2.crt -subj "/CN=www.bing.com" -days 3650 2>/dev/null
fi
if ! grep -q HY2_PASSWORD /root/vpn/creds.txt; then
  echo "HY2_PASSWORD=$(openssl rand -hex 16)" >> /root/vpn/creds.txt
fi
. /root/vpn/creds.txt
mkdir -p /etc/hysteria
cat > /etc/hysteria/config.yaml <<EOF
listen: :443
tls:
  cert: /root/vpn/hy2.crt
  key: /root/vpn/hy2.key
auth:
  type: password
  password: $HY2_PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
cat > /etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria2 Server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hysteria-server 2>/dev/null
systemctl restart hysteria-server
sleep 2
systemctl is-active hysteria-server

# ---------- cloudflared: force IPv6 edge ----------
UNIT=/etc/systemd/system/cf-tunnel.service
if ! grep -q 'edge-ip-version' $UNIT; then
  sed -i 's/tunnel /tunnel --edge-ip-version 6 /' $UNIT
fi
rm -f /root/vpn/cf.log
systemctl daemon-reload
systemctl restart cf-tunnel
sleep 12
if ! grep -q 'Registered tunnel connection' /root/vpn/cf.log; then
  sed -i 's/--edge-ip-version 6/--edge-ip-version 6 --protocol http2/' $UNIT
  rm -f /root/vpn/cf.log
  systemctl daemon-reload
  systemctl restart cf-tunnel
  sleep 12
fi
grep -E 'Registered tunnel connection|ERR' /root/vpn/cf.log | tail -5
D=""
for i in $(seq 1 20); do
  D=$(grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' /root/vpn/cf.log 2>/dev/null | tail -1)
  [ -n "$D" ] && break
  sleep 3
done
echo "tunnel_domain=$D"

# ---------- regenerate node links ----------
IP6=$(ip -6 addr show scope global | grep -o 'inet6 [0-9a-f:]*' | awk '{print $2}' | head -1)
{
  echo "vless://$UUID@${D#https://}:443?encryption=none&security=tls&type=ws&host=${D#https://}&path=%2Fvless#ASCS-VLESS-CF"
  echo "hysteria2://$HY2_PASSWORD@[$IP6]:443?insecure=1&sni=www.bing.com#ASCS-HY2-V6"
} > /root/vpn/nodes.txt
chmod 600 /root/vpn/nodes.txt /root/vpn/creds.txt
echo "=== STAGE2 DONE ==="
systemctl is-active xray cf-tunnel hysteria-server
cat /root/vpn/nodes.txt
