# DVWA + mod_remoteip: ghi IP thật của kẻ tấn công (WAF gửi qua header X-Real-IP)
# thay vì IP container WAF (172.x). Xem Bước 4.2 trong kế hoạch.
FROM vulnerables/web-dvwa
RUN a2enmod remoteip && \
    printf 'RemoteIPHeader X-Real-IP\nRemoteIPInternalProxy 172.16.0.0/12\n' > /etc/apache2/conf-available/remoteip.conf && \
    a2enconf remoteip && \
    sed -i 's/^LogFormat "%h /LogFormat "%a /' /etc/apache2/apache2.conf
