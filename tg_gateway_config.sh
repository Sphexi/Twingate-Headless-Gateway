#!/bin/bash

# This bash script will configure the underlying Ubuntu operating system to
# run as a Twingate Internet gateway for the local network.
# This script is intended to be run on a fresh Ubuntu 22.04 LTS installation, 
# but should work on earlier still supported versions.

# It will install and/or configure the following services:
# - bind9 (DNS server)
# - twingate client in headless mode
# - iptables (nat forwarding)

# This script should be run as root or with sudo.

# You will need to create a Twingate Service Account to use for this first, and have the
# configuration file available on the local filesystem.

# You will need to provide the location of the JSON configuration file for the Twingate client
# as the first argument to this script.

# You will also need to provide your local network's subnet as the second argument to this script.

# Example usage:
# sudo ./twingate-gateway.sh /path/to/twingate-service-key.json 10.0.0.0/24

# Help command to output usage and an example
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: sudo ./twingate-gateway.sh /path/to/twingate-service-key.json 10.0.0.0/24
    /path/to/twingate-service-key.json - The location of the Twingate service key file
    10.0.0.0/24 - The local network subnet
    "

# Check if the script is being run as root or with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo."
  exit 1
fi

# Check if the Twingate service key file is provided
if [ -z "$1" ]; then
  echo "Please provide the location of the Twingate service key file as the first argument."
  exit 1
fi

# Check if the Twingate service key file exists
if [ ! -f "$1" ]; then
  echo "The Twingate service key file does not exist."
  exit 1
fi

# Assign the Twingate service key file to a variable
TWINGATE_SERVICE_KEY_FILE="$1"

# Check if the local network subnet is provided
if [ -z "$2" ]; then
  echo "Please provide the local network subnet as the second argument in the format of x.x.x.x/xx."
  exit 1
fi

# Check if the local network subnet is valid
if ! echo "$2" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
  echo "The local network subnet is not valid."
  exit 1
fi

# Assign the local network subnet to a variable
LOCAL_NETWORK_SUBNET="$2"

# Assign the main network interface IP address to a variable
MAIN_NETWORK_INTERFACE_IP=$(ip -4 addr show $(ip route show default | awk '/default/ {print $5}') | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Section to identify which package manager is used
if [ -x "$(command -v apt-get)" ]; then
  PKG_MANAGER="apt-get"
elif [ -x "$(command -v yum)" ]; then
  PKG_MANAGER="yum"
else
  echo "No supported package manager found. Exiting."
  exit 1
fi

# Run package manager update
$PKG_MANAGER update

# Install bind9
$PKG_MANAGER install -y bind9

# Disable local DNS server
systemctl stop systemd-resolved
systemctl disable systemd-resolved

# Configure bind9
cat <<EOF > /etc/bind/named.conf.options
acl LAN {
$LOCAL_NETWORK_SUBNET;
};
options {
        directory "/var/cache/bind";
        allow-query { localhost; LAN; };
        recursion yes;
        forwarders {
                100.95.0.251;
                100.95.0.252;
                100.95.0.253;
                100.95.0.254;
        };
        dnssec-validation no;
        listen-on port 53 { 127.0.0.1;$MAIN_NETWORK_INTERFACE_IP; };
};
EOF

# Set bind9 to IPv4 only
sed -i 's/OPTIONS="-u bind"/OPTIONS="-u bind -4"/' /etc/default/named

# Restart bind9
systemctl restart bind9
systemctl restart named

# Install Twingate client
$PKG_MANAGER install -y curl
curl https://binaries.twingate.com/client/linux/install.sh | sudo bash
sudo twingate setup --headless $TWINGATE_SERVICE_KEY_FILE

# Enable IPv4 forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure iptables to NAT traffic from the local network out through the Twingate client
sudo iptables -t nat -A POSTROUTING -s 0.0.0.0/24 -o sdwan0 -j MASQUERADE

# Persist iptables rules for reboot
iptables-save > /etc/iptables/rules.v4