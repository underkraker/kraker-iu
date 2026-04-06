#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Error fatal: ${plain} Por favor, ejecute este script con privilegios de root \n " && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
    elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "¡Error al verificar el sistema operativo, por favor contacte al autor!" >&2
    exit 1
fi
echo "La versión del SO es: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}¡Arquitectura de CPU no soportada! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "Arch: $(arch)"

# Simple helpers
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# Port helpers
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    return 1
}

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
        ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q curl tar tzdata socat ca-certificates openssl
        ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y curl tar tzdata socat ca-certificates openssl
            else
                dnf -y update && dnf install -y -q curl tar tzdata socat ca-certificates openssl
            fi
        ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm curl tar tzdata socat ca-certificates openssl
        ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y curl tar timezone socat ca-certificates openssl
        ;;
        alpine)
            apk update && apk add curl tar tzdata socat ca-certificates openssl
        ;;
        *)
            apt-get update && apt-get install -y -q curl tar tzdata socat ca-certificates openssl
        ;;
    esac
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $(( length * 2 )) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

install_acme() {
    echo -e "${green}Instalando acme.sh para la gestión de certificados SSL...${plain}"
    cd ~ || return 1
    curl -s https://get.acme.sh | sh >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${red}Fallo al instalar acme.sh${plain}"
        return 1
    else
        echo -e "${green}acme.sh instalado con éxito${plain}"
    fi
    return 0
}

setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"
    
    echo -e "${green}Configurando certificado SSL...${plain}"
    
    # Check if acme.sh is installed
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}Fallo al instalar acme.sh, omitiendo la configuración de SSL${plain}"
            return 1
        fi
    fi
    
    # Create certificate directory
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"
    
    # Issue certificate
    echo -e "${green}Emitiendo certificado SSL para ${domain}...${plain}"
    echo -e "${yellow}Nota: El puerto 80 debe estar abierto y accesible desde internet${plain}"
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport 80 --force
    
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Fallo al emitir el certificado para ${domain}${plain}"
        echo -e "${yellow}Por favor, asegúrese de que el puerto 80 esté abierto e inténtelo de nuevo más tarde con: x-ui${plain}"
        rm -rf ~/.acme.sh/${domain} 2>/dev/null
        rm -rf "$certPath" 2>/dev/null
        return 1
    fi
    
    # Install certificate
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Fallo al instalar el certificado${plain}"
        return 1
    fi
    
    # Enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    # Secure permissions: private key readable only by owner
    chmod 600 $certPath/privkey.pem 2>/dev/null
    chmod 644 $certPath/fullchain.pem 2>/dev/null
    
    # Set certificate for panel
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"
    
    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" >/dev/null 2>&1
        echo -e "${green}¡Certificado SSL instalado y configurado con éxito!${plain}"
        return 0
    else
        echo -e "${yellow}Archivos del certificado no encontrados${plain}"
        return 1
    fi
}

