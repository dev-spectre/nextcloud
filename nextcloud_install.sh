#!/bin/bash

# =================================================================
# Universal Nextcloud Installer for Linux
# Author: Gemini
# Description: This script automates the installation and
#              configuration of Nextcloud on popular Linux distros,
#              with automatic HTTPS setup via Cloudflare or DuckDNS.
# =================================================================

# --- Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Function to print messages ---
info() {
    printf "${GREEN}[INFO] %s${NC}\n" "$1"
}

warn() {
    printf "${YELLOW}[WARN] %s${NC}\n" "$1"
}

error() {
    printf "${RED}[ERROR] %s${NC}\n" "$1"
    exit 1
}

# --- Distro Detection & Configuration ---
detect_distro() {
    info "Detecting your Linux distribution..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID_LIKE=${ID_LIKE:-$ID}
        if [[ "$ID_LIKE" == *"debian"* || "$ID_LIKE" == *"ubuntu"* ]]; then
            DISTRO="debian"
            PKG_MANAGER="apt"
            WEB_SERVER_SERVICE="apache2"
            WEB_SERVER_USER="www-data"
            APACHE_CONF_DIR="/etc/apache2/sites-available"
            APACHE_ENABLE_CMD="a2ensite"
            APACHE_DISABLE_CMD="a2dissite"
            APACHE_TEST_CMD="apache2ctl configtest"
            LOG_DIR="\${APACHE_LOG_DIR}"
        elif [[ "$ID_LIKE" == *"fedora"* || "$ID_LIKE" == *"rhel"* || "$ID_LIKE" == *"centos"* ]]; then
            DISTRO="rhel"
            PKG_MANAGER="dnf"
            if ! command -v dnf &> /dev/null; then PKG_MANAGER="yum"; fi
            WEB_SERVER_SERVICE="httpd"
            WEB_SERVER_USER="apache"
            APACHE_CONF_DIR="/etc/httpd/conf.d"
            APACHE_ENABLE_CMD="true" # No-op, file in conf.d is auto-enabled
            APACHE_DISABLE_CMD="rm -f" # To disable, we remove the conf file
            APACHE_TEST_CMD="httpd -t"
            LOG_DIR="/var/log/httpd"
        fi
    fi

    if [ -z "$DISTRO" ]; then
        error "Unsupported Linux distribution. This script supports Debian/Ubuntu and Fedora/RHEL based systems."
    fi
    info "Distribution detected: ${ID}. Using '${PKG_MANAGER}' as the package manager."
}

# --- Function to install dependencies ---
install_dependencies() {
    info "Installing all necessary dependencies for your system..."
    case "$PKG_MANAGER" in
        apt)
            apt update && apt upgrade -y
            apt install apache2 mariadb-server mariadb-client php libapache2-mod-php php-mysql php-xml php-mbstring php-zip php-curl php-gd php-intl php-bcmath php-gmp php-imagick bzip2 curl wget gnupg cron -y
            ;;
        dnf|yum)
            $PKG_MANAGER install httpd mariadb-server mariadb php php-mysqlnd php-xml php-mbstring php-zip php-curl php-gd php-intl php-bcmath php-gmp php-pecl-imagick bzip2 curl wget gnupg cronie -y
            ;;
    esac
    systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1
    systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1
}

# --- Function to restart Apache with syntax check ---
restart_apache() {
    info "Testing Apache configuration..."
    APACHE_CONFIG_TEST_OUTPUT=$($APACHE_TEST_CMD 2>&1)
    
    if ! echo "$APACHE_CONFIG_TEST_OUTPUT" | grep -q "Syntax OK"; then
        error "Apache configuration test failed:\n$APACHE_CONFIG_TEST_OUTPUT"
    fi
    info "Apache configuration syntax is OK."

    info "Restarting Apache..."
    systemctl restart $WEB_SERVER_SERVICE
    if ! systemctl is-active --quiet $WEB_SERVER_SERVICE; then
        error "Failed to restart Apache. Please check the logs using 'journalctl -xeu ${WEB_SERVER_SERVICE}'"
    fi
}

