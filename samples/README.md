# samples/ — dữ liệu mẫu

- `raw-logs/`: vài dòng log thô lấy từ `archives.json` (trường `full_log`) cho cả 2 nguồn
  `modsec` và `dvwa` — dùng để test decoder bằng `wazuh-logtest` (Bước 5.3, 6.3).
- `alerts/`: vài chục cảnh báo JSON thật trích từ `/var/ossec/logs/alerts/alerts.json`
  (đủ loại: 100201–100206, 100210, 100220, 311xx) — dữ liệu để phần AI agent phát triển và
  test mà không cần chờ hệ thống chạy.

Trước khi commit: kiểm tra không chứa mật khẩu/token.