# Issue Let's Encrypt IP certificate with shortlived profile (~6 days validity)
# Requires acme.sh and port 80 open for HTTP-01 challenge
setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2"  # optional

    echo -e "${green}Configurando certificado IP de Let's Encrypt...${plain}"
    echo -e "${yellow}Nota: Los certificados de IP son válidos por ~6 días y se renuevan automáticamente.${plain}"
    echo -e "${yellow}El puerto predeterminado es el 80. Si elige otro, asegúrese de redirigir el puerto 80 externo.${plain}"

    # Check for acme.sh
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${red}Fallo al instalar acme.sh${plain}"
            return 1
        fi
    fi

    # Validate IP address
    if [[ -z "$ipv4" ]]; then
        echo -e "${red}Se requiere una dirección IPv4${plain}"
        return 1
    fi

    if ! is_ipv4 "$ipv4"; then
        echo -e "${red}Dirección IPv4 inválida: $ipv4${plain}"
        return 1
    fi

    # Create certificate directory
    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    # Build domain arguments
    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
        echo -e "${green}Incluyendo dirección IPv6: ${ipv6}${plain}"
    fi

    # Set reload command for auto-renewal (add || true so it doesn't fail during first install)
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    # Choose port for HTTP-01 listener (default 80, prompt override)
    local WebPort=""
    read -rp "Puerto a usar para el validador ACME HTTP-01 (por defecto 80): " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        echo -e "${red}Puerto proporcionado inválido. Usando por defecto el 80.${plain}"
        WebPort=80
    fi
    echo -e "${green}Usando el puerto ${WebPort} para validación standalone.${plain}"
    if [[ "${WebPort}" -ne 80 ]]; then
        echo -e "${yellow}Recordatorio: Let's Encrypt todavía se conecta por el puerto 80; redirija el puerto 80 externo a ${WebPort}.${plain}"
    fi

    # Ensure chosen port is available
    while true; do
        if is_port_in_use "${WebPort}"; then
            echo -e "${yellow}El puerto ${WebPort} está en uso.${plain}"

            local alt_port=""
            read -rp "Ingrese otro puerto para el validador standalone de acme.sh (deje vacío para abortar): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                echo -e "${red}El puerto ${WebPort} está ocupado; no se puede proceder.${plain}"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                echo -e "${red}Puerto proporcionado inválido.${plain}"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            echo -e "${green}El puerto ${WebPort} está libre y listo para la validación standalone.${plain}"
            break
        fi
    done

    # Issue certificate with shortlived profile
    echo -e "${green}Emitiendo certificado IP para ${ipv4}...${plain}"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1
    
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        echo -e "${red}Fallo al emitir certificado IP${plain}"
        echo -e "${yellow}Por favor, asegúrese de que el puerto ${WebPort} sea accesible (o esté redirigido desde el puerto 80 externo)${plain}"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${ipv4} 2>/dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2>/dev/null
        rm -rf ${certDir} 2>/dev/null
        return 1
    fi

    echo -e "${green}Certificate issued successfully, installing...${plain}"

    # Install certificate
    # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
    # but the cert files are still installed. We check for files instead of exit code.
    ~/.acme.sh/acme.sh --installcert -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}Archivos del certificado no encontrados después de la instalación${plain}"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${ipv4} 2>/dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2>/dev/null
        rm -rf ${certDir} 2>/dev/null
        return 1
    fi
    
    echo -e "${green}Certificate files installed successfully${plain}"

    # Enable auto-upgrade for acme.sh (ensures cron job runs)
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1

    # Secure permissions: private key readable only by owner
    chmod 600 ${certDir}/privkey.pem 2>/dev/null
    chmod 644 ${certDir}/fullchain.pem 2>/dev/null

    # Configure panel to use the certificate
    echo -e "${green}Setting certificate paths for the panel...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"
    
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Warning: Could not set certificate paths automatically${plain}"
        echo -e "${yellow}Certificate files are at:${plain}"
        echo -e "  Cert: ${certDir}/fullchain.pem"
        echo -e "  Key:  ${certDir}/privkey.pem"
    else
        echo -e "${green}Certificate paths configured successfully${plain}"
    fi

    echo -e "${green}¡Certificado IP instalado y configurado con éxito!${plain}"
    echo -e "${green}El certificado es válido por ~6 días, se renueva automáticamente vía tarea cron de acme.sh.${plain}"
    echo -e "${yellow}acme.sh renovará y recargará KRAKER X-UI automáticamente antes del vencimiento.${plain}"
    return 0
}

