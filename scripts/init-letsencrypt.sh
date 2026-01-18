#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================
DOMAIN="${DOMAIN:-ide.ucclab.io}"
EMAIL="${EMAIL:-admin@ucclab.io}"
BASE="${BASE:-/opt/vscode-server}"
ENVIRONMENT="${LETSENCRYPT_ENV:-production}"   # staging | production

COMPOSE="cd '$BASE' && docker compose"
LIVE_DIR="$BASE/data/nginx/letsencrypt/live/$DOMAIN"

# ============================================================
# PREFLIGHT
# ============================================================
command -v docker >/dev/null || { echo "❌ Docker not installed"; exit 1; }
[[ -f "$BASE/docker-compose.yml" ]] || { echo "❌ docker-compose.yml not found"; exit 1; }

# ============================================================
# EXIT IF CERT EXISTS
# ============================================================
if [[ -f "$LIVE_DIR/fullchain.pem" ]]; then
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
  echo "   - Certificates per domain: 50/week"
  echo "   - Duplicate certificates: 5/week"
  echo "   - Failed validations: 5/hour"
fi

# ============================================================
# ENSURE CERTBOT DIRECTORIES EXIST
# ============================================================
echo "📁 Creating required directories..."
mkdir -p "$BASE/data/nginx/letsencrypt" "$BASE/data/nginx/certbot"

# ============================================================
# CLEAN START - Stop and restart containers
# ============================================================
echo "🔄 Stopping existing containers..."
cd "$BASE"
docker compose down nginx certbot 2>/dev/null || true

echo "🚀 Starting nginx for ACME challenge..."
docker compose up -d nginx

# ============================================================
# WAIT FOR NGINX (CHECK BOTH CONTAINER STATUS AND PORT 80)
# ============================================================
echo "⏳ Waiting for nginx to be ready..."
MAX_ATTEMPTS=30
ATTEMPT=1

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  # Check if container is running
  if docker compose ps nginx | grep -q "Up" && \
     docker compose exec nginx nginx -t >/dev/null 2>&1; then

    # Check if port 80 is responding
    if curl -fsS http://localhost >/dev/null 2>&1 || \
       curl -fsS http://127.0.0.1 >/dev/null 2>&1; then
      echo "✅ nginx is ready and responding on port 80"
      break
    fi
  fi

  echo "Still waiting for nginx... ($ATTEMPT/$MAX_ATTEMPTS)"
  sleep 2
  ATTEMPT=$((ATTEMPT + 1))

  if [[ $ATTEMPT -gt $MAX_ATTEMPTS ]]; then
    echo "❌ nginx did not become ready — checking logs..."
    docker compose logs nginx --tail=20
    echo "📋 Checking nginx config..."
    docker compose exec nginx nginx -t || true
    echo "🔍 Checking port 80..."
    curl -v http://localhost || curl -v http://127.0.0.1 || true
    exit 1
  fi
done

# ============================================================
# REQUEST CERTIFICATE
# ============================================================
echo "🔐 Requesting TLS certificate for $DOMAIN..."
if docker compose run --rm certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  $STAGING_FLAG \
  -d "$DOMAIN"; then
  echo "✅ Certificate issued successfully"
else
  echo "❌ Certificate issuance failed"
  echo "⚠️  Common issues:"
  echo "   1. Domain DNS not pointing to this server"
  echo "   2. Port 80 not accessible from internet"
  echo "   3. Let's Encrypt rate limits"
  exit 1
fi

# ============================================================
# VERIFY CERTIFICATE
# ============================================================
if [[ ! -f "$LIVE_DIR/fullchain.pem" ]]; then
  echo "❌ Certificate file not found at $LIVE_DIR/fullchain.pem"
  exit 1
fi

echo "📄 Certificate files created:"
ls -la "$LIVE_DIR/"

# ============================================================
# RESTART NGINX WITH SSL
# ============================================================
echo "🔄 Restarting nginx with SSL configuration..."
docker compose restart nginx

# ============================================================
# FINAL VERIFICATION
# ============================================================
echo "🔍 Final verification..."
sleep 3

if docker compose ps nginx | grep -q "Up"; then
  echo "✅ nginx is running with SSL"
else
  echo "⚠️  nginx may not be running - checking logs..."
  docker compose logs nginx --tail=10
fi

echo "🎉 TLS bootstrap complete for $DOMAIN"
echo "🌐 Access your VS Code at: https://$DOMAIN"
