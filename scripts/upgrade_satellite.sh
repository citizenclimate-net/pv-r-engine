#!/usr/bin/env bash
# Add the satellite pillars (4-5) service to an EXISTING pv-r-engine box.
# Run as root from anywhere. Safe to re-run. Leaves the certbot-managed nginx
# vhost in place and only adds an `include` for the /sat/ location.
set -euo pipefail
cd /srv/cc-pv-r

# 1. Latest code + the spatial R stack (terra, geodiv, landscapemetrics).
git pull --ff-only
# libabsl-dev + cmake: s2 (needed by sf, which geodiv imports) builds against Abseil.
apt-get install -y gdal-bin libgdal-dev libudunits2-dev libproj-dev libgeos-dev zip \
  libabsl-dev cmake libssl-dev
Rscript scripts/restore.R

# 2. Work dir for scene rasters (terra spills here; cleaned per run).
install -d -o cc-pv-r -g cc-pv-r /var/lib/cc-pv-r/sat

# 3. systemd unit for the second plumber process on :8002.
install -m 644 systemd/pv-sat-engine.service /etc/systemd/system/pv-sat-engine.service
systemctl daemon-reload
systemctl enable pv-sat-engine.service
systemctl restart pv-sat-engine.service   # also picks up unit/env changes on re-runs
systemctl restart pv-r-engine.service   # picks up the pulled code too

# 4. nginx: /sat/ -> :8002, included in every server block for this host.
install -d /etc/nginx/snippets
install -m 644 nginx/cc-pv-sat.conf /etc/nginx/snippets/cc-pv-sat.conf
VHOST=/etc/nginx/sites-available/cc-pv-r.conf
if ! grep -q "cc-pv-sat.conf" "$VHOST"; then
  cp "$VHOST" "$VHOST.bak.$(date +%s)"
  sed -i 's#^\(\s*server_name citizenclimate-pv-r.duckdns.org;\)#\1\n    include /etc/nginx/snippets/cc-pv-sat.conf;#' "$VHOST"
fi
nginx -t && systemctl reload nginx

echo "Done. Check: curl -H \"X-API-Key: \$(sudo cat /etc/cc-pv-r/api-key)\" https://citizenclimate-pv-r.duckdns.org/sat/health"