# Comprehensive manual SSL certificate issuance via acme.sh
ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo "acme.sh could not be found. Installing now..."
        cd ~ || return 1
        curl -s https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            echo -e "${red}Failed to install acme.sh${plain}"
            return 1
        else
            echo -e "${green}acme.sh installed successfully${plain}"
        fi
    fi

    # get the domain here, and we need to verify it
    local domain=""
    while true; do
        read -rp "Please enter your domain name: " domain
        domain="${domain// /}"  # Trim whitespace
        
        if [[ -z "$domain" ]]; then
            echo -e "${red}Domain name cannot be empty. Please try again.${plain}"
            continue
        fi
        
        if ! is_domain "$domain"; then
            echo -e "${red}Invalid domain format: ${domain}. Please enter a valid domain name.${plain}"
            continue
        fi
        
        break
    done
    echo -e "${green}Su dominio es: ${domain}, verificándolo...${plain}"

    # check if there already exists a certificate
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
    if [ "${currentCert}" == "${domain}" ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        echo -e "${red}El sistema ya tiene certificados para este dominio. No se puede emitir de nuevo.${plain}"
        echo -e "${yellow}Detalles del certificado actual:${plain}"
        echo "$certInfo"
        return 1
    else
        echo -e "${green}Su dominio está listo para la emisión de certificados ahora...${plain}"
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local WebPort=80
    read -rp "Por favor, elija qué puerto usar (por defecto es 80): " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        echo -e "${yellow}Su entrada ${WebPort} es inválida, se usará el puerto 80 por defecto.${plain}"
        WebPort=80
    fi
    echo -e "${green}Se usará el puerto: ${WebPort} para emitir certificados. Por favor asegúrese de que esté abierto.${plain}"

    # Stop panel temporarily
    echo -e "${yellow}Deteniendo el panel temporalmente...${plain}"
    systemctl stop x-ui 2>/dev/null || rc-service x-ui stop 2>/dev/null

    # issue the certificate
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort} --force
    if [ $? -ne 0 ]; then
        echo -e "${red}La emisión del certificado falló, por favor revise los logs.${plain}"
        rm -rf ~/.acme.sh/${domain}
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
        return 1
    else
        echo -e "${green}La emisión del certificado fue exitosa, instalando certificados...${plain}"
    fi

    # Setup reload command
    reloadCmd="systemctl restart x-ui || rc-service x-ui restart"
    echo -e "${green}El --reloadcmd por defecto para ACME es: ${yellow}systemctl restart x-ui || rc-service x-ui restart${plain}"
    echo -e "${green}Este comando se ejecutará cada vez que se emita o renueve un certificado.${plain}"
    read -rp "¿Desea modificar --reloadcmd para ACME? (y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} Preajuste: systemctl reload nginx ; systemctl restart x-ui"
        echo -e "${green}\t2.${plain} Ingrese su propio comando"
        echo -e "${green}\t0.${plain} Mantener reloadcmd por defecto"
        read -rp "Elija una opción: " choice
        case "$choice" in
        1)
            echo -e "${green}Reloadcmd es: systemctl reload nginx ; systemctl restart x-ui${plain}"
            reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
            ;;
        2)
            echo -e "${yellow}Se recomienda poner x-ui restart al final${plain}"
            read -rp "Por favor ingrese su reloadcmd personalizado: " reloadCmd
            echo -e "${green}Reloadcmd es: ${reloadCmd}${plain}"
            ;;
        *)
            echo -e "${green}Manteniendo reloadcmd por defecto${plain}"
            ;;
        esac
    fi

    # install the certificate
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}"

    if [ $? -ne 0 ]; then
        echo -e "${red}Fallo al instalar el certificado, saliendo.${plain}"
        rm -rf ~/.acme.sh/${domain}
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
        return 1
    else
        echo -e "${green}La instalación del certificado fue exitosa, habilitando renovación automática...${plain}"
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Hubo problemas con la configuración de renovación automática, detalles del certificado:${plain}"
        ls -lah /root/cert/${domain}/
        # Secure permissions: private key readable only by owner
        chmod 600 $certPath/privkey.pem 2>/dev/null
        chmod 644 $certPath/fullchain.pem 2>/dev/null
    else
        echo -e "${green}Renovación automática configurada con éxito, detalles del certificado:${plain}"
        ls -lah /root/cert/${domain}/
        # Secure permissions: private key readable only by owner
        chmod 600 $certPath/privkey.pem 2>/dev/null
        chmod 644 $certPath/fullchain.pem 2>/dev/null
    fi

    # start panel
    systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null

    # Prompt user to set panel paths after successful certificate installation
    read -rp "¿Desea configurar este certificado para el panel? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            echo -e "${green}Rutas del certificado establecidas para el panel${plain}"
            echo -e "${green}Archivo Cert: $webCertFile${plain}"
            echo -e "${green}Archivo Key:  $webKeyFile${plain}"
            echo ""
            echo -e "${green}URL de Acceso: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            echo -e "${yellow}El panel se reiniciará para aplicar el certificado SSL...${plain}"
            systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null
        else
            echo -e "${red}Error: No se encontró el archivo del certificado o llave privada para el dominio: $domain.${plain}"
        fi
    else
        echo -e "${yellow}Omitiendo la configuración de rutas del panel.${plain}"
    fi
    
    return 0
}

