# samples/ — dữ liệu mẫu cho phần AI agent

Dữ liệu thật lấy từ lab giai đoạn 1 (tấn công từ Kali 192.168.100.10 vào WAF 192.168.100.20).
Không chứa mật khẩu/token. Địa chỉ IP là IP nội bộ của lab.

## alerts/alerts-samples.jsonl
8 alert của Wazuh, mỗi dòng là 1 JSON (định dạng `alerts.json` của Wazuh, đã nén 1 dòng).
Mỗi loại một alert:

| rule.id | level | Ý nghĩa |
|---|---|---|
| 100201 | 8  | WAF: SQL Injection (CRS 942xxx) |
| 100202 | 8  | WAF: XSS (CRS 941xxx) |
| 100203 | 10 | WAF: Remote Command Execution (CRS 932xxx) |
| 100204 | 8  | WAF: LFI / Path Traversal (CRS 930xxx) |
| 100206 | 6  | WAF: scanner / công cụ tấn công (CRS 913xxx) |
| 100210 | 10 | WAF: vượt ngưỡng điểm bất thường (CRS 949110) — với engine `On` nghĩa là request bị chặn 403 |
| 100220 | 13 | Tương quan: ≥5 request bị chặn / 60 giây từ cùng một IP (`previous_output` chứa các alert thành phần) |
| 31106  | 6  | Rule có sẵn của Wazuh: tấn công web nhưng ứng dụng trả mã 200 — dấu hiệu tấn công đã lọt (xuất hiện khi WAF ở `DetectionOnly`) |

Trường quan trọng: `rule.id`, `rule.level`, `rule.description`, `rule.mitre.*`,
`data.srcip`, `data.url`, `data.modsec_id`, `data.modsec_msg`, `data.modsec_action`
(chỉ có khi engine `On`, giá trị `Access denied`), `full_log` (dòng log gốc), `timestamp`.

Lưu ý: một request bị chặn sinh nhiều alert (vài alert 1002xx cho từng rule CRS bị khớp + 1 alert 100210),
cùng `data.url` và cùng thời điểm — agent nên gộp theo `data.srcip` + `data.url` + thời gian.

## raw-logs/
Log thô, đúng như Wazuh Server nhận qua syslog (trước khi decode):

- `raw-waf-warning.log` — dòng `ModSecurity: Warning` (từng rule CRS khớp, có `[id "..."]`, `[msg "..."]`, `client: <ip>`).
- `raw-waf-denied.log` — dòng `ModSecurity: Access denied with code 403` (rule 949110, có `[client <ip>]`).
- `raw-waf-audit.json` — audit log JSON của ModSecurity (1 dòng/request bị chặn: toàn bộ request, response, danh sách rule khớp). Giàu thông tin nhất cho AI, hiện chưa có decoder trong Wazuh (đi qua rule 1002 level 2 nên không thành alert).
- `raw-dvwa-access.log` — access log Apache của DVWA; IP nguồn đã được `mod_remoteip` khôi phục thành IP máy tấn công (không phải IP Docker).

Dùng để thử decoder: `/var/ossec/bin/wazuh-logtest`, dán dòng log vào (thêm tiền tố syslog `Oct 15 21:53:50 modsec[1227]: ` nếu cần).
