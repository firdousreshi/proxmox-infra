#!/bin/bash

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server

# Start and enable MariaDB service
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Set MariaDB root password
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${local.db_password}'"

# Create a user and database
sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${local.db}"
sudo mysql -e "CREATE USER IF NOT EXISTS '${local.db_user}'@'localhost' IDENTIFIED BY '${local.db_password}'"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${local.db}.* TO '${local.db_user}'@'localhost'"
sudo mysql -e "FLUSH PRIVILEGES"