# Reusable interactive SSL setup (domain or IP)
# Sets global `SSL_HOST` to the chosen domain/IP for Access URL usage
prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2"   # expected without leading slash
    local server_ip="$3"

    local ssl_choice=""

    echo -e "${yellow}Elija el método de configuración del certificado SSL:${plain}"
    echo -e "${green}1.${plain} Let's Encrypt para Dominio (validez de 90 días, renovación automática)"
    echo -e "${green}2.${plain} Let's Encrypt para Dirección IP (validez de 6 días, renovación automática)"
    echo -e "${green}3.${plain} Certificado SSL Personalizado (Ruta a archivos existentes)"
    echo -e "${blue}Nota:${plain} Las opciones 1 y 2 requieren el puerto 80 abierto. La opción 3 requiere rutas manualas."
    read -rp "Elija una opción (por defecto 2 para IP): " ssl_choice
    ssl_choice="${ssl_choice// /}"  # Trim whitespace
    
    # Default to 2 (IP cert) if input is empty or invalid (not 1 or 3)
    if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" ]]; then
        ssl_choice="2"
    fi

    case "$ssl_choice" in
    1)
        # User chose Let's Encrypt domain option
        echo -e "${green}Usando Let's Encrypt para el certificado de dominio...${plain}"
        ssl_cert_issue
        # Extract the domain that was used from the certificate
        local cert_domain=$(~/.acme.sh/acme.sh --list 2>/dev/null | tail -1 | awk '{print $1}')
        if [[ -n "${cert_domain}" ]]; then
            SSL_HOST="${cert_domain}"
            echo -e "${green}✓ Certificado SSL configurado con éxito para el dominio: ${cert_domain}${plain}"
        else
            echo -e "${yellow}Puede que la configuración SSL haya terminado, pero falló la extracción del dominio${plain}"
            SSL_HOST="${server_ip}"
        fi
        ;;
    2)
        # User chose Let's Encrypt IP certificate option
        echo -e "${green}Usando Let's Encrypt para el certificado IP (perfil shortlived)...${plain}"
        
        # Ask for optional IPv6
        local ipv6_addr=""
        read -rp "¿Tiene una dirección IPv6 para incluir? (deje en blanco para omitir): " ipv6_addr
        ipv6_addr="${ipv6_addr// /}"  # Trim whitespace
        
        # Stop panel if running (port 80 needed)
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop >/dev/null 2>&1
        else
            systemctl stop x-ui >/dev/null 2>&1
        fi
        
        setup_ip_certificate "${server_ip}" "${ipv6_addr}"
        if [ $? -eq 0 ]; then
            SSL_HOST="${server_ip}"
            echo -e "${green}✓ Certificado IP de Let's Encrypt configurado con éxito${plain}"
        else
            echo -e "${red}✗ Falló la configuración del certificado IP. Por favor verifique que el puerto 80 esté abierto.${plain}"
            SSL_HOST="${server_ip}"
        fi
        ;;
    3)
        # User chose Custom Paths (User Provided) option
        echo -e "${green}Usando un certificado personalizado existente...${plain}"
        local custom_cert=""
        local custom_key=""
        local custom_domain=""

        # 3.1 Request Domain to compose Panel URL later
        read -rp "Por favor ingrese el nombre del dominio para el cual se emitió el certificado: " custom_domain
        custom_domain="${custom_domain// /}" # Убираем пробелы

        # 3.2 Loop for Certificate Path
        while true; do
            read -rp "Ingrese la ruta del certificado (ej: .crt / fullchain): " custom_cert
            # Strip quotes if present
            custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

            if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
                break
            elif [[ ! -f "$custom_cert" ]]; then
                echo -e "${red}Error: ¡El archivo no existe! Intente de nuevo.${plain}"
            elif [[ ! -r "$custom_cert" ]]; then
                echo -e "${red}Error: ¡El archivo existe pero no se puede leer (verifique permisos)!${plain}"
            else
                echo -e "${red}Error: File is empty!${plain}"
            fi
        done

        # 3.3 Loop for Private Key Path
        while true; do
            read -rp "Ingrese la ruta de la llave privada (ej: .key / privatekey): " custom_key
            # Strip quotes if present
            custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

            if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
                break
            elif [[ ! -f "$custom_key" ]]; then
                echo -e "${red}Error: ¡El archivo no existe! Intente de nuevo.${plain}"
            elif [[ ! -r "$custom_key" ]]; then
                echo -e "${red}Error: ¡El archivo existe pero no se puede leer (verifique permisos)!${plain}"
            else
                echo -e "${red}Error: File is empty!${plain}"
            fi
        done

        # 3.4 Apply Settings via x-ui binary
        ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" >/dev/null 2>&1
        
        # Set SSL_HOST for composing Panel URL
        if [[ -n "$custom_domain" ]]; then
            SSL_HOST="$custom_domain"
        else
            SSL_HOST="${server_ip}"
        fi

        echo -e "${green}✓ Rutas de certificados personalizados aplicadas.${plain}"
        echo -e "${yellow}Nota: Usted es responsable de renovar estos archivos externamente.${plain}"

        systemctl restart x-ui >/dev/null 2>&1 || rc-service x-ui restart >/dev/null 2>&1
        ;;
    *)
        echo -e "${red}Opción inválida. Omitiendo la configuración SSL.${plain}"
        SSL_HOST="${server_ip}"
        ;;
    esac
}

