#!/usr/bin/env bash
# =========================================================
# 🕒 Ubuntu 24.x 時區校正腳本（設定為台灣時間）
# Author: waason
# =========================================================
set -euo pipefail

echo "=============================================="
echo "🕐 Ubuntu 時區設定 -> Asia/Taipei"
echo "📅 $(date)"
echo "=============================================="

# Step 1️⃣ 顯示目前時區
echo "目前時區：$(timedatectl show --property=Timezone --value)"
echo "目前系統時間：$(date)"

# Step 2️⃣ 設定台灣時區
echo "➡️ 設定時區為 Asia/Taipei..."
sudo timedatectl set-timezone Asia/Taipei

# Step 3️⃣ 啟用 NTP 自動校時
echo "🔄 啟用 NTP 同步..."
sudo timedatectl set-ntp true

# Step 4️⃣ 重新同步時間（使用 systemd-timesyncd 或 ntpdate）
if command -v systemctl >/dev/null && systemctl list-unit-files | grep -q systemd-timesyncd; then
  echo "🔧 重新啟動 systemd-timesyncd..."
  sudo systemctl restart systemd-timesyncd
else
  echo "⚙️ 安裝 ntpdate 並同步時間..."
  sudo apt update -y && sudo apt install -y ntpdate
  sudo ntpdate time.stdtime.gov.tw
fi

# Step 5️⃣ 顯示結果
echo
echo "✅ 設定完成！目前狀態如下："
timedatectl status | grep -E "Time zone|Local time|NTP"
echo "=============================================="