# --- Function to clean up remote access configurations ---
cleanup_remote_access() {
    info "Cleaning up previous remote access configurations..."
    (crontab -l 2>/dev/null | grep -v "/usr/local/bin/cloudflared tunnel") | crontab -
    pkill -f cloudflared
    rm -rf /etc/cloudflared /usr/local/bin/cloudflared

    if crontab -l 2>/dev/null | grep -q "/opt/duckdns/duck.sh"; then
        (crontab -l | grep -v "/opt/duckdns/duck.sh") | crontab -
        rm -rf /opt/duckdns
    fi

    if [ -f "${APACHE_CONF_DIR}/nextcloud-le-ssl.conf" ]; then
        info "Disabling existing Let's Encrypt SSL configuration..."
        $APACHE_DISABLE_CMD nextcloud-le-ssl.conf >/dev/null 2>&1
    fi

    info "Resetting Apache configuration for local access..."
    cat > "${APACHE_CONF_DIR}/nextcloud.conf" <<EOF
<VirtualHost *:80>
    ServerName localhost
    ServerAlias ${SERVER_IP}
    DocumentRoot ${DEFAULT_INSTALL_LOCATION}nextcloud/
    <Directory ${DEFAULT_INSTALL_LOCATION}nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>
    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
    </IfModule>
    ErrorLog ${LOG_DIR}/error.log
    CustomLog ${LOG_DIR}/access.log combined
</VirtualHost>
EOF
    $APACHE_ENABLE_CMD nextcloud.conf >/dev/null 2>&1
    restart_apache
    info "Cleanup complete."
}

