# Kế hoạch triển khai Giai đoạn 1 (WAF → Wazuh)

2026-10-14 · @Hữu Nguyên

## Tổng quan

Dựng theo thứ tự **hạ tầng → Wazuh (Indexer → Server → Dashboard) → Web/WAF → syslog → decoder/rule → firewall → demo**. Làm Wazuh trước để khi WAF bắn log là có chỗ nhận ngay; bật firewall sau cùng để không phải debug hai thứ cùng lúc.

Nguyên tắc chung:

- Mỗi bước có **điểm kiểm tra (✔)**; chưa qua thì không sang bước sau.
- **Snapshot VM** sau mỗi bước chạy được.
- Mọi file cấu hình (compose, dvwa/Dockerfile, ossec.conf, decoder, rule, attack.sh, after.rules) commit lên repo Git cá nhân (private) tên vigilai — vừa làm backup, vừa có lịch sử thay đổi để viết báo cáo.
- Phiên bản: **Wazuh 4.14** (bản `current` trên docs), **CRS v4** image `owasp/modsecurity-crs:nginx` — ghim tag cụ thể khi đã chạy ổn.

Làm một mình nên đi tuần tự, mỗi tuần chốt một mốc chạy được:

| Tuần | Bước | Mốc hoàn thành |
| --- | --- | --- |
| 1 | 0, 1, 2, 3 | Cụm Wazuh 3 node lên, Dashboard thấy alert của chính manager |
| 2 | 4, 5, 6 | Bắn SQLi từ Kali → thấy alert rule 1002xx trên Dashboard; log DVWA về Wazuh với IP thật |
| 3 | 7, 8, 9 | Firewall theo ma trận, kịch bản demo chạy trọn vẹn, đủ ảnh chụp cho báo cáo |

Với 1 máy thật: cần ≥ 24 GB RAM để chạy cả 5 VM thoải mái. Máy 16 GB thì gộp Indexer + Dashboard vào 1 VM (.31) như tài liệu kiến trúc đã cho phép, và chỉ bật Kali khi tấn công.

Mẹo tiết kiệm thời gian: trong lúc chờ cài đặt hoặc tải image, viết sẵn decoder/rule (Bước 6) và `attack.sh` (Bước 8) từ mẫu trong tài liệu này.

## Bước 0 — Chuẩn bị hạ tầng

Mục tiêu: 5 VM cùng mạng 192.168.100.0/24, IP tĩnh, ra được Internet để cài gói, đồng bộ giờ.

1. **Hypervisor:** VMware Workstation Pro (miễn phí cho cá nhân). Cả lab chạy trên 1 máy của bạn (yêu cầu RAM xem phần Tổng quan).
2. **Mạng:** VMware: sửa VMnet8 (NAT) thành subnet 192.168.100.0/24, tắt DHCP, gateway mặc định là 192.168.100.2. Dùng NAT để vừa nội bộ vừa có Internet; máy thật nhận IP 192.168.100.1 trên card VMnet8 nên SSH và Dashboard vào thẳng được.
3. **Tạo VM** theo bảng quy hoạch (Kali .10, Web .20, Server .30, Indexer .31, Dashboard .32). Cài Ubuntu Server 24.04 bản minimal + OpenSSH. Mẹo: cài 1 VM Ubuntu chuẩn rồi clone 4 bản, sau clone chạy `sudo rm /etc/machine-id && sudo systemd-machine-id-setup` để tránh trùng ID, và tạo lại SSH host key bằng sudo rm /etc/ssh/ssh_host_* && sudo dpkg-reconfigure openssh-server.
4. **IP tĩnh** bằng netplan, ví dụ VM Server (`/etc/netplan/50-cloud-init.yaml`):

```yaml
network:
  version: 2
  ethernets:
    ens33:
      addresses: [192.168.100.30/24]
      routes: [{to: default, via: 192.168.100.2}]
      nameservers: {addresses: [8.8.8.8, 1.1.1.1]}
```

Rồi `sudo netplan apply`; kiểm tra tên card bằng `ip a`. Nếu sau reboot IP bị cloud-init ghi đè: tạo /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg với nội dung network: {config: disabled}. Sau đó:

