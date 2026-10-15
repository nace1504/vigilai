# Đặc tả giao tiếp: VigilAI (phát hiện) ↔ AI agent (phản ứng)

> Bản nháp — cần chốt với thành viên phụ trách AI agent.

## 1. Nhận cảnh báo
- Cách: Wazuh integration (webhook) từ Wazuh Server (.30) → AI agent (IP: _chốt_, cổng 8000/tcp).
- Ngưỡng: level ≥ 8 (_chốt_). Định dạng: JSON nguyên bản của Wazuh alert.

## 2. Trường dữ liệu cam kết giữ ổn định
| Trường | Ý nghĩa |
| --- | --- |
| `timestamp`, `id` | thời điểm, ID cảnh báo |
| `rule.id`, `rule.level`, `rule.description`, `rule.groups`, `rule.mitre.id` | phân loại |
| `data.srcip` | IP nguồn tấn công |
| `data.url` | URI bị tấn công (WAF) |
| `data.modsec_id`, `data.modsec_msg`, `data.modsec_action` | chi tiết ModSecurity |
| `decoder.name` | `modsec` (WAF) hoặc `web-accesslog` (DVWA) |
| `location`, `full_log` | nguồn gửi, log gốc |

Mẫu thật: `samples/alerts/`.

## 3. Lấy ngữ cảnh
- AI agent đọc Wazuh Indexer (.31:9200), index `wazuh-alerts-*`, bằng tài khoản **chỉ đọc** riêng.

## 4. Phản ứng
- Gọi Wazuh API (.30:55000) để chạy Active Response (vd `firewall-drop`) — cần Wazuh agent trên VM Web (giai đoạn 4).
- Tài khoản API giới hạn quyền (RBAC). Tự động chặn chỉ khi chắc chắn (vd rule 100220); còn lại đề xuất, chờ người duyệt.

## 5. Luồng mạng cần mở thêm (khi tích hợp)
| Nguồn | Đích | Cổng | Mục đích |
| --- | --- | --- | --- |
| Server (.30) | AI agent | 8000/tcp | đẩy cảnh báo |
| AI agent | Indexer (.31) | 9200/tcp | đọc ngữ cảnh |
| AI agent | Server (.30) | 55000/tcp | gọi API Active Response |
| VM Web (.20) | Server (.30) | 1514–1515/tcp | Wazuh agent |
