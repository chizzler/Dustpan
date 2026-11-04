#!/usr/bin/env bash
# Install or update the OpenTodo server on your own server, behind its Caddy.
#   deploy/deploy.sh          install the pinned release, the unit and the Caddy site, then restart
#   deploy/deploy.sh --setup  first run only: firewall, setup token, then the above
# The server downloads the release itself and checks it against the sum pinned here.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# HOST (an ssh destination) and DOMAIN come from deploy/deploy.env, which git ignores. See deploy.env.example.
# shellcheck source=/dev/null
[[ -f $HERE/deploy.env ]] && source "$HERE/deploy.env"
VERSION=v0.22.0
ASSET=opentodo-linux-amd64
SHA256=74c8b2276e315c2428dee06433efe361599cb3482e384ca6f3e02a6871119c9b
URL=https://github.com/OpenTodoApp/OpenTodo/releases/download/$VERSION/$ASSET

[[ -n ${HOST:-} && -n ${DOMAIN:-} ]] || { echo "Set HOST and DOMAIN in $HERE/deploy.env first." >&2; exit 1; }

if [[ ${1:-} == --setup ]]; then
  ssh "$HOST" bash -s <<EOF
set -euo pipefail
# Allow SSH before turning the firewall on, so this session survives.
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable
# The setup token guards the owner account until you create it. Made here, never stored in git.
mkdir -p /etc/opentodo
if [[ ! -f /etc/opentodo/env ]]; then
  umask 077
  printf 'OPENTODO_BASE_URL=https://%s\nOPENTODO_SETUP_TOKEN=%s\n' "$DOMAIN" "\$(openssl rand -hex 24)" > /etc/opentodo/env
fi
EOF
fi

ssh "$HOST" bash -s <<EOF
set -euo pipefail
dir=/opt/opentodo/$VERSION
if [[ ! -x \$dir/$ASSET ]]; then
  mkdir -p \$dir
  curl -fsSL -o \$dir/$ASSET.part "$URL"
  echo "$SHA256  \$dir/$ASSET.part" | sha256sum -c --quiet -
  chmod 755 \$dir/$ASSET.part
  mv \$dir/$ASSET.part \$dir/$ASSET
fi
ln -sfn \$dir /opt/opentodo/current
EOF

scp -q "$HERE/opentodo.service" "$HOST:/etc/systemd/system/opentodo.service"
sed "s/^DOMAIN {/$DOMAIN {/" "$HERE/dustpan.caddy" | ssh "$HOST" "mkdir -p /etc/caddy/sites && cat > /etc/caddy/sites/dustpan.caddy"

# Each site lives in its own file. If something else writes the main Caddyfile, give it this import line too.
ssh "$HOST" bash -s <<'EOF'
set -euo pipefail
grep -q '^import /etc/caddy/sites/\*.caddy' /etc/caddy/Caddyfile ||
  printf '\n# Other projects add their sites here.\nimport /etc/caddy/sites/*.caddy\n' >> /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --quiet opentodo
systemctl restart opentodo
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl reload caddy
EOF

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if version=$(curl -fsS "https://$DOMAIN/healthz" 2>/dev/null); then
    echo "Live at https://$DOMAIN/ ($version)"
    exit 0
  fi
  sleep 3
done
echo "https://$DOMAIN/healthz didn't answer. Check: ssh $HOST journalctl -u opentodo -u caddy -n 50" >&2
exit 1
