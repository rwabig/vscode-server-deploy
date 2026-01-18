#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================
DOMAIN="${DOMAIN:-ide.ucclab.io}"
EMAIL="${EMAIL:-admin@ucclab.io}"
BASE="${BASE:-/opt/vscode-server}"
ENVIRONMENT="${LETSENCRYPT_ENV:-production}"   # staging | production

COMPOSE="docker compose -f $BASE/docker-compose.yml"
LIVE_DIR="$BASE/data/nginx/letsencrypt/live/$DOMAIN"

# ============================================================
# PREFLIGHT
# ============================================================
command -v docker >/dev/null || { echo "❌ Docker not installed"; exit 1; }
[[ -f "$BASE/docker-compose.yml" ]] || { echo "❌ docker-compose.yml not found"; exit 1; }

# ============================================================
# EXIT IF CERT EXISTS
# ============================================================
if [[ -d "$LIVE_DIR" ]]; then
  echo "✅ Certificate already exists for $DOMAIN — skipping bootstrap"
  exit 0
fi

# ============================================================
# CERTBOT FLAGS
# ============================================================
STAGING_FLAG=""
if [[ "$ENVIRONMENT" == "staging" ]]; then
  echo "⚠️  Using Let's Encrypt STAGING environment"
  STAGING_FLAG="--staging"
else
  echo "⚠️  PRODUCTION: Let's Encrypt rate limits apply"
fi

# ============================================================
# START NGINX
# ============================================================
echo "🚀 Ensuring nginx is running..."
$COMPOSE up -d nginx

# ============================================================
# WAIT FOR NGINX TO BIND PORT 80
# ============================================================
echo "⏳ Waiting for nginx to accept connections..."
sleep 10  # Give nginx more time to start

for i in {1..30}; do
  if curl -fsS http://127.0.0.1 >/dev/null 2>&1 || \
     curl -fsS http://localhost >/dev/null 2>&1; then
    echo "✅ nginx is ready"
    break
  fi
  sleep 2
  echo "Still waiting for nginx... ($i/30)"
  if [[ "$i" == "30" ]]; then
    echo "❌ nginx did not become ready — checking status..."
    docker compose ps
    docker compose logs nginx --tail=20
    exit 1
  fi
done

# ============================================================
# REQUEST CERTIFICATE
# ============================================================
echo "🔐 Requesting TLS certificate for $DOMAIN..."
$COMPOSE run --rm certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  $STAGING_FLAG \
  -d "$DOMAIN"

# ============================================================
# VERIFY CERTIFICATE
# ============================================================
if [[ ! -f "$LIVE_DIR/fullchain.pem" ]]; then
  echo "❌ Certificate issuance failed — file not found"
  exit 1
fi

# ============================================================
# RELOAD NGINX
# ============================================================
echo "🔄 Reloading nginx..."
$COMPOSE restart nginx

echo "🎉 TLS bootstrap complete for $DOMAIN"
