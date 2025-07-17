#!/usr/bin/env bash

# A script to run 'ncdu /' (Disk usage analysis from root directory).

# 1) Check if ncdu is installed
if ! command -v ncdu &> /dev/null; then
  echo "Error: 'ncdu' command not found. Please install ncdu first."
  exit 1
fi

# 2) Run ncdu from the root directory
echo "Running ncdu on / ..."
ncdu /
echo "returning to main menu..."
sleep 2
exec ./scripts/troubleshoot/main.sh