- **Hostname + /etc/hosts** trên mọi VM: `sudo hostnamectl set-hostname wazuh-server` (tương tự `wazuh-indexer`, `wazuh-dashboard`, `web`, `kali`), thêm 5 dòng IP–tên vào `/etc/hosts`.
- **Giờ và gói:** `sudo timedatectl set-timezone Asia/Ho_Chi_Minh`, `sudo apt update && sudo apt -y upgrade && sudo apt -y install curl tar tcpdump net-tools chrony`. Giờ lệch giữa các VM làm hỏng cert TLS và làm sai rule tương quan theo thời gian.
- **Riêng Indexer:** tắt swap (`sudo swapoff -a` và comment dòng swap trong `/etc/fstab`) — OpenSearch khuyến nghị.

✔ Kiểm tra: từ mỗi VM `ping` được 4 VM còn lại theo tên và `ping 8.8.8.8` được; `timedatectl` báo `System clock synchronized: yes`. → Snapshot "B0-base".

## Bước 1 — Wazuh Indexer (VM .31)

Dùng installation assistant của Wazuh để sinh cert chung cho cả 3 node rồi cài từng node. Toàn bộ lệnh chạy bằng root (`sudo -i`).

**1.1. Tải script và khai báo node** (trên VM Indexer):

```bash
curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh
curl -sO https://packages.wazuh.com/4.14/config.yml
```

Sửa `config.yml`, xóa phần thừa, chỉ để:

```yaml
nodes:
  indexer:
    - name: node-1
      ip: "192.168.100.31"
  server:
    - name: wazuh-1
      ip: "192.168.100.30"
  dashboard:
    - name: dashboard
      ip: "192.168.100.32"
```

**1.2. Sinh cert + mật khẩu, copy sang 2 node còn lại:**

```bash
bash wazuh-install.sh --generate-config-files
scp wazuh-install-files.tar wazuh-install.sh <user>@192.168.100.30:~/
scp wazuh-install-files.tar wazuh-install.sh <user>@192.168.100.32:~/
```

`wazuh-install-files.tar` chứa cert và toàn bộ mật khẩu — cất 1 bản riêng, không commit lên Git.

**1.3. Cài Indexer và khởi tạo cluster:**

```bash
bash wazuh-install.sh --wazuh-indexer node-1
bash wazuh-install.sh --start-cluster
```

**1.4. Chỉnh heap JVM** (VM 4 GB → 2 GB): sửa `/etc/wazuh-indexer/jvm.options` thành `-Xms2g` và `-Xmx2g`, rồi `systemctl restart wazuh-indexer`.

**1.5. Kiểm tra:**

```bash
ADMIN_PW=$(tar -axf wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt -O | grep -P "'admin'" -A 1 | tail -1 | awk -F"'" '{print $2}')
curl -k -u admin:$ADMIN_PW https://192.168.100.31:9200
curl -k -u admin:$ADMIN_PW "https://192.168.100.31:9200/_cat/nodes?v"
```

✔ Lệnh đầu trả JSON có `"cluster_name" : "wazuh-cluster"`; lệnh sau liệt kê `node-1`. → Snapshot.

## Bước 2 — Wazuh Server (VM .30)

Cài manager + Filebeat, Filebeat tự cấu hình đẩy alert sang Indexer .31:9200 nhờ cert đã sinh.

```bash
sudo -i
cd /home/<user>
bash wazuh-install.sh --wazuh-server wazuh-1
```

Kiểm tra:

```bash
systemctl status wazuh-manager filebeat --no-pager
filebeat test output          # phải ra "talk to server... OK"
/var/ossec/bin/wazuh-control status
```

✔ `filebeat test output` báo OK tới 192.168.100.31:9200; các tiến trình `wazuh-analysisd`, `wazuh-remoted`, `wazuh-apid` đều `is running`. → Snapshot.

## Bước 3 — Wazuh Dashboard (VM .32) và chốt cụm Wazuh

```bash
sudo -i
cd /home/<user>
bash wazuh-install.sh --wazuh-dashboard dashboard
```

