#!/bin/bash

# Ask the user for the current date and time
read -p "Enter the current date and time(24 hours) (YYYY-MM-DD HH:MM): " user_datetime

# Set the system date and time
sudo date --set="$user_datetime"

# Update the system
sudo apt update && sudo apt upgrade -y

# install figlet and lolcat
sudo apt-get install figlet -y
sudo apt-get install lolcat -y

# install 3d.tlf figlet font
wget https://raw.githubusercontent.com/xero/figlet-fonts/master/3d.flf
sudo mv 3d.flf /usr/share/figlet/

# install python3 and pip3
pip3 install -r requirements.txt
pip install -r requirements.txt
pip3 install user-agents
pip3 install tqdm

# install zerotier-cli
curl -s https://install.zerotier.com | sudo bash

# install aws-cli
sudo apt install awscli -y

# configure aws-cli
if [ -f ~/.aws/config ]; then
    echo "AWS CLI already configured."
    echo "Continuing with installation..."
    sleep 1
else
    echo "AWS CLI not configured."
    echo "Do you want to configure it? (y/n)"
    read -p "" user_input
    if [ "$user_input" = "y" ]; then
    echo ""
    echo "Running AWS CLI configuration..."
    sleep 1
    aws configure
    fi
fi

# Create the 'bin' directory
mkdir -p ~/bin

# Create a symbolic link to your script
ln -s ~/rachel-auto/main.sh ~/bin/rachel-auto

# Add the 'bin' directory to PATH in ~/.bashrc
echo 'export PATH=$PATH:~/bin' >> ~/.bashrc

# Source the updated profile
source ~/.bashrc


# make the scripts executable
sudo chmod +x *.sh
sudo chmod +x scripts/vpn/*.sh
sudo chmod +x scripts/update/*.sh
sudo chmod +x scripts/system/*.sh
sudo chmod +x scripts/data/*.sh
sudo chmod +x scripts/data/all/*.sh
sudo chmod +x scripts/data/all/process/*.sh
sudo chmod +x scripts/data/collection/*.sh
sudo chmod +x scripts/data/process/*.sh
sudo chmod +x scripts/data/process/all/*.sh
sudo chmod +x scripts/data/upload/*.sh


exec ./main.sh
