# Kali (192.168.100.10) — đặt IP tĩnh bằng NetworkManager

```bash
nmcli con show                       # xem tên kết nối, thường là "Wired connection 1"
sudo nmcli con mod "Wired connection 1" ipv4.method manual \
  ipv4.addresses 192.168.100.10/24 ipv4.gateway 192.168.100.2 \
  ipv4.dns "8.8.8.8 1.1.1.1"
sudo nmcli con up "Wired connection 1"
```