# --- Function to set up remote access ---
setup_remote_access() {
    SETUP_MODE=$1 # Can be "interactive" or "headless"
    INSTALL_LOCATION=${2:-$DEFAULT_INSTALL_LOCATION}
    info "Now, let's make your Nextcloud instance accessible from the internet."
    read -p "Choose your preferred method (cloudflare/duckdns) [Default: cloudflare]: " ACCESS_METHOD
    ACCESS_METHOD=${ACCESS_METHOD:-cloudflare}

    if [ "$ACCESS_METHOD" = "cloudflare" ]; then
        ARCH=$(uname -m)
        CLOUDFLARED_URL=""
        if [ "$ARCH" = "aarch64" ]; then CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64";
        elif [ "$ARCH" = "armv7l" ]; then CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm";
        elif [ "$ARCH" = "x86_64" ]; then CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64";
        else error "Unsupported architecture: $ARCH. Cannot install cloudflared."; fi

        info "Setting up Cloudflare Tunnel for $ARCH..."
        curl -L "$CLOUDFLARED_URL" -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
        warn "You will now be asked to log in to your Cloudflare account in a browser."
        read -p "Press [Enter] to open the login URL..."
        cloudflared tunnel login
        read -p "Enter your full domain (e.g., nextcloud.yourdomain.com) [Optional, press Enter for a random URL]: " CUSTOM_DOMAIN_NAME
        TUNNEL_NAME="nextcloud-$(date +%s)"
        cloudflared tunnel create "$TUNNEL_NAME" >/dev/null 2>&1

        mkdir -p /etc/cloudflared/
        if [ -n "$CUSTOM_DOMAIN_NAME" ]; then
            DOMAIN_NAME="$CUSTOM_DOMAIN_NAME"
            cat > /etc/cloudflared/config.yml <<EOF
ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:80
  - service: http_status:404
EOF
        else
            TUNNEL_UUID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
            if [ -z "$TUNNEL_UUID" ]; then error "Failed to find created tunnel UUID."; fi
            DOMAIN_NAME="${TUNNEL_UUID}.cfargotunnel.com"
            info "No custom domain provided. Using persistent URL: https://${DOMAIN_NAME}"
            cat > /etc/cloudflared/config.yml <<EOF
ingress:
  - service: http://localhost:80
  - service: http_status:404
EOF
        fi

        info "Setting up cron job for auto-starting the tunnel on boot..."
        (crontab -l 2>/dev/null; echo "@reboot sleep 60 && /usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run ${TUNNEL_NAME} >/dev/null 2>&1") | crontab -
        info "Cron job created. Starting tunnel in the background..."
        nohup /usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run "${TUNNEL_NAME}" >/dev/null 2>&1 &
        
        if [ -n "$CUSTOM_DOMAIN_NAME" ]; then
            warn "Waiting 10 seconds for the tunnel to initialize before routing domain..."
            sleep 10
            info "Routing your custom domain ${CUSTOM_DOMAIN_NAME} to the tunnel..."
            cloudflared tunnel route dns "${TUNNEL_NAME}" "${CUSTOM_DOMAIN_NAME}"
        fi
        
        sed -i "s/ServerName localhost/ServerName ${DOMAIN_NAME}/" "${APACHE_CONF_DIR}/nextcloud.conf"
        sed -i "/ServerAlias ${SERVER_IP}/d" "${APACHE_CONF_DIR}/nextcloud.conf"

    elif [ "$ACCESS_METHOD" = "duckdns" ]; then
        read -p "Enter your DuckDNS domain (e.g., yourdomain.duckdns.org): " DOMAIN_NAME
        read -p "Enter your DuckDNS token: " DUCKDNS_TOKEN
        read -p "Enter an email address for Let's Encrypt SSL certificate notifications: " LETSENCRYPT_EMAIL
        mkdir -p /opt/duckdns
        echo "#!/bin/bash" > /opt/duckdns/duck.sh
        echo "echo url=\"https://www.duckdns.org/update?domains=${DOMAIN_NAME}&token=${DUCKDNS_TOKEN}&ip=\" | curl -k -o /opt/duckdns/duck.log -K -" >> /opt/duckdns/duck.sh
        chmod +x /opt/duckdns/duck.sh && /opt/duckdns/duck.sh
        (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1") | crontab -
        info "DuckDNS cron job created."
        info "Installing Certbot..."
        case "$PKG_MANAGER" in apt) apt install certbot python3-certbot-apache -y;; *) $PKG_MANAGER install certbot python3-certbot-apache -y;; esac
        sed -i "s/ServerName localhost/ServerName ${DOMAIN_NAME}/" "${APACHE_CONF_DIR}/nextcloud.conf"
        sed -i "/ServerAlias ${SERVER_IP}/d" "${APACHE_CONF_DIR}/nextcloud.conf"
        restart_apache
        info "Requesting and installing Let's Encrypt certificate..."
        warn "This may fail if your domain is not yet pointing to this server's public IP or if port 80 is blocked."
        certbot --apache -n --agree-tos -d "$DOMAIN_NAME" -m "$LETSENCRYPT_EMAIL" --redirect
        info "Certbot setup complete."
    else
        error "Invalid selection. Exiting."
    fi

    if [ "$SETUP_MODE" = "interactive" ]; then
        info "Finalizing Nextcloud configuration..."
        sudo -u $WEB_SERVER_USER php "${INSTALL_LOCATION}nextcloud/occ" config:system:set trusted_domains 2 --value="$DOMAIN_NAME"
        sudo -u $WEB_SERVER_USER php "${INSTALL_LOCATION}nextcloud/occ" config:system:set overwrite.cli.url --value="https://${DOMAIN_NAME}"
        sudo -u $WEB_SERVER_USER php "${INSTALL_LOCATION}nextcloud/occ" config:system:set overwriteprotocol --value="https"
    fi
    restart_apache
}

# --- Main Script Logic ---
if [[ $EUID -ne 0 ]]; then error "This script must be run as root."; fi

detect_distro
SERVER_IP=$(hostname -I | awk '{print $1}')
DEFAULT_INSTALL_LOCATION="/var/www/"

info "Starting Nextcloud Installation Script for your Linux Server."
sleep 2

