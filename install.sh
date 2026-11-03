#!/usr/bin/env bash
# juhe-ai (聚合 AI) — установка / обновление на один сервер (Docker Compose).
# Источник: https://github.com/huanmin123/juhe-ai (Go + Vue, PostgreSQL + Redis)
#
# Запуск:
#   sudo bash install.sh                         # доступ по IP, http://<IP>/__aisys__/
#   sudo DOMAIN=ai.example.uz bash install.sh    # домен + автоматический HTTPS (Caddy)
#   sudo JUHE_REF=<commit|tag> bash install.sh   # зафиксировать версию juhe-ai
#
# Повторный запуск = обновление: тянет новый код, пересобирает, останавливает
# gateway/jobs, прогоняет миграции (upgrade) и поднимает заново. .env не трогается.
set -euo pipefail

DOMAIN="${DOMAIN:-}"
JUHE_REF="${JUHE_REF:-master}"
BASE="${BASE:-/opt/juhe-ai}"
TZ_NAME="${TZ_NAME:-Asia/Tashkent}"
SRC="$BASE/src"
REPO_URL="https://github.com/huanmin123/juhe-ai.git"

[ "$(id -u)" -eq 0 ] || { echo "Запускайте от root (sudo)"; exit 1; }
log() { printf '\n\033[1;32m>> %s\033[0m\n' "$*"; }

# --- 0. зависимости и память --------------------------------------------------
log "Проверка зависимостей"
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
docker compose version >/dev/null
command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git; }
command -v openssl >/dev/null || apt-get install -y -qq openssl

# Сборка фронта и Go требует ~4-6 ГБ RAM+swap; добавляем swap, если мало.
MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
SWAP_KB=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
if [ $(( (MEM_KB + SWAP_KB) / 1024 )) -lt 6000 ] && [ ! -f /swapfile ]; then
  log "RAM+swap < 6 ГБ — создаю /swapfile 4G"
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p "$BASE/build/bin" "$BASE/data/app/data" "$BASE/data/app/logs"
cd "$BASE"

# --- 1. исходники ---------------------------------------------------------------
log "Исходники juhe-ai ($JUHE_REF)"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth 1 origin "$JUHE_REF"
  git -C "$SRC" checkout -q --force FETCH_HEAD
else
  git clone -q "$REPO_URL" "$SRC"
  git -C "$SRC" checkout -q "$JUHE_REF"
fi
BUILD_ID=$(git -C "$SRC" rev-parse HEAD)
echo "commit: $BUILD_ID"

# --- 2. сборка Go (в контейнере, без локального Go) ----------------------------
for p in gateway jobs maintenance; do
  log "Сборка $p"
  docker run --rm -v "$SRC":/src -v juhe-gomod:/go/pkg/mod -v juhe-gocache:/root/.cache/go-build \
    -w /src/backend-go/projects/$p -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 \
    golang:1.26-alpine go build -trimpath -ldflags "-s -w" -o /src/.out/juhe-ai-$p ./cmd/juhe-ai-$p
  install -m 0755 "$SRC/.out/juhe-ai-$p" build/bin/
done

# --- 3. сборка фронта -----------------------------------------------------------
# vue-tsc (проверка типов) пропущен — ему не хватает памяти и для деплоя он не нужен.
# VITE_JUHE_AI_BUILD_ID нужен, т.к. в node:alpine нет git.
log "Сборка фронта"
docker run --rm -e VITE_JUHE_AI_BUILD_ID="$BUILD_ID" -v "$SRC":/src -w /src node:22-alpine sh -c \
  "corepack enable && pnpm install --frozen-lockfile && cd frontend && NODE_OPTIONS=--max-old-space-size=3072 npx vite build"
rm -rf build/frontend-dist && cp -r "$SRC/frontend/dist" build/frontend-dist
test -f build/frontend-dist/index.html
cp "$SRC/docker/single-server/Dockerfile.runtime" .

# --- 4. .env (создаётся один раз; JUHE_AI_SECRET менять НЕЛЬЗЯ) -----------------
if [ -n "$DOMAIN" ]; then
  ORIGIN="https://$DOMAIN"; COOKIE_SECURE=true
else
  IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')
  ORIGIN="http://$IP"; COOKIE_SECURE=false
fi

if [ ! -f .env ]; then
  log "Генерация .env"
  PGP=$(openssl rand -hex 24); RDP=$(openssl rand -hex 24); SEC=$(openssl rand -hex 32)
  PG="postgres://juhe_ai:${PGP}@postgres:5432/juhe_ai?sslmode=disable"
  cat > .env <<ENV
