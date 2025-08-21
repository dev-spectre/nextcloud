#!/bin/bash

# =================================================================
# Universal Nextcloud Uninstaller
# Author: Gemini
# Description: This script completely removes Nextcloud, its
#              associated configurations, database, and remote
#              access tools from a Linux server.
# =================================================================

# --- Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Function to print messages ---
info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
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
            APACHE_CONF_DIR="/etc/apache2/sites-available"
            APACHE_DISABLE_CMD="a2dissite"
        elif [[ "$ID_LIKE" == *"fedora"* || "$ID_LIKE" == *"rhel"* || "$ID_LIKE" == *"centos"* ]]; then
            DISTRO="rhel"
            PKG_MANAGER="dnf"
            if ! command -v dnf &> /dev/null; then PKG_MANAGER="yum"; fi
            WEB_SERVER_SERVICE="httpd"
            APACHE_CONF_DIR="/etc/httpd/conf.d"
            APACHE_DISABLE_CMD="rm -f"
        fi
    fi

    if [ -z "$DISTRO" ]; then
        error "Unsupported Linux distribution. This script supports Debian/Ubuntu and Fedora/RHEL based systems."
    fi
    info "Distribution detected: ${ID}."
}

# --- Main Script Logic ---
if [[ $EUID -ne 0 ]]; then error "This script must be run as root."; fi

detect_distro

warn "This script will permanently remove Nextcloud and all its data."
warn "This action cannot be undone. Backups are strongly recommended."
read -p "Are you sure you want to continue? (y/n): " CONFIRMATION
if [[ ! "$CONFIRMATION" =~ ^[Yy]$ ]]; then
    info "Uninstallation cancelled."
    exit 0
fi

# 1. Stop Services
info "Stopping services..."
systemctl stop $WEB_SERVER_SERVICE
systemctl stop mariadb
pkill -f cloudflared

# 2. Clean Up Remote Access
info "Removing remote access configurations..."
(crontab -l 2>/dev/null | grep -v "/usr/local/bin/cloudflared tunnel") | crontab -
(crontab -l 2>/dev/null | grep -v "/opt/duckdns/duck.sh") | crontab -
rm -rf /etc/cloudflared /usr/local/bin/cloudflared /opt/duckdns
info "Remote access tools and cron jobs removed."

# 3. Remove Apache Configuration
info "Removing Apache/HTTPD configuration..."
$APACHE_DISABLE_CMD nextcloud.conf >/dev/null 2>&1
$APACHE_DISABLE_CMD nextcloud-le-ssl.conf >/dev/null 2>&1
rm -f "${APACHE_CONF_DIR}/nextcloud.conf" "${APACHE_CONF_DIR}/nextcloud-le-ssl.conf"
systemctl restart $WEB_SERVER_SERVICE
info "Web server configuration removed."

# 4. Remove Nextcloud Files & Data
read -p "Enter the Nextcloud installation location [Default: /var/www/]: " INSTALL_LOCATION
INSTALL_LOCATION=${INSTALL_LOCATION:-/var/www/}
NEXTCLOUD_DIR="${INSTALL_LOCATION}nextcloud"
CONFIG_FILE="${NEXTCLOUD_DIR}/config/config.php"

if [ -d "$NEXTCLOUD_DIR" ]; then
    # Find the data directory path BEFORE deleting the web root
    DATA_DIR=""
    if [ -f "$CONFIG_FILE" ]; then
        DATA_DIR=$(grep "'datadirectory'" "$CONFIG_FILE" | sed "s/.*' => '\([^']*\)',/\1/")
    fi

    info "Removing Nextcloud web directory: ${NEXTCLOUD_DIR}..."
    rm -rf "$NEXTCLOUD_DIR"
    info "Web directory removed."

    # Ask to remove the data directory
    if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ]; then
        warn "Found Nextcloud data directory at: ${DATA_DIR}"
        warn "This directory contains all user files. Deleting it is PERMANENT."
        read -p "Do you want to delete this data directory? (y/n): " DELETE_DATA
        if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
            info "Deleting data directory: ${DATA_DIR}..."
            rm -rf "$DATA_DIR"
            info "Data directory removed."
        else
            info "Skipping data directory removal."
        fi
    fi
else
    warn "Nextcloud directory not found at ${NEXTCLOUD_DIR}. Skipping file removal."
fi

# 5. Remove Database
read -p "Do you want to remove the Nextcloud database and user? (y/n): " DELETE_DB
if [[ "$DELETE_DB" =~ ^[Yy]$ ]]; then
    read -p "Enter the database name to remove [Default: nextcloud]: " DB_NAME
    DB_NAME=${DB_NAME:-nextcloud}
    read -p "Enter the database user to remove [Default: nextclouduser]: " DB_USER
    DB_USER=${DB_USER:-nextclouduser}
    read -sp "Enter your MariaDB root password: " MARIADB_ROOT_PASS
    echo

    info "Removing database '${DB_NAME}' and user '${DB_USER}'..."
    mysql -u root -p"${MARIADB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS ${DB_NAME}; DROP USER IF EXISTS '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
    info "Database and user removed."
else
    info "Skipping database removal."
fi

# 6. Remove Packages
warn "The script can now attempt to remove packages like Apache, MariaDB, and PHP."
warn "Only do this if you are NOT running other websites or databases on this server."
read -p "Do you want to remove the server packages (apache, mariadb, php, etc.)? (y/n): " REMOVE_PACKAGES
if [[ "$REMOVE_PACKAGES" =~ ^[Yy]$ ]]; then
    info "Removing server packages..."
    case "$PKG_MANAGER" in
        apt)
            apt purge --auto-remove apache2 mariadb-server php.* -y
            ;;
        dnf|yum)
            $PKG_MANAGER remove httpd mariadb-server php* -y
            $PKG_MANAGER autoremove -y
            ;;
    esac
    info "Packages removed."
else
    info "Skipping package removal."
fi

info "Nextcloud uninstallation is complete."