Cuối quá trình script in user `admin` + mật khẩu. Truy cập `https://192.168.100.32` từ máy thật (bỏ qua cảnh báo cert tự ký).

Sau khi cả 3 node chạy ổn, **khóa phiên bản** trên cả 3 VM để `apt upgrade` không làm lệch version giữa các node:

```bash
sed -i "s/^deb /#deb /" /etc/apt/sources.list.d/wazuh.list && apt update
```

✔ Đăng nhập Dashboard được; trang **Server management → Status** báo manager active; vào **Threat Hunting** thấy đã có vài alert của chính manager (rule 502, 503…) — chứng tỏ luồng Server → Indexer → Dashboard đã thông. → Snapshot cả 3 VM "B3-wazuh-ok".

## Bước 4 — VM Web: Docker, WAF + DVWA (VM .20)

**4.1. Cài Docker:**

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # logout/login lại
mkdir -p ~/lab-web && cd ~/lab-web
```

**4.2. Tạo Dockerfile cho DVWA.** DVWA đứng sau reverse proxy nên mặc định chỉ thấy IP container WAF (172.x). Bật `mod_remoteip` để Apache lấy IP thật của kẻ tấn công từ header `X-``Real-IP` mà WAF chèn vào, và ghi IP đó vào access log. Tạo `~/lab-web/dvwa/Dockerfile`:

```dockerfile
FROM vulnerables/web-dvwa
RUN a2enmod remoteip && \
    printf 'RemoteIPHeader X-Real-IP\nRemoteIPInternalProxy 172.16.0.0/12\n' > /etc/apache2/conf-available/remoteip.conf && \
    a2enconf remoteip && \
    sed -i 's/^LogFormat "%h /LogFormat "%a /' /etc/apache2/apache2.conf
```

**4.3. Tạo `docker-compose.yml`** (chưa bật syslog — để Bước 5):

```yaml
services:
  dvwa:
    build: ./dvwa
    container_name: dvwa
    restart: unless-stopped
    networks: [webnet]          # không publish port: chỉ đi qua WAF

  waf:
    image: owasp/modsecurity-crs:nginx
    container_name: waf
    restart: unless-stopped
    depends_on: [dvwa]
    ports:
      - "80:8080"
    environment:
      BACKEND: "http://dvwa:80"
      PORT: "8080"
      LOGLEVEL: "info"                # BẮT BUỘC: dòng Warning của từng luật CRS ghi ở mức info
      MODSEC_RULE_ENGINE: "On"        # DetectionOnly khi demo 'không có WAF'
      BLOCKING_PARANOIA: "1"          # CRS v4 dùng tên này thay PARANOIA
      ANOMALY_INBOUND: "5"
      ANOMALY_OUTBOUND: "4"
      MODSEC_AUDIT_ENGINE: "RelevantOnly"
      MODSEC_AUDIT_LOG_FORMAT: "JSON"
    networks: [webnet]

networks:
  webnet:
```

`LOGLEVEL: "info"` là bắt buộc: connector ModSecurity-nginx ghi dòng `ModSecurity: Warning` (942xxx, 941xxx…) ở mức `info`, còn image mặc định `warn` → thiếu biến này thì chỉ còn dòng `Access denied` (949110) và các rule phân loại 100201–100206 không bao giờ bật.

```bash
docker compose up -d --build && docker compose ps
```

Image `vulnerables/web-dvwa` chỉ có bản amd64; nếu chạy trên chip ARM thì đổi dòng `FROM` trong Dockerfile sang `ghcr.io/digininja/dvwa`, thêm 1 container MariaDB và kiểm tra lại đường dẫn cấu hình Apache trong lệnh `sed`.

**4.4. Khởi tạo DVWA:** từ trình duyệt máy Kali mở `http://192.168.100.20/setup.php` → **Create / Reset Database** → đăng nhập `admin` / `password` → **DVWA Security** → chọn `low`.

