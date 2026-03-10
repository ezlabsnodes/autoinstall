#!/bin/bash

echo "======================================================="
echo " SETUP PACKETSTREAM DOCKER + REDSOCKS (FOR GO BINARIES) "
echo "======================================================="
read -p "Masukkan Proxy (Format -> IP:PORT:USER:PASS): " PROXY_INPUT
read -p "Masukkan CID PacketStream kamu : " CID_INPUT
CID_INPUT=${CID_INPUT:-7vhQ}

IFS=':' read -r PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS <<< "$PROXY_INPUT"

if [[ -z "$PROXY_IP" || -z "$PROXY_PORT" || -z "$PROXY_USER" || -z "$PROXY_PASS" ]]; then
    echo "Error: Format input proxy salah."
    exit 1
fi

echo "=== 1. MENGHENTIKAN CONTAINER LAMA ==="
sudo docker stop psclient watchtower 2>/dev/null
sudo docker rm psclient watchtower 2>/dev/null

echo "=== 2. MENYIAPKAN WORKSPACE ==="
mkdir -p ~/psclient-redsocks && cd ~/psclient-redsocks

echo "=== 3. MEMBUAT REDSOCKS CONFIG TEMPLATE ==="
cat > redsocks.conf <<EOF
base {
    log_debug = off;
    log_info = on;
    daemon = on;
    user = root;
    group = root;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = $PROXY_IP;
    port = $PROXY_PORT;
    type = http-connect;
    login = "$PROXY_USER";
    password = "$PROXY_PASS";
}
EOF

echo "=== 4. MEMBUAT ENTRYPOINT SCRIPT ==="
cat > entrypoint.sh <<EOF
#!/bin/bash
redsocks -c /etc/redsocks.conf

sleep 2

iptables -t nat -A OUTPUT -d 127.0.0.0/8 -j RETURN
iptables -t nat -A OUTPUT -d $PROXY_IP -j RETURN
iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports 12345

echo "Starting PacketStream behind Transparent Proxy..."
exec /usr/local/bin/pslauncher "\$@"
EOF
chmod +x entrypoint.sh

echo "=== 5. MEMBUAT DOCKERFILE BARU ==="
cat > Dockerfile <<EOF
FROM packetstream/psclient:latest
USER root

RUN apt-get update && apt-get install -y redsocks iptables && apt-get clean

COPY redsocks.conf /etc/redsocks.conf
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

echo "=== 6. BUILD & RUN CUSTOM IMAGE ==="
sudo docker build -t psclient-redsocks .

sudo docker run -d --restart=always --cap-add=NET_ADMIN -e CID=$CID_INPUT --name psclient psclient-redsocks

echo "=== SETUP COMPLETE! ==="
echo "Menunggu container berjalan (5 detik)..."
sleep 5
echo "---------------------------------------------"
echo "Silakan cek log dengan perintah:"
echo "docker logs psclient"