if [ -d "${DEFAULT_INSTALL_LOCATION}nextcloud" ]; then
    warn "A Nextcloud installation has been detected."
    printf "Please choose an option:\n"
    printf "  1) Reconfigure Remote Access (Cloudflare/DuckDNS)\n"
    printf "  2) Perform a Full Reinstall (DESTRUCTIVE)\n"
    printf "  3) Exit\n"
    read -p "Enter your choice [1-3]: " REINSTALL_CHOICE
    case $REINSTALL_CHOICE in
        1) cleanup_remote_access; setup_remote_access "interactive";;
        2)
            info "Proceeding with FULL reinstallation..."
            systemctl stop $WEB_SERVER_SERVICE
            $APACHE_DISABLE_CMD 000-default.conf nextcloud.conf nextcloud-le-ssl.conf >/dev/null 2>&1
            rm -rf "${DEFAULT_INSTALL_LOCATION}nextcloud" "${APACHE_CONF_DIR}/nextcloud.conf" "${APACHE_CONF_DIR}/nextcloud-le-ssl.conf"
            restart_apache
            info "Previous installation files removed."
            read -sp "Please enter the MariaDB root password to remove the database: " MARIADB_ROOT_PASS_REINSTALL; echo
            mysql -u root -p"${MARIADB_ROOT_PASS_REINSTALL}" -e "DROP DATABASE IF EXISTS nextcloud; DROP USER IF EXISTS 'nextclouduser'@'localhost'; FLUSH PRIVILEGES;"
            info "Previous database and user removed. Continuing with a fresh installation..."
            ;;
        3) info "Exiting script."; exit 0;;
        *) error "Invalid choice. Exiting.";;
    esac
    if [ "$REINSTALL_CHOICE" = "1" ]; then
        info "Remote access has been reconfigured successfully."
        exit 0
    fi
fi

info "Starting a fresh installation of Nextcloud..."
read -p "Enter installation location [Default: /var/www/]: " INSTALL_LOCATION; INSTALL_LOCATION=${INSTALL_LOCATION:-/var/www/}
read -p "Enter database name [Default: nextcloud]: " DB_NAME; DB_NAME=${DB_NAME:-nextcloud}
read -p "Enter database user [Default: nextclouduser]: " DB_USER; DB_USER=${DB_USER:-nextclouduser}
while true; do
    read -sp "Enter a strong password for the database user: " DB_PASS; echo
    read -sp "Confirm the password: " DB_PASS_CONFIRM; echo
    if [ "$DB_PASS" = "$DB_PASS_CONFIRM" ] && [ -n "$DB_PASS" ]; then break; else warn "Passwords do not match or are empty."; fi
done

install_dependencies
info "Ensuring services are running..."
systemctl enable $WEB_SERVER_SERVICE && systemctl start $WEB_SERVER_SERVICE
systemctl enable mariadb && systemctl start mariadb
warn "Next, you will be prompted to run 'mysql_secure_installation'."
read -p "Press [Enter] to continue..."
mysql_secure_installation
info "Preparing the database..."
read -sp "Please enter the MariaDB root password you just set: " MARIADB_ROOT_PASS; echo

while true; do
    DB_EXISTS=$(mysql -u root -p"${MARIADB_ROOT_PASS}" -se "SHOW DATABASES LIKE '${DB_NAME}'")
    if [ -n "$DB_EXISTS" ]; then
        warn "Database '${DB_NAME}' already exists."
        read -p "Do you want to [R]eplace it or [C]hoose a different name? (R/C): " DB_CHOICE
        if [[ "$DB_CHOICE" =~ ^[Rr]$ ]]; then
            mysql -u root -p"${MARIADB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS ${DB_NAME}; DROP USER IF EXISTS '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
            info "Database and user removed." && break
        elif [[ "$DB_CHOICE" =~ ^[Cc]$ ]]; then
            read -p "Enter a new database name: " DB_NAME; DB_USER="${DB_NAME}user"; info "New database user will be '${DB_USER}'."
        else warn "Invalid choice."; fi
    else break; fi
done

info "Creating the Nextcloud database and user..."
mysql -u root -p"${MARIADB_ROOT_PASS}" -e "CREATE DATABASE ${DB_NAME}; CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}'; GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
DB_EXISTS_CHECK=$(mysql -u root -p"${MARIADB_ROOT_PASS}" -se "SHOW DATABASES LIKE '${DB_NAME}'")
if [ -z "$DB_EXISTS_CHECK" ]; then error "Database creation failed."; fi
info "Database '${DB_NAME}' created successfully."