config_after_install() {
    local existing_hasDefaultCredential=$(${xui_folder}/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # Properly detect empty cert by checking if cert: line exists and has content after it
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2>/dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]')
        if [[ "${http_code}" == "200" && -n "${ip_result}" ]]; then
            server_ip="${ip_result}"
            break
        fi
    done
    
    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath=$(gen_random_string 18)
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)
            
            read -rp "¿Desea personalizar la configuración del puerto del panel? (Si no, se aplicará uno aleatorio) [y/n]: " config_confirm
            if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                read -rp "Por favor, configure el puerto del panel: " config_port
                echo -e "${yellow}Su puerto del panel es: ${config_port}${plain}"
            else
                local config_port=$(shuf -i 1024-62000 -n 1)
                echo -e "${yellow}Se generó un puerto aleatorio: ${config_port}${plain}"
            fi
            
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"
            
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     Configuración de Certificado SSL (OBLIGATORIO)     ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}Por seguridad, se requiere un certificado SSL para todos los paneles.${plain}"
            echo -e "${yellow}¡Let's Encrypt ahora soporta tanto dominios como direcciones IP!${plain}"
            echo ""

            prompt_and_setup_ssl "${config_port}" "${config_webBasePath}" "${server_ip}"
            
            # Display final credentials and access information
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     ¡Instalación de KRAKER X-UI Completa!  ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}Usuario:      ${config_username}${plain}"
            echo -e "${green}Contraseña:   ${config_password}${plain}"
            echo -e "${green}Puerto:       ${config_port}${plain}"
            echo -e "${green}Ruta Web:     ${config_webBasePath}${plain}"
            echo -e "${green}URL Acceso:   https://${SSL_HOST}:${config_port}/${config_webBasePath}${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}⚠ IMPORTANTE: ¡Guarde estos datos de forma segura!${plain}"
            echo -e "${yellow}⚠ Certificado SSL: Habilitado y configurado${plain}"
        else
            local config_webBasePath=$(gen_random_string 18)
            echo -e "${yellow}Falta el WebBasePath o es muy corto. Generando uno nuevo...${plain}"
            ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}Nuevo WebBasePath: ${config_webBasePath}${plain}"

            # If the panel is already installed but no certificate is configured, prompt for SSL now
            if [[ -z "${existing_cert}" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}     Configuración de Certificado SSL (RECOMENDADO)   ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}¡Let's Encrypt ahora soporta tanto dominios como direcciones IP!${plain}"
                echo ""
                prompt_and_setup_ssl "${existing_port}" "${config_webBasePath}" "${server_ip}"
                echo -e "${green}URL de Acceso:  https://${SSL_HOST}:${existing_port}/${config_webBasePath}${plain}"
            else
                # If a cert already exists, just show the access URL
                echo -e "${green}URL de Acceso: https://${server_ip}:${existing_port}/${config_webBasePath}${plain}"
            fi
        fi
    else
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)
            
            echo -e "${yellow}Credenciales por defecto detectadas. Se requiere actualización de seguridad...${plain}"
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}"
            echo -e "Nuevas credenciales de acceso generadas aleatoriamente:"
            echo -e "###############################################"
            echo -e "${green}Usuario: ${config_username}${plain}"
            echo -e "${green}Contraseña: ${config_password}${plain}"
            echo -e "###############################################"
        else
            echo -e "${green}El Usuario, la Contraseña y el WebBasePath están correctamente configurados.${plain}"
        fi

        # Existing install: if no cert configured, prompt user for SSL setup
        # Properly detect empty cert by checking if cert: line exists and has content after it
        existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        if [[ -z "$existing_cert" ]]; then
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     Configuración de Certificado SSL (RECOMENDADO)   ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}¡Let's Encrypt ahora soporta tanto dominios como direcciones IP!${plain}"
            echo ""
            prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"
            echo -e "${green}URL de Acceso:  https://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        else
            echo -e "${green}El certificado SSL ya está configurado. No se requiere acción.${plain}"
        fi
    fi
    
    ${xui_folder}/x-ui migrate
}