**4.5. Kiểm tra từ Kali:**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.100.20/login.php                       # 200
curl -s -o /dev/null -w "%{http_code}\n" "http://192.168.100.20/?id=1%27%20OR%20%271%27=%271"   # 403
```

Trên VM Web: `docker logs waf 2>&1 | grep ModSecurity | tail -5`. Copy vài dòng `ModSecurity: Warning` và `ModSecurity: Access denied` lưu vào file làm mẫu test decoder.

Kiểm tra log DVWA: `docker logs dvwa 2>&1 | tail -3` phải có dòng access log bắt đầu bằng `192.168.100.10` (request `login.php` vừa gửi từ Kali). Ra `172.x` là remoteip chưa ăn; không có dòng access log nào là image không in log ra stdout — báo lại để đổi cách lấy.

✔ Request sạch 200, request SQLi 403; log WAF có `[id "942..."]` và `[id "949110"]`; log DVWA ghi IP thật .10. → Snapshot.

## Bước 5 — Đẩy log WAF và DVWA sang Wazuh qua syslog

**5.1. Mở cổng nhận syslog trên Wazuh Server.** Thêm khối này vào `/var/ossec/etc/ossec.conf` (giữ nguyên khối `<remote>` secure 1514 đã có):

```xml
<remote>
  <connection>syslog</connection>
  <port>514</port>
  <protocol>udp</protocol>
  <allowed-ips>192.168.100.20/32</allowed-ips>
  <local_ip>192.168.100.30</local_ip>
</remote>
```

Tạm bật lưu toàn bộ log thô để debug: trong khối `<global>` đặt `<logall_json>yes</logall_json>`. Sau đó `systemctl restart wazuh-manager` và kiểm tra `ss -lunp | grep 514`.

**5.2. Bật Docker logging driver cho cả 2 container trên VM Web.** Thêm khối `logging` vào cả 2 service, chỉ khác `tag`:

```yaml
  dvwa:
    # ...giữ nguyên phần trên...
    logging:
      driver: syslog
      options:
        syslog-address: "udp://192.168.100.30:514"
        syslog-format: "rfc3164"
        tag: "dvwa"

  waf:
    # ...giữ nguyên phần trên...
    logging:
      driver: syslog
      options:
        syslog-address: "udp://192.168.100.30:514"
        syslog-format: "rfc3164"
        tag: "modsec"
```

```bash
docker compose up -d --force-recreate
```

`tag` trở thành `program_name` bên Wazuh — cách để phân biệt 2 nguồn. Nguồn `modsec` gồm error log (dòng `ModSecurity:`), access log nginx và audit log JSON; nguồn `dvwa` gồm access log Apache. Docker 20.10+ vẫn giữ bản sao cục bộ nên `docker logs` vẫn dùng được.

**5.3. Kiểm tra luồng:** bắn lại request SQLi từ Kali, trên Wazuh Server chạy song song:

```bash
tcpdump -i any -nn -A udp port 514 | grep -iE 'modsec|dvwa'
tail -f /var/ossec/logs/archives/archives.json | grep -E 'modsec|dvwa'
```

✔ tcpdump thấy gói từ 192.168.100.20; archives.json có bản ghi với `"program_name":"modsec"` (full_log chứa `ModSecurity:`) và `"program_name":"dvwa"` (full_log là dòng access log). Ghi lại 1–2 `full_log` mỗi loại để test decoder. → Snapshot.

## Bước 6 — Decoder và rule cho log WAF và DVWA

Phần tự viết của đồ án là 2 file cho log WAF (6.1–6.3); log DVWA dùng decoder và rule có sẵn của Wazuh (6.4). Wazuh phân biệt 2 nguồn qua `program_name` = tag `modsec` / `dvwa` gắn ở Bước 5.

**6.1. Decoder** — `/var/ossec/etc/decoders/modsec_decoders.xml`:

```xml
<decoder name="modsec">
  <program_name>^modsec</program_name>
</decoder>