NODE_ENV=production
POSTGRES_PASSWORD=${PGP}
REDIS_PASSWORD=${RDP}
JUHE_AI_SECRET=${SEC}
JUHE_AI_POSTGRES_URL=${PG}
JUHE_AI_RUNTIME_LOG_POSTGRES_URL=${PG}&application_name=juhe-ai-runtime-log
JUHE_AI_ACCOUNT_HEALTH_INPUT_POSTGRES_URL=${PG}&application_name=juhe-ai-account-health
JUHE_AI_ACCOUNT_HEALTH_JOBS_OUTCOME_POSTGRES_URL=${PG}&application_name=juhe-ai-account-health-outcomes
JUHE_AI_MAINTENANCE_J3A_POSTGRES_URL=${PG}
JUHE_AI_MAINTENANCE_J3B_POSTGRES_URL=${PG}
JUHE_AI_MAINTENANCE_ACCOUNT_BALANCE_POSTGRES_URL=${PG}
JUHE_AI_REDIS_CACHE_URL=redis://:${RDP}@redis:6379/0
JUHE_AI_REDIS_STATE_URL=redis://:${RDP}@redis:6379/1
JUHE_AI_J3B_CIRCUIT_REDIS_URL=redis://:${RDP}@redis:6379/2
JUHE_AI_REDIS_NAMESPACE=prod
JUHE_AI_ALLOWED_ORIGINS=${ORIGIN}
JUHE_AI_COOKIE_SECURE=${COOKIE_SECURE}
JUHE_AI_TRUST_PROXY=true
ENV
  chmod 600 .env
else
  sed -i "s#^JUHE_AI_ALLOWED_ORIGINS=.*#JUHE_AI_ALLOWED_ORIGINS=${ORIGIN}#; s#^JUHE_AI_COOKIE_SECURE=.*#JUHE_AI_COOKIE_SECURE=${COOKIE_SECURE}#" .env
fi
set -a; . ./.env; set +a

