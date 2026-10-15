#!/usr/bin/env bash
# VigilAI — sinh traffic tấn công mẫu vào WAF (Bước 8.1). Chạy trên Kali.
# Dùng: ./attack.sh [http://192.168.100.20]   -> mong đợi mọi dòng trả 403
T="${1:-http://192.168.100.20}"
hit() { printf "%-5s %s\n" "$1" "$(curl -s -o /dev/null -w '%{http_code}' "${@:2}")"; sleep 1; }

hit SQLi "$T/vulnerabilities/sqli/?id=1%27%20OR%20%271%27%3D%271&Submit=Submit"
hit SQLi "$T/vulnerabilities/sqli/?id=1%20UNION%20SELECT%20user,password%20FROM%20users--%20-&Submit=Submit"
hit XSS  "$T/vulnerabilities/xss_r/?name=%3Cscript%3Ealert(document.cookie)%3C%2Fscript%3E"
hit RCE  -X POST -d "ip=127.0.0.1;cat /etc/passwd&Submit=Submit" "$T/vulnerabilities/exec/"
hit LFI  "$T/vulnerabilities/fi/?page=../../../../etc/passwd"
hit SCAN -A "Nikto" "$T/"
