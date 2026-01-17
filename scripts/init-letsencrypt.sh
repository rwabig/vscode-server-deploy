#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================
DOMAIN="${DOMAIN:-ide.ucclab.io}"
EMAIL="${EMAIL:-admin@ucclab.io}"
BASE="${BASE:-/opt/vscode-server}"
ENVIRONMENT="${LETSENCRYPT_ENV:-production}"   # "staging" or "production"

COMPOSE="docker compose -f $BASE/docker-compose.yml"
LIVE_DIR="$BASE/data/nginx/letsencrypt/live/$DOMAIN"

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================
if [[ ! -f "$BASE/docker-compose.yml" ]]; then
  echo "❌ docker-compose.yml not found at $BASE"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ Docker is not installed"
  exit 1
fi

# DNS validation (IPv4 or IPv6)
if ! timeout 5 dig +short A "$DOMAIN" | grep -qE '^[0-9]' && \
   ! timeout 5 dig +short AAAA "$DOMAIN" | grep -qE ':'; then
  echo "❌ DNS for $DOMAIN does not resolve to A or AAAA record — aborting"
  exit 1
fi

# Rate-limit warning
if [[ "$ENVIRONMENT" == "production" ]]; then
  echo "⚠️  PRODUCTION: Let's Encrypt rate limits apply"
  echo "   - Certificates per domain: 50/week"
  echo "   - Duplicate certificates: 5/week"
  echo "   - Failed validations: 5/hour"
fi

# ============================================================
# EXIT IF CERT ALREADY EXISTS
# ============================================================
if [[ -d "$LIVE_DIR" && -f "$LIVE_DIR/fullchain.pem" ]]; then
  if openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1; then
    echo "✅ Certificate valid for >24h — skipping bootstrap"
    exit 0
  else
    echo "⚠️  Certificate expires soon — forcing renewal"
  fi
fi

# ============================================================
# PREPARE CERTBOT FLAGS
# ============================================================
STAGING_FLAG=""
if [[ "$ENVIRONMENT" == "staging" ]]; then
  echo "⚠️  Using Let's Encrypt STAGING environment"
  STAGING_FLAG="--staging"
fi

cleanup() {
  echo "🔄 Cleaning up temporary nginx..."
  $COMPOSE stop nginx >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ============================================================
# START NGINX FOR ACME CHALLENGE
# ============================================================
echo "🚀 Starting nginx for ACME challenge..."
$COMPOSE up -d nginx

echo "⏳ Waiting for nginx to bind port 80..."
for i in {1..15}; do
  if nc -z localhost 80 >/dev/null 2>&1; then
    echo "✅ nginx is listening on port 80"
    break
  fi
  sleep 2
done

if ! nc -z localhost 80 >/dev/null 2>&1; then
  echo "❌ nginx did not become ready — aborting"
  echo "   Check: docker compose logs nginx"
  exit 1
fi

# ============================================================
# REQUEST CERTIFICATE
# ============================================================
echo "🔐 Requesting TLS certificate for $DOMAIN..."
if ! $COMPOSE run --rm certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  $STAGING_FLAG \
  -d "$DOMAIN"; then

  echo "❌ Certificate issuance failed"
  echo "   Check: docker compose logs certbot"
  exit 1
fi

# ============================================================
# VERIFY CERTIFICATE
# ============================================================
if [[ ! -f "$LIVE_DIR/fullchain.pem" ]]; then
  echo "❌ Certificate file not found after issuance"
  exit 1
fi

echo "🔍 Validating certificate SANs..."
if ! openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "$DOMAIN"; then
  echo "❌ Certificate SAN does not contain $DOMAIN"
  exit 1
fi

# ============================================================
# RELOAD NGINX
# ============================================================
echo "🔄 Reloading nginx..."
$COMPOSE restart nginx

sleep 2
if ! $COMPOSE exec nginx nginx -t >/dev/null 2>&1; then
  echo "❌ nginx configuration invalid after certificate load"
  exit 1
fi

echo "🎉 TLS bootstrap complete for $DOMAIN"
echo "   Certificate: $LIVE_DIR/fullchain.pem"
echo "   Expires: $(openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
