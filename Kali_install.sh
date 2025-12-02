#!/usr/bin/env bash
set -e

echo "==============================================="
echo " 🐳 Docker Installer for Kali (Using Debian bookworm repo)"
echo "==============================================="

# ---------------------------------------------
# 1) Remove invalid Docker sources
# ---------------------------------------------
echo "🔧 清除舊的 Docker repository......"

sudo rm -f /etc/apt/sources.list.d/docker.list || true
sudo rm -f /etc/apt/keyrings/docker.gpg || true

echo "✔ 舊 Docker Repo 已清除"

# ---------------------------------------------
# 2) Install required packages
# ---------------------------------------------
echo "🔧 安裝必要套件..."

sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release

# ---------------------------------------------
# 3) Add Docker GPG key
# ---------------------------------------------
echo "🔐 新增 Docker GPG Key..."

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "✔ GPG key 已加入"

# ---------------------------------------------
# 4) Add Debian bookworm Docker repo
# ---------------------------------------------
echo "📦 新增 Debian bookworm Docker repo..."

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian bookworm stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "✔ Docker repo 已加入 (bookworm)"

# ---------------------------------------------
# 5) Update & Install Docker
# ---------------------------------------------
echo "🔄 更新 apt 來源..."
sudo apt update -y

echo "🐳 安裝 Docker CE / CLI / Compose plugin..."
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "✔ Docker 已成功安裝"

# ---------------------------------------------
# 6) Add current user to docker group
# ---------------------------------------------
echo "👤 設定 docker 群組權限..."

sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"

echo "✔ 已加入 docker 群組"

# ---------------------------------------------
# 7) Show installed versions
# ---------------------------------------------
echo "==============================================="
echo " Docker 安裝完成！版本如下："
docker --version
docker compose version
echo "==============================================="
echo "⚠ 建議執行： newgrp docker"
echo "==============================================="
