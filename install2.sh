#!/usr/bin/env bash
set -e

echo "====================================================="
echo " 🚀 Docker ELK + Fleet Server + Offline Agent Installer"
echo "====================================================="

# ---------------------------------------------
# 基本檢查：必須在 docker-elk 專案目錄執行
# ---------------------------------------------
PROJECT_DIR="$HOME/docker-elk"
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "❌ 找不到資料夾：$PROJECT_DIR"
  echo "請先把 docker-elk 專案放在：~/docker-elk/"
  exit 1
fi

cd "$PROJECT_DIR"

echo "📁 工作目錄：$PWD"

# ---------------------------------------------
# 安裝必要工具
# ---------------------------------------------
echo "🔧 安裝必要套件..."

sudo apt update -y
sudo apt install -y ca-certificates curl jq gnupg lsb-release

# ---------------------------------------------
# Docker 安裝（若不存在）
# ---------------------------------------------
if ! command -v docker &> /dev/null; then
  echo "🐳 安裝 Docker..."

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "✔ Docker 已存在，跳過安裝"
fi

sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"

DOCKER="sudo docker"
COMPOSE="$DOCKER compose"

echo "🐳 Docker 版本：$(docker --version)"
echo "🐳 Docker Compose 版本：$(docker compose version)"

# ---------------------------------------------
# 建立 fortigate / windows log 資料夾
# ---------------------------------------------
echo "📂 建立 Fortigate/Windows Log 資料夾..."

mkdir -p "$HOME/Documents/fortigate_logs"
mkdir -p "$HOME/Documents/win_evtx_log"

sudo chmod 2775 "$HOME/Documents/fortigate_logs"
sudo chmod 2775 "$HOME/Documents/win_evtx_log"

# ---------------------------------------------
# 取得 Elastic 版本與密碼
# ---------------------------------------------
read -p "請輸入 ELK/Elastic 版本（預設 9.2.0）：" INPUT_VERSION
ELK_VERSION="${INPUT_VERSION:-9.2.0}"

read -s -p "請輸入 Elastic superuser 密碼：" ELASTIC_PASSWORD
echo ""
read -s -p "請輸入 Kibana System 密碼：" KIBANA_PASSWORD
echo ""

# ---------------------------------------------
# 離線 Elastic Agent 準備
# ---------------------------------------------
echo "📦 準備 Offline Elastic Agent (${ELK_VERSION})..."

OFFLINE_ROOT="$PROJECT_DIR/fleet-static-agent-offline"
OFFLINE_HTTP_ROOT="$OFFLINE_ROOT/downloads/beats/elastic-agent"
OFFLINE_TAR="$OFFLINE_HTTP_ROOT/elastic-agent-${ELK_VERSION}-linux-x86_64.tar.gz"
OFFLINE_URL="https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${ELK_VERSION}-linux-x86_64.tar.gz"

sudo install -d -m 775 -o "$USER" -g "$USER" "$OFFLINE_HTTP_ROOT"

if [[ -f "$OFFLINE_TAR" ]]; then
  echo "✔ 掛載檔案已存在：$OFFLINE_TAR"
else
  echo "🌐 下載 Elastic Agent ${ELK_VERSION}..."
  if curl -fSL "$OFFLINE_URL" -o "$OFFLINE_TAR"; then
    echo "✔ Elastic Agent 下載完成"
  else
    echo "⚠️ Elastic Agent 下載失敗。請手動放入："
    echo "   $OFFLINE_TAR"
  fi
fi

echo "📁 離線 Elastic Agent 位置：$OFFLINE_TAR"

# ---------------------------------------------
# 建立 docker-compose.override.yml  — nginx artifacts
# ---------------------------------------------
echo "🌐 建立 NGINX 離線 artifacts server（agent-artifacts）..."

OVERRIDE_FILE="$PROJECT_DIR/docker-compose.override.yml"

if [[ ! -f "$OVERRIDE_FILE" ]]; then
  cat > "$OVERRIDE_FILE" <<'EOF'
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
  echo "✔ 已建立 docker-compose.override.yml"
else
  if ! grep -q "agent-artifacts" "$OVERRIDE_FILE"; then
    cat >> "$OVERRIDE_FILE" <<'EOF'

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
    echo "✔ 已加入 agent-artifacts 到現有 override"
  else
    echo "✔ docker-compose.override.yml 已包含 agent-artifacts"
  fi
fi

echo "✔ NGINX 靜態伺服器已準備好"
echo "   離線 Agent URL（Fleet Host 填此）："
echo "   👉 http://agent-artifacts/downloads/"

# ---------------------------------------------
# 更新 .env
# ---------------------------------------------
echo "🧾 寫入 .env..."

ENV_FILE="$PROJECT_DIR/.env"

sed -i '/ELK_VERSION/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/ELASTIC_VERSION/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/ELASTIC_PASSWORD/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/KIBANA_PASSWORD/d' "$ENV_FILE" 2>/dev/null || true

cat >> "$ENV_FILE" <<EOF
ELK_VERSION=${ELK_VERSION}
ELASTIC_VERSION=${ELK_VERSION}
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_PASSWORD=${KIBANA_PASSWORD}
EOF

echo "✔ .env 已寫入"

# ---------------------------------------------
# 啟動 docker-elk + fleet-server + artifacts
# ---------------------------------------------
echo "🚀 啟動 docker-elk + fleet-server + artifacts server..."

$COMPOSE pull
$COMPOSE up setup
$COMPOSE build
$COMPOSE up -d

echo "====================================================="
echo " 🎉 安裝完成！"
echo "====================================================="
echo "Kibana UI: http://localhost:5601"
echo ""
echo "請到：Kibana → Fleet → Settings → Agent binary source"
echo "將 Host 改成："
echo "👉 http://agent-artifacts/downloads/"
echo ""
echo "離線 agent 路徑已支援完整下載結構（beats/elastic-agent/...）"
echo "====================================================="
