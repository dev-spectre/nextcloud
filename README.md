# Nextcloud

Universal Nextcloud installation and uninstallation scripts for Linux.

## Overview

Bash scripts to install and uninstall Nextcloud on any Linux distribution. Handles dependencies, web server configuration, and database setup automatically.

## Features

- **Universal installer** — works on Debian, Ubuntu, Fedora, Arch, and more
- **Automatic dependency** detection and installation
- **Web server** configuration (Apache/Nginx)
- **Database** setup (MySQL/MariaDB/SQLite)
- **Clean uninstaller** — removes all traces

## Usage

### Install

```bash
chmod +x nextcloud_install.sh
sudo ./nextcloud_install.sh
```

### Uninstall

```bash
chmod +x nextcloud_uninstall.sh
sudo ./nextcloud_uninstall.sh
```

## Project Structure

```
├── nextcloud_install.sh    # Installation script
└── nextcloud_uninstall.sh  # Uninstallation script
```

## License

MIT
