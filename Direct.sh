#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
plain='\033[0m'
NC='\033[0m'

install_jq() {
    if ! command -v jq &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            echo -e "${RED}jq is not installed. Installing...${NC}"
            sudo apt-get update -y
            sudo apt-get install -y jq
        else
            echo -e "${RED}Error: Unsupported package manager. Please install jq manually.${NC}"
            exit 1
        fi
    fi
}

loader(){
    install_jq
    SERVER_IP=$(hostname -I | awk '{print $1}')
    SERVER_COUNTRY=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.country')
    SERVER_ISP=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.isp')
}

setupFakeWebSite(){
    sudo apt-get update -y
    sudo apt-get install unzip -y

    if ! command -v nginx &> /dev/null; then
        echo "The Nginx software is not installed; the installation process has started."
        if sudo apt-get install -y nginx; then
            echo "Nginx was successfully installed."
        else
            echo "An error occurred during the Nginx installation process." >&2
            exit 1
        fi
    else
        echo "The Nginx software was already installed."
    fi

    cd /root || { echo "Failed to change directory to /root"; exit 1; }

    if [[ -d "website-templates-master" ]]; then
        echo "Removing existing 'website-templates-master' directory..."
        rm -rf website-templates-master
    fi

    wget https://github.com/learning-zone/website-templates/archive/refs/heads/master.zip
    unzip master.zip
    rm master.zip
    cd website-templates-master || { echo "Failed to change directory to randomfakehtml-master"; exit 1; }
    rm -rf assets
    rm ".gitattributes" "README.md" "_config.yml"

    randomTemplate=$(a=(*); echo ${a[$((RANDOM % ${#a[@]}))]} 2>&1)
    if [[ -n "$randomTemplate" ]]; then
        echo "Random template name: ${randomTemplate}"
    else
        echo "No directories found to choose from."
        exit 1
    fi

    if [[ -d "${randomTemplate}" && -d "/var/www/html/" ]]; then
        sudo rm -rf /var/www/html/*
        sudo cp -a "${randomTemplate}/." /var/www/html/
        echo "Template extracted successfully!"
    else
        echo "Extraction error!"
    fi
}

loader
setupFakeWebSite
