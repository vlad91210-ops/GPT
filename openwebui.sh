#!/usr/bin/env bash
# Open WebUI — веб-чат для сотрудников поверх juhe-ai.
# Запуск:  sudo bash openwebui.sh sk-ВАШ_КЛЮЧ     (ключ из админки juhe-ai → API Key)
#          sudo bash openwebui.sh                 (без ключа — задать потом в Open WebUI:
#                                              Настройки администратора → Подключения)
set -euo pipefail
KEY="${1:-${OPENWEBUI_KEY:-}}"
PORT="${OPENWEBUI_PORT:-8080}"

docker network inspect juhe-ai_default >/dev/null 2>&1 || { echo "Сначала запустите install.sh"; exit 1; }
docker pull -q ghcr.io/open-webui/open-webui:main
docker rm -f open-webui 2>/dev/null || true
docker run -d --name open-webui --restart unless-stopped \
  --network juhe-ai_default -p "${PORT}:8080" \
  -e OPENAI_API_BASE_URL=http://gateway:3000/v1 \
  -e OPENAI_API_KEY="$KEY" \
  -e ENABLE_OLLAMA_API=false \
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:main

IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')
echo "Open WebUI: http://${IP}:${PORT}  (первый старт 2–4 мин; первый зарегистрированный = админ)"
echo "Логи: docker logs -f open-webui   (ждать 'Application startup complete')"
