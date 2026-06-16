#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="aceserve"
IMAGE_NAME="${ACESTREAM_ENGINE_IMAGE:-jopsis/aceserve:latest}"

if ! command -v docker >/dev/null 2>&1; then
  cat <<'EOF'
Docker не установлен.

Установите Docker Desktop для Mac:
https://www.docker.com/products/docker-desktop/

После установки запустите Docker Desktop и повторите команду.
EOF
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  cat <<'EOF'
Docker установлен, но сейчас не запущен.

Откройте Docker Desktop, дождитесь статуса "Docker is running" и повторите команду.
EOF
  exit 1
fi

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "AceStream Engine уже запущен: http://127.0.0.1:6878"
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  docker start "$CONTAINER_NAME" >/dev/null
else
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p 6878:6878 \
    -p 8621:8621 \
    -p 62062:62062 \
    "$IMAGE_NAME" >/dev/null
fi

printf "Жду AceStream Engine"
for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:6878" >/dev/null 2>&1; then
    printf "\nAceStream Engine запущен: http://127.0.0.1:6878\n"
    exit 0
  fi
  printf "."
  sleep 1
done

printf "\nКонтейнер запущен, но Engine пока не ответил на http://127.0.0.1:6878\n"
echo "Проверьте логи: docker logs $CONTAINER_NAME"
exit 1
