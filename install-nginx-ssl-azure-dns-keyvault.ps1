# Install Nginx with SSL support on Windows using PowerShell
# Let´s Encrypt Azure DNS validation

param(
    [Parameter(Mandatory)]
    [string]$hostname,
    [Parameter(Mandatory)]
    [string]$KeyVaultName,
    [Parameter(Mandatory)]
    [string]$tenantId,
    [Parameter(Mandatory)]
    [string]$subscriptionId,
    [Parameter()]
    [bool]$Staging = $true
)

Start-Transcript -Path "e:\install-nginx.log" -Append

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
	location /.well-known {
	    root html;
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

Invoke-WebRequest 'https://github.com/win-acme/win-acme/releases/download/v2.2.9.1701/win-acme.v2.2.9.1701.x64.pluggable.zip' -OutFile 'e:\win-acme.zip'
Expand-Archive e:\win-acme.zip e:\win-acme
Invoke-WebRequest 'https://github.com/simple-acme/simple-acme/releases/download/v2.3.2/simple-acme.v2.3.2.1981.win-x64.pluggable.zip' -OutFile 'e:\simple-acme.zip'
Expand-Archive e:\simple-acme.zip e:\simple-acme
Invoke-WebRequest 'https://github.com/simple-acme/simple-acme/releases/download/v2.3.2/plugin.validation.dns.azure.v2.3.2.1981.zip' -OutFile 'e:\simple-acme-azure-dns-plugin.zip'
Expand-Archive e:\simple-acme-azure-dns-plugin.zip e:\simple-acme
Invoke-WebRequest 'https://github.com/simple-acme/simple-acme/releases/download/v2.3.2/plugin.store.keyvault.v2.3.2.1981.zip' -OutFile 'e:\simple-acme-keyvault-plugin.zip'
Expand-Archive e:\simple-acme-keyvault-plugin.zip e:\simple-acme
New-Item -ItemType Directory -Path e:\nginx\conf\ssl
New-Item -ItemType Directory -Path e:\nginx\html\.well-known

if ($Staging) {
        $baseUri = "https://acme-staging-v02.api.letsencrypt.org"
    }
    else {
        $baseUri = "https://acme-v02.api.letsencrypt.org"
    }

e:\simple-acme\wacs.exe --baseuri $baseUri --verbose `
 --accepttos --emailaddress noreply@noreply.org --source manual --host $hostname --validationmode dns-01 --validation azure  `
 --store pemfiles,keyvault --pemfilespath e:\nginx\conf\ssl --pemfilesname $hostname `
 --vaultname $keyVaultName --certificatename $hostname.Replace('.','-').Replace('*','wildcard') `
 --azuretenantid $tenantId --azuresubscriptionid $subscriptionId --azureusemsi

# e:\simple-acme\wacs.exe --verbose `
# --accepttos --emailaddress noreply@noreply.org --source manual --host $hostname --validationmode dns-01 --validation azure  `
# --store pemfiles --pemfilespath e:\nginx\conf\ssl --pemfilesname $hostname `
# --azuretenantid $tenantId --azuresubscriptionid $subscriptionId --azureusemsi

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
	location /.well-known {
	    root html;
        }
        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   html;
        }
    }
    server {
        listen       $FirstIp`:443 ssl;
        
        ssl_certificate      ssl/$($hostname.Replace('*','_'))-chain.pem;
        ssl_certificate_key  ssl/$($hostname.Replace('*','_'))-key.pem;

        ssl_session_cache    shared:SSL:1m;
        ssl_session_timeout  5m;

        ssl_ciphers  HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers  on;

        location / {
            proxy_bind  $FirstIp;
            proxy_pass https://ifconfig.me;
            proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP `$remote_addr;
        }
		
    }
}
"@ | Out-File -FilePath e:/nginx/conf/nginx.conf -Encoding ascii
Restart-Service nginx
Stop-Transcript