<decoder name="modsec-fields">
  <parent>modsec</parent>
  <prematch>ModSecurity: </prematch>
  <regex type="pcre2">\[client ([\d.]+)\] ModSecurity: (Warning|Access denied[^.]*)\..*?\[id "(\d+)"\].*?\[msg "([^"]*)"\].*?\[uri "([^"]*)"\]</regex>
  <order>srcip, modsec_action, modsec_id, modsec_msg, url</order>
</decoder>
```

**6.2. Rule** — `/var/ossec/etc/rules/modsec_rules.xml`. Phân loại theo dải ID của CRS: 942 = SQLi, 941 = XSS, 932 = RCE, 930 = LFI, 933 = PHP injection, 913 = scanner, 949110 = vượt ngưỡng điểm (bị chặn khi engine On, chỉ cảnh báo khi DetectionOnly).

```xml
<group name="modsec,web,attack,">

  <rule id="100200" level="3">
    <decoded_as>modsec</decoded_as>
    <field name="modsec_id">\d+</field>
    <description>WAF: ModSecurity rule $(modsec_id) - $(modsec_msg)</description>
  </rule>

  <rule id="100201" level="8">
    <if_sid>100200</if_sid>
    <field name="modsec_id">^942</field>
    <description>WAF: SQL Injection từ $(srcip)</description>
    <mitre><id>T1190</id></mitre>
    <group>sqli,</group>
  </rule>

  <rule id="100202" level="8">
    <if_sid>100200</if_sid>
    <field name="modsec_id">^941</field>
    <description>WAF: XSS từ $(srcip)</description>
    <mitre><id>T1190</id></mitre>
    <group>xss,</group>
  </rule>

  <rule id="100203" level="10">
    <if_sid>100200</if_sid>
    <field name="modsec_id">^932</field>
    <description>WAF: Remote Command Execution từ $(srcip)</description>
    <mitre><id>T1190</id><id>T1059</id></mitre>
    <group>rce,</group>
  </rule>

  <rule id="100204" level="8">
    <if_sid>100200</if_sid>
    <field name="modsec_id">^930</field>
    <description>WAF: LFI / Path Traversal từ $(srcip)</description>
    <mitre><id>T1190</id></mitre>
    <group>lfi,</group>
  </rule>

  <rule id="100205" level="8">
    <if_sid>100200</if_sid>
    <field name="modsec_id">^933</field>
    <description>WAF: PHP Injection từ $(srcip)</description>
    <mitre><id>T1190</id></mitre>
  </rule>

  <rule id="100206" level="6">
    <if_sid>100200</if_sid>
    <field name="modsec_id">^913</field>
    <description>WAF: Scanner/công cụ tấn công từ $(srcip)</description>
    <mitre><id>T1595</id></mitre>
    <group>scanner,</group>
  </rule>

  <rule id="100210" level="10">
    <if_sid>100200</if_sid>
    <field name="modsec_id">^949110$</field>
    <description>WAF: vượt ngưỡng điểm bất thường từ $(srcip) - $(modsec_action)</description>
    <mitre><id>T1190</id></mitre>
    <group>blocked,</group>
  </rule>

  <rule id="100220" level="13" frequency="10" timeframe="60" ignore="120">
    <if_matched_group>modsec</if_matched_group>
    <same_srcip />
    <description>WAF: tấn công dồn dập từ $(srcip) (≥10 cảnh báo/60s)</description>
    <mitre><id>T1190</id></mitre>
    <group>correlation,</group>
  </rule>

</group>
```

**6.3. Nạp và test:**

```bash
/var/ossec/bin/wazuh-analysisd -t        # kiểm tra cú pháp, không lỗi mới restart
systemctl restart wazuh-manager
/var/ossec/bin/wazuh-logtest             # dán nguyên 1 dòng full_log đã lưu ở Bước 5
```

✔ wazuh-logtest in ra: Phase 2 `name: 'modsec'` có đủ 5 trường `srcip`, `modsec_action`, `modsec_id`, `modsec_msg`, `url`; Phase 3 khớp đúng rule (dòng 942xxx → 100201, dòng 949110 → 100210) và báo `Alert to be generated`. Bắn thật từ Kali → Dashboard thấy alert. → Snapshot, commit 2 file lên Git.

Mỗi request bị chặn sinh nhiều alert (mỗi rule CRS khớp 1 dòng Warning + 1 dòng 949110). Đó là bình thường; chính điều này khiến sqlmap/nikto kích hoạt rule 100220 rất nhanh.

**6.4. Log DVWA dùng decoder có sẵn.** Không phải viết decoder mới: Wazuh có sẵn decoder `web-accesslog` cho access log Apache và nhóm rule web 311xx (ví dụ 31103 SQLi, 31105 XSS, 31106 "web attack trả về 200"). Dán 1 dòng `full_log` của nguồn `dvwa` vào `wazuh-logtest`.

Khi WAF đang `On`, log DVWA chỉ chứa request sạch (rule 31100 level 0, không sinh cảnh báo) — đúng như mong đợi vì request tấn công đã bị chặn ở WAF. Rule tấn công 311xx chỉ bật khi demo DetectionOnly (Bước 8.3).

✔ Phase 2 ra decoder `web-accesslog` và `srcip` = 192.168.100.10 (không phải 172.x). Nếu decoder có sẵn không tách được dòng log, viết thêm decoder theo `program_name` `dvwa`, giống cách làm ở 6.1.

## Bước 7 — Firewall theo ma trận kết nối

Bật `ufw` trên 4 VM Ubuntu, mặc định chặn chiều vào, cho phép chiều ra (để còn `apt`). Máy quản trị = máy thật, với VMware NAT thường là `192.168.100.1` — kiểm tra lại bằng `ipconfig` trên máy thật. **Mở SSH trước khi `ufw enable`** kẻo tự khóa mình.

```bash
# Chung cho mọi VM Ubuntu
ufw default deny incoming && ufw default allow outgoing
ufw allow from 192.168.100.1 to any port 22 proto tcp

# Wazuh Server (.30)
ufw allow from 192.168.100.20 to any port 514 proto udp
ufw allow from 192.168.100.32 to any port 55000 proto tcp

# Wazuh Indexer (.31)
ufw allow from 192.168.100.30 to any port 9200 proto tcp
ufw allow from 192.168.100.32 to any port 9200 proto tcp

# Wazuh Dashboard (.32)
ufw allow from 192.168.100.1 to any port 443 proto tcp

ufw enable && ufw status numbered
```

**Riêng VM Web (.20):** Docker tự ghi iptables cho cổng publish nên **bỏ qua ufw** — `ufw` không chặn được cổng 80. Phải lọc ở chain `DOCKER-USER`. Thêm vào cuối `/etc/ufw/after.rules` (đổi `ens33` theo tên card):

```text
# BEGIN lab DOCKER-USER
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i ens33 -p tcp -m conntrack --ctorigdstport 80 --ctdir ORIGINAL ! -s 192.168.100.10 -j DROP
-A DOCKER-USER -j RETURN
COMMIT
# END lab DOCKER-USER
```

Rồi `ufw reload` (hoặc `systemctl restart ufw docker`).

✔ Từ Kali: `curl http://192.168.100.20` được; `nc -zv 192.168.100.31 9200` và `nc -zv 192.168.100.30 55000` bị chặn. Từ máy thật: vào Dashboard được, vào `http://192.168.100.20` bị chặn. Chạy lại 1 request SQLi → vẫn ra alert trên Dashboard. → Snapshot.

## Bước 8 — Kịch bản tấn công và dashboard demo

**8.1. `attack.sh` trên Kali** — mỗi loại 1 payload, in mã HTTP trả về (mong đợi 403):

```bash
#!/usr/bin/env bash
# attack.sh - sinh traffic tấn công mẫu vào WAF
T="${1:-http://192.168.100.20}"
hit() { printf "%-5s %s\n" "$1" "$(curl -s -o /dev/null -w '%{http_code}' "${@:2}")"; sleep 1; }

hit SQLi "$T/vulnerabilities/sqli/?id=1%27%20OR%20%271%27%3D%271&Submit=Submit"
hit SQLi "$T/vulnerabilities/sqli/?id=1%20UNION%20SELECT%20user,password%20FROM%20users--%20-&Submit=Submit"
hit XSS  "$T/vulnerabilities/xss_r/?name=%3Cscript%3Ealert(document.cookie)%3C%2Fscript%3E"
hit RCE  -X POST -d "ip=127.0.0.1;cat /etc/passwd&Submit=Submit" "$T/vulnerabilities/exec/"
hit LFI  "$T/vulnerabilities/fi/?page=../../../../etc/passwd"
hit SCAN -A "Nikto" "$T/"
```

**8.2. Tấn công dồn dập** để kích hoạt rule 100220 (level 13):

```bash
nikto -h http://192.168.100.20
sqlmap -u "http://192.168.100.20/vulnerabilities/sqli/?id=1&Submit=Submit" \
  --cookie="PHPSESSID=<lấy từ trình duyệt>; security=low" --batch
```

**8.3. So sánh có/không chặn — màn tương quan 2 nguồn:** đổi `MODSEC_RULE_ENGINE: "DetectionOnly"`, `docker compose up -d --force-recreate waf`. Trên trình duyệt Kali đã đăng nhập DVWA, vào SQL Injection nhập `1' UNION SELECT user,password FROM users#` → DVWA trả danh sách user + hash mật khẩu. Cùng một request, Dashboard ra 2 loại cảnh báo: 1002xx từ WAF (phát hiện) và 311xx từ log DVWA (mã 200 = tấn công đã vào tới ứng dụng). Demo xong đổi lại `On`.

**8.4. Dashboard:**

- Dashboard Management → Index patterns → `wazuh-alerts-*` → **Refresh fields** để thấy `data.modsec_id`, `data.modsec_msg`, `data.url`.
- Threat Hunting → lọc `rule.groups: modsec`; thêm cột `rule.id`, `rule.level`, `data.srcip`, `data.modsec_id`, `data.url`, `rule.description`. Lưu thành saved search "WAF alerts". Tạo thêm saved search "DVWA alerts" lọc decoder.name: web-accesslog.
- Tab **MITRE ATT&CK**: thấy T1190, T1059, T1595.
- Tạo dashboard riêng "WAF Overview" gồm 3 visualization: pie theo `rule.description`, bar theo thời gian chia theo `rule.id`, bảng top `data.srcip`.

✔ Chạy `attack.sh` → 6 dòng 403; Dashboard có alert 100201–100206 và 100210; chạy nikto → có alert 100220 level 13.

## Bước 9 — Checklist nghiệm thu

- [ ] 5 VM ping được nhau, giờ đồng bộ
- [ ] Indexer trả `wazuh-cluster`, Filebeat test output OK, Dashboard đăng nhập được
- [ ] Request sạch qua WAF trả 200, request tấn công trả 403
- [ ] DVWA không truy cập trực tiếp được (không publish port)
- [ ] Log WAF và DVWA tới Wazuh qua UDP 514 (program_name modsec / dvwa), chỉ nhận từ .20
- [ ] wazuh-logtest decode đủ 5 trường, khớp đúng rule; log DVWA ra srcip 192.168.100.10
- [ ] Đủ 6 loại alert: SQLi, XSS, RCE, LFI, scanner, vượt ngưỡng (100210)
- [ ] Rule 100220 level 13 bật khi chạy nikto/sqlmap
- [ ] Tab MITRE hiển thị T1190
- [ ] Firewall đúng ma trận (thử cả luồng được phép và bị chặn)
- [ ] Demo DetectionOnly: cùng 1 request SQLi ra cảnh báo WAF (1002xx) lẫn DVWA (311xx)
- [ ] Tắt `logall_json` (đặt lại `no`) để không đầy đĩa
- [ ] Snapshot cuối "GD1-done", repo Git có đủ compose, ossec.conf (phần sửa), dvwa/Dockerfile, decoder, rule, attack.sh, after.rules
- [ ] Ảnh chụp cho báo cáo: 403 trên Kali, logtest, danh sách alert, MITRE, dashboard WAF Overview, cặp cảnh báo WAF + DVWA ở màn DetectionOnly

## Xử lý sự cố thường gặp

| Triệu chứng | Kiểm tra / cách sửa |
| --- | --- |
| `--start-cluster` lỗi, Indexer không lên | `journalctl -u wazuh-indexer`; thường do thiếu RAM hoặc heap quá lớn — giảm `-Xms/-Xmx`; kiểm tra IP trong `config.yml` khớp IP thật |
| Dashboard báo "Wazuh API not reachable" | Server có chạy `wazuh-apid` không; firewall đã mở 55000 từ .32 chưa |
| Không có gói nào tới cổng 514 | Trên Web: `docker inspect waf`` ``--format '{{.HostConfig.LogConfig}}'` (làm tương tự với `dvwa`) xem đúng driver chưa; container phải recreate sau khi sửa logging |
| Có gói 514 nhưng archives trống | Sai `allowed-ips` / `local_ip`; xem `/var/ossec/logs/ossec.log` dòng `wazuh-remoted` |
| archives có log nhưng không ra alert | Chạy `wazuh-logtest`: Phase 2 ra decoder khác hoặc thiếu trường → so regex với dòng log thật; `program_name` không phải `modsec` / dvwa → kiểm tra `tag` và `syslog-format` |
| Alert có trong `alerts.json` nhưng không lên Dashboard | `filebeat test output`; Indexer đầy đĩa → index chuyển read-only (`df -h`) |
| Không thấy `data.modsec_*` khi lọc | Refresh fields của index pattern `wazuh-alerts-*` |
| Cổng 80 vẫn mở cho mọi IP dù đã bật ufw | Docker bỏ qua ufw — dùng chain `DOCKER-USER` (Bước 7) |
| Request sạch cũng bị 403 | Xem `[id]` trong log: thường là 920xxx (protocol); giữ PL1, không tăng paranoia |
| Log DVWA ghi IP 172.x thay vì .10 | remoteip chưa bật (docker exec dvwa apache2ctl -M \| grep remoteip) hoặc WAF không gửi header X-Real-IP, hoặc subnet Docker nằm ngoài 172.16.0.0/12 (docker network inspect) — sửa RemoteIPInternalProxy rồi build lại |
| Không có log nguồn dvwa trên Wazuh | docker logs dvwa không có dòng access log → image không in log ra stdout, cần đổi cách lấy; có log nhưng không tới Wazuh → kiểm tra khối logging của service dvwa và recreate container |
| Chỉ có cảnh báo 100210, không có 100201–100206 | Thiếu LOGLEVEL: "info" trong compose → dòng ModSecurity: Warning không được ghi; thêm biến rồi recreate container waf |

## Các quyết định đã chốt

Khớp với file .docx kiến trúc giai đoạn 1.

- **Quy mô:** 1 người thực hiện, 5 VM; Kali giữ VM tấn công riêng (.10).
- **Wazuh:** bản 4.14, tách 3 VM Server / Indexer / Dashboard.
- **Nguồn log:** 2 nguồn qua syslog UDP 514 — log WAF (tag `modsec`, decoder/rule tự viết) và access log DVWA (tag `dvwa`, decoder/rule có sẵn).
- **Agent:** chưa cài ở giai đoạn 1; cài trên VM Web từ giai đoạn 2 (Suricata/Zeek, Active Response), lúc đó mở thêm 1514–1515/tcp.
- **WAF:** `LOGLEVEL=info`, `BLOCKING_PARANOIA=1`, `ANOMALY_INBOUND=5`; gửi IP client qua `X-Real-IP`, DVWA đọc bằng `mod_remoteip`.
- **Decoder WAF:** tách `srcip`, `modsec_action`, `modsec_id`, `modsec_msg`, `url`; rule 100200–100220.
- **Mạng:** 7 luồng trong ma trận kết nối (gồm SSH từ máy quản trị); cổng 80 trên VM Web lọc ở chain `DOCKER-USER`.

## Nguồn

- [Wazuh 4.14 — cài Wazuh server bằng installation assistant](https://documentation.wazuh.com/current/installation-guide/wazuh-server/installation-assistant.html)
- [coreruleset/modsecurity-crs-docker — biến môi trường của image](https://github.com/coreruleset/modsecurity-crs-docker)

- [ModSecurity-nginx — ngx_http_modsecurity_log.c (dòng Warning ghi ở mức NGX_LOG_INFO)](https://github.com/owasp-modsecurity/ModSecurity-nginx/blob/master/src/ngx_http_modsecurity_log.c)
