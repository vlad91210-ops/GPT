# juhe-ai (聚合 AI) — установка одним скриптом

OpenAI-совместимый шлюз [huanmin123/juhe-ai](https://github.com/huanmin123/juhe-ai): пул AI-аккаунтов, свои `sk-` ключи, бюджеты, аудит.
Стек: Go (gateway + jobs) + Vue, PostgreSQL 18, Redis 7, Caddy. Всё в Docker Compose, каталог `/opt/juhe-ai`.

## Требования
- Ubuntu/Debian, 2 vCPU, **4 ГБ RAM** (+ swap; скрипт сам добавит 4G, если RAM+swap < 6 ГБ)
- Hyper-V Gen2: шаблон Secure Boot = «Microsoft UEFI Certificate Authority», динамическая память выключена
- Открыты порты 80/443

## Установка

```bash
git clone https://github.com/vlad91210-ops/GPT.git && cd GPT
sudo bash install.sh                         # доступ по IP:  http://<IP>/__aisys__/
```

Потом, когда появится домен (DNS A-запись → этот сервер):

```bash
sudo DOMAIN=ai.example.uz bash install.sh    # переключит на https://ai.example.uz (Let's Encrypt)
```

Зафиксировать версию juhe-ai (проект меняется почти ежедневно):

```bash
sudo JUHE_REF=<commit> bash install.sh
```

## Обновление
Повторный запуск `sudo bash install.sh` = обновление: свежий код → сборка → бэкап БД (`/opt/juhe-ai/backups`, 7 шт.) → остановка gateway/jobs → миграции (`upgrade`) → старт. `.env` не перезаписывается.

## После установки
1. `http://<IP>/__aisys__/` → вход `admin` / `admin` → сменить пароль.
2. **AI 账户** → добавить аккаунт типа **API Key** (OpenAI / Anthropic / Gemini / DeepSeek). OAuth-аккаунты требуют зарубежный прокси и могут нарушать условия провайдеров.
3. **API Key** → скопировать ключ `sk-...`.
4. Клиенты: `Base URL http://<IP>/v1`, `API Key sk-...` (Cherry Studio, Codex, скрипты).

## Веб-чат для сотрудников (Open WebUI)

```bash
sudo bash openwebui.sh sk-ВАШ_КЛЮЧ          # http://<IP>:8080, первый зарегистрированный = админ
```

## Обслуживание

```bash
cd /opt/juhe-ai
docker compose ps
docker compose logs -f --tail=100 gateway jobs
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/v1/models   # 401 = ok
```

**`/opt/juhe-ai/.env` — сохранить копию вне сервера.** `JUHE_AI_SECRET` шифрует ключи провайдеров; без него данные не расшифровать. В git `.env` не класть.

## Известные грабли (уже учтены в скрипте)
| Симптом | Причина |
|---|---|
| `JavaScript heap out of memory` при сборке | `vue-tsc` — пропущен, собирается только `vite build` |
| `spawnSync git ENOENT` | в `node:alpine` нет git — ID сборки передаётся через `VITE_JUHE_AI_BUILD_ID` |
| `Out of memory: Killed process` в VM | мало RAM — 4 ГБ статически + swap |
| `The signed image's hash is not allowed (DB)` | Secure Boot шаблон Windows — сменить на Microsoft UEFI CA |
