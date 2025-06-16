# Firewall config
netsh advfirewall firewall add rule name="http" dir=in action=allow protocol=TCP localport=80
netsh advfirewall firewall add rule name="https" dir=in action=allow protocol=TCP localport=443

# Download nginx.
Set-Location e:\
Invoke-WebRequest 'https://nginx.org/download/nginx-1.27.5.zip' -OutFile 'e:/nginx.zip'

# Download NSSM
Invoke-WebRequest 'https://github.com/jensdiedrich/vmdeploy/raw/main/nssm-2.24.zip' -OutFile 'e:/nssm.zip'

# Install Nginx.
Expand-Archive e:/nginx.zip e:/
Move-Item e:/nginx-1.27.5 e:/nginx

# Install NSSM.
Expand-Archive e:/nssm.zip e:/
Copy-Item e:/nssm-2.24/win64/nssm.exe e:/nginx

$FirstIp = (Get-NetIPAddress | Where-Object {$_.AddressFamily -eq "IPv4"} | Where-Object {$_.InterfaceAlias -notmatch "Loopback"}).IPAddress

@"
events {
    worker_connections  1024;
}


http {
    include       mime.types;
    default_type  application/octet-stream;

    log_format  main  '`$remote_addr - `$remote_user [`$time_local] "`$request" '
                      '`$status `$body_bytes_sent "`$http_referer" '
                      '"`$http_user_agent" "`$http_x_forwarded_for"';

    access_log  logs/access.log  main;

    sendfile        on;
    keepalive_timeout  65;
    server {
        listen       $FirstIp`:80;
        server_name  lb1;
        

	location / {
            proxy_bind $FirstIp;
            proxy_pass http://ifconfig.me;
            proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP `$remote_addr;
        }
        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   html;
        }
    }
}
"@ | Out-File -FilePath e:/nginx/conf/nginx.conf -Encoding ascii

e:\nginx\nssm.exe install nginx e:\nginx\nginx.exe
e:\nginx\nssm.exe start nginx

Stop-Transcript
