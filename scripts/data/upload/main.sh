#!/bin/bash

clear

echo ""
echo ""

figlet -c -t -f 3d "UPLOAD" | lolcat

echo ""
echo "=============================================================="
echo "Upload processed logs or Kolibri summaries to AWS S3"
echo "=============================================================="
echo ""

RED='\033[0;31m'
NC='\033[0m'
DARK_GRAY='\033[1;30m'
GREEN='\033[0;32m'

echo -e "1. Upload Processed Logs   ${DARK_GRAY}-| Upload processed RACHEL CSV files${NC}"
echo -e "2. Upload Kolibri Summary ${DARK_GRAY}-| Export and upload the Kolibri summary CSV${NC}"
echo -e "3. Configure AWS CLI      ${DARK_GRAY}-| Configure AWS CLI${NC}"
echo -e "4. Change s3 Bucket       ${DARK_GRAY}-| Change s3 Bucket URI${NC}"
echo -e "${GREEN}5. Go Back                ${DARK_GRAY}-| Go back to the data menu${NC}"
echo -e "${RED}6. Exit                   ${DARK_GRAY}-| Exit the program${NC}"

echo -e "${NC}"
read -p "Choose an option (1-6): " choice

case $choice in
  1)
    ./scripts/data/upload/upload.sh
    ;;
  2)
    ./scripts/data/upload/kolibri.sh
    ;;
  3)
    ./scripts/data/upload/configure.sh
    ;;
  4)
    ./scripts/data/upload/s3_bucket.sh
    ;;
  5)
    ./scripts/data/main.sh
    ;;
  6)
    ./exit.sh
    ;;
  *)
    echo -e "${RED}Invalid choice. Please choose a number between 1 and 6."
    echo -e "${NC}"
    sleep 1.5
    exec ./scripts/data/upload/main.sh
    ;;
esac
