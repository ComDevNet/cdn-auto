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
echo -e "3. Upload ModuleGaze Logs ${DARK_GRAY}-| Upload processed ModuleGaze CSV files${NC}"
echo -e "4. Upload OC4D Assessments${DARK_GRAY}-| Pull OC4D assessment results and upload${NC}"
echo -e "5. Configure AWS CLI      ${DARK_GRAY}-| Configure AWS CLI${NC}"
echo -e "6. Change s3 Bucket       ${DARK_GRAY}-| Change s3 Bucket URI${NC}"
echo -e "${GREEN}7. Go Back                ${DARK_GRAY}-| Go back to the data menu${NC}"
echo -e "${RED}8. Exit                   ${DARK_GRAY}-| Exit the program${NC}"

echo -e "${NC}"
read -p "Choose an option (1-8): " choice

case $choice in
  1)
    ./scripts/data/upload/upload.sh
    ;;
  2)
    ./scripts/data/upload/kolibri.sh
    ;;
  3)
    ./scripts/data/upload/modulegaze.sh
    ;;
  4)
    ./scripts/data/upload/oc4d_assessments.sh
    ;;
  5)
    ./scripts/data/upload/configure.sh
    ;;
  6)
    ./scripts/data/upload/s3_bucket.sh
    ;;
  7)
    ./scripts/data/main.sh
    ;;
  8)
    ./exit.sh
    ;;
  *)
    echo -e "${RED}Invalid choice. Please choose a number between 1 and 8."
    echo -e "${NC}"
    sleep 1.5
    exec ./scripts/data/upload/main.sh
    ;;
esac
