# Direct.sh - VPS Configuration for Direct Configs

Automated VPS setup script that installs nginx, fetches a random HTML template from GitHub, and deploys it as a decoy website.

## Quick Install

```bash
bash <(curl -s https://raw.githubusercontent.com/Salarvand-Education/Direct/main/Direct.sh)
```

## What It Does

1. **Installs packages**: `jq`, `unzip`, `nginx`, `curl`
2. **Detects server info**: Public IP, country, ISP (with fallback)
3. **Downloads templates**: From GitHub repo (default: 150+ HTML5 templates)
4. **Picks random template**: Cleans up junk files, deploys to `/var/www/html`
5. **Configures nginx**: Tests config, enables service, sets proper permissions

## Configuration (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `TEMPLATE_REPO` | `Salarvand-Education/website-templates` | GitHub repo with templates |
| `TEMPLATE_BRANCH` | `master` | Branch to use |
| `WEB_ROOT` | `/var/www/html` | Nginx web root |
| `WORK_DIR` | `/root` | Temporary work directory |
| `SKIP_PACKAGES` | `false` | Skip apt package installation |
| `SKIP_TEMPLATE` | `false` | Skip template deployment (nginx only) |
| `DRY_RUN` | `false` | Test run without making changes |
| `LOG_LEVEL` | `1` (INFO) | `0=DEBUG`, `1=INFO`, `2=WARN`, `3=ERROR` |

## Examples

```bash
# Use your own template repository
TEMPLATE_REPO="myorg/my-templates" bash <(curl -s ...)

# Only configure nginx, keep existing website
SKIP_TEMPLATE=true bash <(curl -s ...)

# Test run - shows what would happen without changes
DRY_RUN=true bash <(curl -s ...)

# Debug logging
LOG_LEVEL=0 bash <(curl -s ...)

# Combine options
TEMPLATE_REPO="me/myrepo" TEMPLATE_BRANCH="dev" SKIP_PACKAGES=true bash <(curl -s ...)
```

## Requirements

- **Root access** (run with sudo)
- **Debian/Ubuntu** based system
- **Internet access** for package installation and template download

## Template Repository Structure

The script expects a GitHub repo with template directories at the root level:

```
your-templates-repo/
├── template-one/
│   ├── index.html
│   ├── css/
│   └── js/
├── template-two/
│   ├── index.html
│   └── ...
└── template-three/
    └── ...
```

The script:
- Downloads the repo as ZIP
- Removes: `assets/`, `.gitattributes`, `README.md`, `_config.yml`, `*.md`, `LICENSE*`
- Picks one directory at random
- Copies contents to web root

## Logging

- Console: Colored output (DEBUG/INFO/WARN/ERROR)
- File: `/var/log/direct-setup.log` (always written, fallback to `/tmp/direct-setup.log`)

## Exit Codes

- `0` - Success
- `1` - Error (check logs)

## Help

```bash
bash <(curl -s https://raw.githubusercontent.com/Salarvand-Education/Direct/main/Direct.sh) --help
```
