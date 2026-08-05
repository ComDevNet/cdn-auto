#!/bin/bash

# Run the monitoring script
sudo -u pi /usr/local/bin/update_network_ips.sh

sleep 2

exec ./scripts/system/networking.sh