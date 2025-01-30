#!/bin/bash

# Define color codes for better readability (used in terminal logs)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to display a message using echo
display_message() {
    local title="$1"
    local text="$2"
    echo -e "${GREEN}$title: $text${NC}"
}

# Function to install required packages if not present
install_packages() {
    PACKAGES=("jq" "unzip" "nginx")
    for PACKAGE in "${PACKAGES[@]}"; do
        if ! command -v $PACKAGE &> /dev/null; then
            display_message "Installing $PACKAGE" "$PACKAGE is not installed. Installing..."
            sudo apt-get update -y > /dev/null && sudo apt-get install -y $PACKAGE > /dev/null
            if [[ $? -ne 0 ]]; then
                display_message "Error" "Failed to install $PACKAGE. Please try manually."
                exit 1
            fi
        else
            display_message "Info" "$PACKAGE is already installed."
        fi
    done
}

# Function to load server information
loader() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if [[ -z "$SERVER_IP" ]]; then
        display_message "Error" "Could not determine server IP address."
        exit 1
    fi
    
    SERVER_COUNTRY=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.country')
    SERVER_ISP=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.isp')

    if [[ -z "$SERVER_COUNTRY" || -z "$SERVER_ISP" ]]; then
        display_message "Error" "Failed to fetch server location or ISP information."
        exit 1
    fi

    display_message "Server Info" "Server IP: ${SERVER_IP}\nCountry: ${SERVER_COUNTRY}\nISP: ${SERVER_ISP}"
}

# Function to setup a fake website using Nginx and random templates
setupFakeWebSite() {
    cd /root || { display_message "Error" "Failed to change directory to /root."; exit 1; }

    if [[ -d "website-templates-master" ]]; then
        display_message "Info" "Removing existing 'website-templates-master' directory..."
        rm -rf website-templates-master > /dev/null 2>&1
    fi

    display_message "Downloading Template" "Downloading template archive..."
    wget -q https://github.com/learning-zone/website-templates/archive/refs/heads/master.zip
    if [[ $? -ne 0 ]]; then
        display_message "Error" "Failed to download template archive."
        exit 1
    fi

    display_message "Extracting Template" "Extracting template archive..."
    unzip -q master.zip && rm master.zip > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        display_message "Error" "Failed to extract template archive."
        exit 1
    fi

    cd website-templates-master || { display_message "Error" "Failed to change directory to website-templates-master."; exit 1; }
    
    display_message "Cleaning Up" "Cleaning up unnecessary files..."
    rm -rf assets .gitattributes README.md _config.yml > /dev/null 2>&1

    # Select a random template
    templates=(*)
    if [[ ${#templates[@]} -eq 0 ]]; then
        display_message "Error" "No directories found to choose from."
        exit 1
    fi

    randomTemplate=${templates[$RANDOM % ${#templates[@]}]}
    display_message "Random Template" "Random template selected: ${randomTemplate}"

    if [[ -d "$randomTemplate" && -d "/var/www/html/" ]]; then
        display_message "Copying Template" "Copying template to web root..."
        sudo rm -rf /var/www/html/* > /dev/null 2>&1
        sudo cp -a "${randomTemplate}/." /var/www/html/ > /dev/null 2>&1
        display_message "Success" "Template extracted successfully!"
    else
        display_message "Error" "Extraction error!"
        exit 1
    fi
}

# Execute functions sequentially to ensure proper execution order
install_packages
loader
setupFakeWebSite

display_message "Completion" "All operations completed successfully!"
