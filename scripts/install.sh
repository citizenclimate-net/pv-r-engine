#!/usr/bin/env bash
# One-shot provisioning for the PV Nature R engine on the existing Hetzner box,
# alongside BirdNET-Analyzer. Run as root. Idempotent enough to re-run.
set -euo pipefail

# 1. System dependencies for the spatial R stack (GDAL/PROJ/GEOS/udunits).
apt-get update
apt-get install -y \
  r-base r-base-dev pkg-config \
  gdal-bin libgdal-dev libudunits2-dev libproj-dev libgeos-dev \
  libxml2-dev libcurl4-openssl-dev libssl-dev libsodium-dev \
  nginx certbot python3-certbot-nginx

# 2. Code checkout + R package restore from the pinned renv.lock.
install -d /srv/cc-pv-r
if [ ! -d /srv/cc-pv-r/.git ]; then
  git clone https://github.com/citizenclimate-net/pv-r-engine /srv/cc-pv-r
fi
cd /srv/cc-pv-r
Rscript scripts/restore.R

# 3. Secrets (place these on the box before running):
#    /tmp/firebase-sa.json  — Firebase Admin service-account JSON
#    /tmp/pv-r-api-key       — the X-API-Key shared with Cloud Functions
install -d -m 700 /etc/cc-pv-r
install -m 600 /tmp/firebase-sa.json /etc/cc-pv-r/firebase-sa.json
install -m 600 /tmp/pv-r-api-key     /etc/cc-pv-r/api-key

# 4. Data directories (persistent cache + per-run scratch), backed up by the
#    existing Hetzner snapshot schedule.
install -d /var/lib/cc-pv-r/cache /var/lib/cc-pv-r/runs

# 5. systemd service + nginx vhost.
install -m 644 systemd/pv-r-engine.service /etc/systemd/system/pv-r-engine.service
install -m 644 nginx/cc-pv-r.conf /etc/nginx/sites-available/cc-pv-r.conf
ln -sf /etc/nginx/sites-available/cc-pv-r.conf /etc/nginx/sites-enabled/cc-pv-r.conf

systemctl daemon-reload
systemctl enable --now pv-r-engine.service
nginx -t && systemctl reload nginx

# 6. TLS (same DuckDNS + Let's Encrypt pattern as the BirdNET endpoint):
#    certbot --nginx -d citizenclimate-pv-r.duckdns.org
echo "Done. Run certbot for TLS, then verify: curl -H 'X-API-Key: <key>' https://citizenclimate-pv-r.duckdns.org/health"