install_x-ui() {
    cd ${xui_folder%/x-ui}/
    
    # Download resources
    if [ $# == 0 ]; then
        tag_version=$(curl -Ls "https://api.github.com/repos/underkraker/kraker-iu/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}Intentando obtener la versión con IPv4...${plain}"
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/underkraker/kraker-iu/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ ! -n "$tag_version" ]]; then
                echo -e "${red}Error al obtener la versión del panel, puede deberse a restricciones de la API de GitHub. Por favor, inténtelo de nuevo más tarde.${plain}"
                exit 1
            fi
        fi
        echo -e "Versión más reciente de KRAKER X-UI: ${tag_version}, iniciando la instalación..."
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/underkraker/kraker-iu/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading x-ui failed, please be sure that your server can access GitHub ${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="2.3.5"
        
        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}Please use a newer version (at least v2.3.5). Exiting installation.${plain}"
            exit 1
        fi
        
        url="https://github.com/underkraker/kraker-iu/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "Iniciando la instalación de KRAKER X-UI $1"
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Fallo al descargar KRAKER X-UI $1, por favor verifique si la versión existe ${plain}"
            exit 1
        fi
    fi
    curl -4fLRo /usr/bin/x-ui-temp https://raw.githubusercontent.com/underkraker/kraker-iu/main/x-ui.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Fallo al descargar x-ui.sh${plain}"
        exit 1
    fi
    
    # Stop x-ui service and remove old resources
    if [[ -e ${xui_folder}/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        rm ${xui_folder}/ -rf
    fi
    
    # Extract resources and set permissions
    tar zxvf x-ui-linux-$(arch).tar.gz
    rm x-ui-linux-$(arch).tar.gz -f
    
    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh
    
    # Check the system's architecture and rename the file accordingly
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-$(arch)
    
    # Update x-ui cli and se set permission
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
    mkdir -p /var/log/x-ui
    config_after_install

    # Etckeeper compatibility
    if [ -d "/etc/.git" ]; then
        if [ -f "/etc/.gitignore" ]; then
            if ! grep -q "x-ui/x-ui.db" "/etc/.gitignore"; then
                echo "" >> "/etc/.gitignore"
                echo "x-ui/x-ui.db" >> "/etc/.gitignore"
                echo -e "${green}Added x-ui.db to /etc/.gitignore for etckeeper${plain}"
            fi
        else
            echo "x-ui/x-ui.db" > "/etc/.gitignore"
            echo -e "${green}Created /etc/.gitignore and added x-ui.db for etckeeper${plain}"
        fi
    fi
    
    if [[ $release == "alpine" ]]; then
        curl -4fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/underkraker/kraker-iu/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Fallo al descargar x-ui.rc${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        # Install systemd service file
        service_installed=false
        
        if [ -f "x-ui.service" ]; then
            echo -e "${green}Found x-ui.service in extracted files, installing...${plain}"
            cp -f x-ui.service ${xui_service}/ >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                service_installed=true
            fi
        fi
        
        if [ "$service_installed" = false ]; then
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}Found x-ui.service.debian in extracted files, installing...${plain}"
                        cp -f x-ui.service.debian ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}Found x-ui.service.arch in extracted files, installing...${plain}"
                        cp -f x-ui.service.arch ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}Found x-ui.service.rhel in extracted files, installing...${plain}"
                        cp -f x-ui.service.rhel ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
            esac
        fi
        
        # If service file not found in tar.gz, download from GitHub
        if [ "$service_installed" = false ]; then
            echo -e "${yellow}Service files not found in tar.gz, downloading from GitHub...${plain}"
            case "${release}" in
                ubuntu | debian | armbian)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/underkraker/kraker-iu/main/x-ui.service.debian >/dev/null 2>&1
                ;;
                arch | manjaro | parch)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/underkraker/kraker-iu/main/x-ui.service.arch >/dev/null 2>&1
                ;;
                *)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/underkraker/kraker-iu/main/x-ui.service.rhel >/dev/null 2>&1
                ;;
            esac
            
            if [[ $? -ne 0 ]]; then
                echo -e "${red}Fallo al instalar x-ui.service desde GitHub${plain}"
                exit 1
            fi
            service_installed=true
        fi
        
        if [ "$service_installed" = true ]; then
            echo -e "${green}Setting up systemd unit...${plain}"
            chown root:root ${xui_service}/x-ui.service >/dev/null 2>&1
            chmod 644 ${xui_service}/x-ui.service >/dev/null 2>&1
            systemctl daemon-reload
            systemctl enable x-ui
            systemctl start x-ui
        else
            echo -e "${red}Failed to install x-ui.service file${plain}"
            exit 1
        fi
    fi
    
    echo -e "${green}Instalación de KRAKER X-UI ${tag_version}${plain} finalizada, ya se encuentra en ejecución..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}Uso del menú de control (subcomandos):${plain}               │
│                                                       │
│  ${blue}x-ui${plain}              - Script de Administración          │
│  ${blue}x-ui start${plain}        - Iniciar                          │
│  ${blue}x-ui stop${plain}         - Detener                          │
│  ${blue}x-ui restart${plain}      - Reiniciar                        │
│  ${blue}x-ui status${plain}       - Estado Actual                    │
│  ${blue}x-ui settings${plain}     - Configuración Actual             │
│  ${blue}x-ui enable${plain}       - Habilitar Inicio Automático      │
│  ${blue}x-ui disable${plain}      - Deshabilitar Inicio Automático   │
│  ${blue}x-ui log${plain}          - Ver Logs                         │
│  ${blue}x-ui banlog${plain}       - Ver Logs de Bloqueos (Fail2ban)  │
│  ${blue}x-ui update${plain}       - Actualizar                       │
│  ${blue}x-ui legacy${plain}       - Versión Antigua                  │
│  ${blue}x-ui install${plain}      - Instalar                         │
│  ${blue}x-ui uninstall${plain}    - Desinstalar                      │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}Running...${plain}"
install_base
install_x-ui $1
