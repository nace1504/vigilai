#!/usr/bin/env bash
# VigilAI — ufw theo ma trận kết nối (Bước 7). Chạy bằng root trên từng VM:
#   sudo ./ufw-rules.sh server|indexer|dashboard|web
# ADMIN = máy thật trên VMnet8 (kiểm tra bằng ipconfig trên Windows).
set -euo pipefail
ADMIN=192.168.100.1
ROLE="${1:-}"

ufw default deny incoming
ufw default allow outgoing
ufw allow from "$ADMIN" to any port 22 proto tcp       # SSH quản trị — mở trước khi enable

case "$ROLE" in
  server)
    ufw allow from 192.168.100.20 to any port 514 proto udp     # syslog WAF + DVWA
    ufw allow from 192.168.100.32 to any port 55000 proto tcp   # Dashboard gọi API
    ;;
  indexer)
    ufw allow from 192.168.100.30 to any port 9200 proto tcp    # Filebeat
    ufw allow from 192.168.100.32 to any port 9200 proto tcp    # Dashboard truy vấn
    ;;
  dashboard)
    ufw allow from "$ADMIN" to any port 443 proto tcp           # giao diện web
    ;;
  web)
    echo "Cổng 80 do Docker publish nên ufw không chặn được:"
    echo "  -> thêm nội dung firewall/after.rules.docker-user vào cuối /etc/ufw/after.rules"
    ;;
  *)
    echo "Dùng: $0 server|indexer|dashboard|web" >&2; exit 1 ;;
esac

ufw --force enable
ufw status numbered