# --- 5. Caddyfile ---------------------------------------------------------------
SITE="${DOMAIN:-:80}"
cat > Caddyfile <<CADDY
${SITE} {
	encode zstd gzip
	redir / /__aisys__/ permanent
	reverse_proxy /v1/* gateway:3000 {
		flush_interval -1
	}
	reverse_proxy gateway:3000
}
CADDY

# --- 6. compose.yml -------------------------------------------------------------
cat > compose.yml <<YML
name: juhe-ai
x-app: &app
  env_file: .env
  working_dir: /app/backend
  restart: unless-stopped
  volumes:
    - ./data/app/data:/app/backend/data
    - ./data/app/logs:/app/backend/logs
  depends_on:
    postgres: {condition: service_healthy}
    redis: {condition: service_healthy}
x-build: &bld
  context: .
  dockerfile: Dockerfile.runtime
services:
  postgres:
    image: postgres:18-alpine
    restart: unless-stopped
    command: [postgres, -c, shared_buffers=512MB, -c, effective_cache_size=1GB]
    environment:
      POSTGRES_DB: juhe_ai
      POSTGRES_USER: juhe_ai
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      TZ: ${TZ_NAME}
    volumes: [./data/postgres:/var/lib/postgresql]
    healthcheck: {test: ["CMD-SHELL","pg_isready -U juhe_ai -d juhe_ai"], interval: 10s, retries: 12}
  redis:
    image: redis:7.4-alpine
    restart: unless-stopped
    command: [redis-server, --requirepass, "\${REDIS_PASSWORD}", --appendonly, "yes", --maxmemory, 512mb, --maxmemory-policy, noeviction]
    environment: {REDIS_PASSWORD: "\${REDIS_PASSWORD}"}
    volumes: [./data/redis:/data]
    healthcheck: {test: ["CMD-SHELL","redis-cli --no-auth-warning -a \"\$\$REDIS_PASSWORD\" ping | grep -q PONG"], interval: 10s, retries: 12}
  gateway:
    <<: *app
    build: {<<: *bld, args: {BASE_IMAGE: "alpine:3.20", ALPINE_MIRROR: dl-cdn.alpinelinux.org, TARGET_BINARY: juhe-ai-gateway}}
    image: juhe-ai:gateway
    mem_limit: 2g
    environment:
      TZ: ${TZ_NAME}
      GOMEMLIMIT: 1536MiB
      JUHE_AI_HOST: 0.0.0.0
      JUHE_AI_PORT: 3000
      JUHE_AI_FRONTEND_DIST_PATH: /app/frontend/dist
      JUHE_AI_LOG_DIR: /app/backend/logs
      JUHE_AI_GATEWAY_HEALTH_LISTEN_ADDRESS: 0.0.0.0:3306
      JUHE_AI_GATEWAY_HEALTH_ALLOW_NON_LOOPBACK: "true"
      JUHE_AI_OWNER_LEASE_ACQUIRE_WAIT: 45s
    healthcheck: {test: ["CMD-SHELL","wget -q -O /dev/null http://127.0.0.1:3306/health"], interval: 10s, retries: 12, start_period: 75s}
  jobs:
    <<: *app
    build: {<<: *bld, args: {BASE_IMAGE: "alpine:3.20", ALPINE_MIRROR: dl-cdn.alpinelinux.org, TARGET_BINARY: juhe-ai-jobs}}
    image: juhe-ai:jobs
    mem_limit: 1g
    environment:
      TZ: ${TZ_NAME}
      JUHE_AI_INSTANCE_ID: juhe-ai-jobs
      JUHE_AI_LOG_DIR: /app/backend/logs
      JUHE_AI_JOBS_HEALTH_LISTEN_ADDRESS: 0.0.0.0:3305
    healthcheck: {test: ["CMD-SHELL","wget -q -O /dev/null http://127.0.0.1:3305/health"], interval: 10s, retries: 12, start_period: 30s}
  maintenance:
    <<: *app
    restart: "no"
    profiles: ["tool"]
    build: {<<: *bld, args: {BASE_IMAGE: "alpine:3.20", ALPINE_MIRROR: dl-cdn.alpinelinux.org, TARGET_BINARY: juhe-ai-maintenance}}
    image: juhe-ai:maintenance
    environment: {TZ: ${TZ_NAME}}
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    init: true
    depends_on: {gateway: {condition: service_healthy}}
    ports: ["80:80", "443:443", "443:443/udp"]
    volumes: [./Caddyfile:/etc/caddy/Caddyfile:ro, caddy_data:/data, caddy_config:/config]
volumes: {caddy_data: {}, caddy_config: {}}
YML

# --- 7. образы, остановка писателей, БД -----------------------------------------
log "Сборка образов"
docker compose --profile tool build
chown -R 1000:1000 data/app

# Миграции выполняются только при остановленных gateway/jobs (требование juhe-ai).
docker compose stop gateway jobs 2>/dev/null || true
docker compose up -d --wait postgres redis

log "Инициализация / миграции БД"
docker compose exec -T postgres psql -U juhe_ai -d juhe_ai -v ON_ERROR_STOP=1 -c \
  "CREATE SCHEMA IF NOT EXISTS juhe_jobs AUTHORIZATION juhe_ai; CREATE SCHEMA IF NOT EXISTS juhe_j3b AUTHORIZATION juhe_ai;"

if [ -s data/.installed ]; then
  log "Резервная копия БД перед обновлением"
  mkdir -p backups
  docker compose exec -T postgres pg_dump -U juhe_ai -Fc juhe_ai > "backups/juhe_ai-$(date +%F-%H%M).dump"
  ls -1t backups/*.dump | tail -n +8 | xargs -r rm -f   # хранить 7 последних
fi

M="docker compose --profile tool run --rm maintenance"
$M --ensure-schema --seed --dsn "$JUHE_AI_POSTGRES_URL" --secret "$JUHE_AI_SECRET"
$M --apply-j3a-proxy-latency-postgres
$M --apply-j3b-model-check-postgres
$M --apply-account-balance-postgres
$M upgrade --dsn "$JUHE_AI_POSTGRES_URL" --secret "$JUHE_AI_SECRET" --stop-write-confirmed --backup-confirmed
docker compose run --rm gateway -init-account-circuit-runtime-index
echo "$BUILD_ID $(date -Is)" >> data/.installed

# --- 8. старт -------------------------------------------------------------------
log "Запуск"
docker compose up -d
sleep 10
docker compose ps
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/v1/models || true)
echo "/v1/models -> $code (ожидается 401)"

cat <<DONE

Готово (juhe-ai $BUILD_ID)
  Админка: ${ORIGIN}/__aisys__/   первый вход: admin / admin — сразу смените пароль
  API:     ${ORIGIN}/v1           ключ sk-... в разделе API Key
  Секреты: ${BASE}/.env — сохраните копию вне сервера (JUHE_AI_SECRET шифрует ключи провайдеров)
DONE
