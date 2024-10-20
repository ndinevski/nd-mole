#!/bin/bash

GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RED="\033[31m"
BOLD="\033[1m"
RESET="\033[0m"

KEY_PAIR_NAME="nd-mole-keypair-$(date +%Y%m%d%H%M%S)"
SECURITY_GROUP_NAME="nd-mole-sg-$(date +%Y%m%d%H%M%S)"
LOCAL_PORT=$1

if [ -z "$1" ]; then
  echo -e "${RED}Error: No port provided. Usage: ./nd-mole <LOCAL_PORT>${RESET}"
  exit 1
fi

echo -e "${CYAN}${BOLD}Creating key pair...${RESET}"
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME --query 'KeyMaterial' --output text > ${KEY_PAIR_NAME}.pem
chmod 400 ${KEY_PAIR_NAME}.pem
echo -e "${GREEN}Key pair created and saved as ${KEY_PAIR_NAME}.pem${RESET}"

echo -e "${CYAN}${BOLD}Creating security group...${RESET}"
VPC_ID=$(aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text)
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name $SECURITY_GROUP_NAME \
    --description "Security group for SSH and HTTP access" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text --no-cli-pager)

echo -e "${GREEN}Security group created: ${SECURITY_GROUP_ID}${RESET}"

echo -e "${CYAN}Adding rules to the security group...${RESET}"
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 --no-cli-pager
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 --no-cli-pager
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
    --protocol tcp --port 8080 --cidr 0.0.0.0/0 --no-cli-pager
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
    --protocol tcp --port 443 --cidr 0.0.0.0/0 --no-cli-pager

echo -e "${GREEN}Security group rules added for SSH and HTTP access.${RESET}"

echo -e "${CYAN}${BOLD}Launching EC2 instance...${RESET}"
LATEST_AMI_ID=$(aws ec2 describe-images \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query "Images | sort_by(@, &CreationDate)[-1].ImageId" \
  --output text)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $LATEST_AMI_ID \
  --instance-type t2.micro \
  --key-name $KEY_PAIR_NAME \
  --security-group-ids $SECURITY_GROUP_ID \
  --user-data "#!/bin/bash
                sudo apt-get update
                sudo apt-get install -y apache2
                sudo a2enmod proxy
                sudo a2enmod proxy_http
                sudo bash -c 'cat > /etc/apache2/sites-available/000-default.conf <<EOF
<VirtualHost *:80>
    DocumentRoot /var/www/html

    ProxyPreserveHost On

    ProxyPass / http://localhost:8080/
    ProxyPassReverse / http://localhost:8080/

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF'

                sudo systemctl restart apache2" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo -e "${YELLOW}Waiting for instance to enter 'running' state...${RESET}"
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo -e "${GREEN}${BOLD}Instance is running!${RESET}"

echo -e "${CYAN}Creating proxy for localhost:${LOCAL_PORT}...${RESET}"

sleep 15

echo -e "${MAGENTA}Your public IP address is: http://$PUBLIC_IP${RESET}"
echo -e "${YELLOW}${BOLD}You can turn off this proxy by exiting the EC2 Machine.${RESET}"

sleep 1

ssh -o StrictHostKeyChecking=no -R localhost:8080:localhost:$LOCAL_PORT ubuntu@$PUBLIC_IP -t -i ${KEY_PAIR_NAME}.pem

echo -e "${RED}${BOLD}Cleaning up resources...${RESET}"
aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME --no-cli-pager
rm -f ${KEY_PAIR_NAME}.pem
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --no-cli-pager
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --no-cli-pager
echo -e "${GREEN}Cleanup complete.${RESET}"
