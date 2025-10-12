#!/bin/bash

# absolute path of the working directory
absolute_path=$(pwd)

theme_path="${absolute_path}/content/themes/spectre"

echo -e "\nDocker-Container stoppen..."
echo -e "============================"
cd $absolute_path
docker compose down

echo -e "\nTheme-Repository von GitHub pullen..."
echo -e "======================================"
cd $theme_path
echo -e $( git pull )

echo -e "\nDocker-Container starten..."
echo -e "============================"
cd $absolute_path
docker compose up -d

echo -e "\nFertig."