info "Downloading and installing Nextcloud..."
cd "$INSTALL_LOCATION" || error "Could not cd to ${INSTALL_LOCATION}"
wget https://download.nextcloud.com/server/releases/latest.tar.bz2 && tar -xvf latest.tar.bz2 && rm latest.tar.bz2
chown -R $WEB_SERVER_USER:$WEB_SERVER_USER "${INSTALL_LOCATION}nextcloud/" && chmod -R 755 "${INSTALL_LOCATION}nextcloud/"

info "Configuring Apache for Nextcloud..."
cat > "${APACHE_CONF_DIR}/nextcloud.conf" <<EOF
<VirtualHost *:80>
    ServerName localhost
    ServerAlias ${SERVER_IP}
    DocumentRoot ${INSTALL_LOCATION}nextcloud/
    <Directory ${INSTALL_LOCATION}nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>
    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
    </IfModule>
    ErrorLog ${LOG_DIR}/error.log
    CustomLog ${LOG_DIR}/access.log combined
</VirtualHost>
EOF
$APACHE_DISABLE_CMD 000-default.conf >/dev/null 2>&1
$APACHE_ENABLE_CMD nextcloud.conf
if [ "$DISTRO" = "debian" ]; then a2enmod rewrite headers env dir mime ssl; fi
restart_apache

info "Initial installation is complete!"
warn "To create your admin account, open a web browser and go to one of these URLs:"
printf "  - ${YELLOW}If on this server:${NC} http://localhost\n"
printf "  - ${YELLOW}From another computer on the same network:${NC} http://%s\n" "$SERVER_IP"
warn "Use the following database details:"
printf "  - User: ${YELLOW}%s${NC}\n" "$DB_USER"
printf "  - Password: ${YELLOW}%s${NC}\n" "$DB_PASS"
printf "  - Database: ${YELLOW}%s${NC}\n" "$DB_NAME"
printf "  - Host: ${YELLOW}localhost${NC}\n"

read -p "Do you want to complete the web-based setup now? (Answering 'n' will set up remote access and exit). (y/n): " COMPLETE_NOW
if [[ "$COMPLETE_NOW" =~ ^[Yy]$ ]]; then
    info "Waiting for you to complete the web-based installation..."
    while ! grep -q "'installed' => true," "${INSTALL_LOCATION}nextcloud/config/config.php" 2>/dev/null; do
        warn "Nextcloud installation is not yet complete. Please finish the setup in your web browser."
        read -p "Press [Enter] after completing the setup to check again..."
    done
    info "Nextcloud installation verified."
    info "Adding localhost and IP to trusted domains..."
    sudo -u $WEB_SERVER_USER php "${INSTALL_LOCATION}nextcloud/occ" config:system:set trusted_domains 0 --value="localhost"
    sudo -u $WEB_SERVER_USER php "${INSTALL_LOCATION}nextcloud/occ" config:system:set trusted_domains 1 --value="${SERVER_IP}"
    setup_remote_access "interactive" "$INSTALL_LOCATION"
else
    setup_remote_access "headless" "$INSTALL_LOCATION"
    warn "Remote access is configured. You can now complete the Nextcloud setup using your phone or another computer."
    warn "IMPORTANT: After setup, log in as admin, go to Settings -> Administration -> Security & setup warnings, and add your domain to the trusted domains list to remove any security warnings."
fi

info "Configuration complete!"
LOCAL_URL="http://${SERVER_IP}"
if [ "$ACCESS_METHOD" = "duckdns" ]; then
    warn "IMPORTANT STEPS FOR DUCKDNS USERS:"
    printf "  1. ${YELLOW}Set a Static IP Address:${NC} Your server's IP (%s) should be static.\n" "$SERVER_IP"
    printf "  2. ${YELLOW}Port Forwarding:${NC} Forward external ports 80 and 443 to your server's IP (%s).\n" "$SERVER_IP"
    LOCAL_URL="https://${SERVER_IP}"
fi
info "Your Nextcloud instance is now accessible via the following URLs:"
printf "  - ${GREEN}Public (from any network):${NC} https://%s\n" "$DOMAIN_NAME"
printf "  - ${GREEN}Local (from your network):${NC} %s\n" "$LOCAL_URL"

read -p "Would you like to reboot the system now? (y/n): " REBOOT_CHOICE
if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then info "Rebooting now..."; reboot; else info "Script finished."; fi

exit 0
