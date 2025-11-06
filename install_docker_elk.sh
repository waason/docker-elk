#!/usr/bin/env bash
# =========================================================
# 🚀 Ubuntu 24.04 - Docker + ELK 自動安裝腳本
# Author: waason
# =========================================================
set -e

LOG_FILE="install_docker_elk_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "🐳 Docker + docker-elk 安裝啟動腳本開始"
echo "📅 $(date)"
echo "📂 Log 檔案：$LOG_FILE"
echo "=============================================="

# ---------- 更新系統 ----------
echo "📦 更新系統套件..."
sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release

# ---------- 安裝 Docker ----------
echo "🔑 新增 Docker 官方 GPG 金鑰..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "🧩 加入 Docker 軟體倉庫..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "⚙️ 安裝 Docker Engine、CLI、Compose plugin..."
sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ---------- 設定權限 ----------
echo "👤 將目前使用者加入 docker 群組（免 sudo）..."
sudo usermod -aG docker $USER

echo "✅ Docker 安裝完成，版本如下："
docker --version
docker compose version

# ---------- 啟動 docker-elk ----------
if [ -d "$HOME/docker-elk" ]; then
  cd ~/docker-elk
  echo "📂 切換目錄到 ~/docker-elk"
else
  echo "⚠️ 找不到 ~/docker-elk，請先 git clone 後再執行此腳本！"
  exit 1
fi

echo "把自己加入 docker 群組（免 sudo）..."
sudo usermod -aG docker $USER
newgrp docker

echo "🧱 建立 docker-elk 初始服務..."
docker compose up setup

echo "🔍 檢查容器狀態..."
docker compose ps

echo "🛠️ 重新建置 images..."
docker compose build

echo "🚀 啟動所有 ELK 服務..."
docker compose up -d

echo "✅ 安裝完成！"
echo "📊 請稍候數十秒後打開 http://127.0.0.1:5601"
echo "🔎 可查看日誌：tail -f $LOG_FILE"
echo "=============================================="

