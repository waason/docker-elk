#!/usr/bin/env bash
set -e

echo "====================================================="
echo " 🚀 Kali: Docker + docker-elk + Fleet + Offline Agent Installer"
echo "====================================================="

# ---------------------------------------------
# 0) 基本參數
# ---------------------------------------------
PROJECT_DIR="$HOME/docker-elk"
OFFLINE_ROOT="$PROJECT_DIR/fleet-static-agent-offline"
OFFLINE_HTTP_ROOT="$OFFLINE_ROOT/downloads/beats/elastic-agent"

# ---------------------------------------------
# 1) Docker 安裝（Debian bookworm repo）
# ---------------------------------------------
echo "🐳 準備安裝 Docker（Debian bookworm repo）..."

sudo rm -f /etc/apt/sources.list.d/docker.list || true
sudo rm -f /etc/apt/keyrings/docker.gpg || true

sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release jq

echo "🔐 新增 Docker GPG Key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "📦 新增 Docker 書源（bookworm）..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian bookworm stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"

echo "🐳 Docker 版本：$(docker --version)"
echo "🐳 Docker Compose：$(docker compose version)"

# ---------------------------------------------
# 2) 確認 docker-elk 專案存在
# ---------------------------------------------
echo "📁 檢查 docker-elk 專案路徑..."

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "❌ 無法找到：$PROJECT_DIR"
  echo "請將 docker-elk 專案放置於 ~/docker-elk/"
  exit 1
fi
cd "$PROJECT_DIR"
echo "➡ 目前目錄：$PWD"

# ---------------------------------------------
# 3) 建立 Fortigate / Windows Log 目錄
# ---------------------------------------------
echo "📂 建立 log 資料夾..."
mkdir -p "$HOME/Documents/fortigate_logs"
mkdir -p "$HOME/Documents/win_evtx_log"
sudo chmod 2775 "$HOME/Documents/fortigate_logs"
sudo chmod 2775 "$HOME/Documents/win_evtx_log"

# ---------------------------------------------
# 4) 讀取 ELK 版本與密碼
# ---------------------------------------------
read -p "請輸入 ELK/Elastic 版本（預設 9.2.0）：" INPUT_VERSION
ELK_VERSION="${INPUT_VERSION:-9.2.0}"

read -s -p "請輸入 Elastic superuser 密碼：" ELASTIC_PASSWORD
echo ""
read -s -p "請輸入 Kibana System 密碼：" KIBANA_PASSWORD
echo ""

# ---------------------------------------------
# 5) 離線 Elastic Agent 準備
# ---------------------------------------------
echo "📦 建立 Offline Elastic Agent 結構..."

sudo install -d -m 775 -o "$USER" -g "$USER" "$OFFLINE_HTTP_ROOT"

AGENT_TAR="$OFFLINE_HTTP_ROOT/elastic-agent-${ELK_VERSION}-linux-x86_64.tar.gz"
AGENT_URL="https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${ELK_VERSION}-linux-x86_64.tar.gz"

if [[ -f "$AGENT_TAR" ]]; then
  echo "✔ 已存在 offline agent：$AGENT_TAR"
else
  echo "🌐 下載 Elastic Agent..."
  if curl -fSL "$AGENT_URL" -o "$AGENT_TAR"; then
    echo "✔ Elastic Agent 下載完成"
  else
    echo "⚠️ 無法自動下載，請手動放入："
    echo "   $AGENT_TAR"
  fi
fi

# ---------------------------------------------
# 6) 建立 docker-compose.override.yml
# ---------------------------------------------
echo "🌐 建立 Nginx 離線 artifacts server..."

OVERRIDE_FILE="$PROJECT_DIR/docker-compose.override.yml"

cat > "$OVERRIDE_FILE" <<EOF
services:
  agent-artifacts:
    image: nginx:stable
    container_name: agent-artifacts
    volumes:
      - ./fleet-static-agent-offline:/usr/share/nginx/html:ro
    ports:
      - "8080:80"
    networks:
      - elk
EOF

echo "✔ docker-compose.override.yml 已建立"

# ---------------------------------------------
# 7) 更新 .env
# ---------------------------------------------
echo "🧾 重建 .env..."

ENV_FILE="$PROJECT_DIR/.env"

sed -i '/ELASTIC_VERSION/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/ELK_VERSION/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/ELASTIC_PASSWORD/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/KIBANA_PASSWORD/d' "$ENV_FILE" 2>/dev/null || true

cat >> "$ENV_FILE" <<EOF
ELASTIC_VERSION=${ELK_VERSION}
ELK_VERSION=${ELK_VERSION}
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_PASSWORD=${KIBANA_PASSWORD}
EOF

echo "✔ .env 完成"

# ---------------------------------------------
# 8) 啟動 docker-elk + fleet-server
# ---------------------------------------------
echo "🚀 啟動 docker-elk + fleet-server + artifacts..."

docker compose pull
docker compose up setup
docker compose build
docker compose up -d

echo "====================================================="
echo " 🎉 安裝完成！"
echo "====================================================="
echo "Kibana URL:  http://localhost:5601"
echo "Fleet → Settings → Agent binary source："
echo "👉 http://agent-artifacts/downloads/"
echo ""
echo "📌 若要讓 docker 生效："
echo "sudo usermod -aG docker \$USER"
echo "newgrp docker"
echo "====================================================="
