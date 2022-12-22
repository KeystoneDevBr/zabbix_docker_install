#!/bin/bash
#################################################################################################
#  Author: Fagne Tolentino Reges
#  Create at: 21/12/2022    Last update: 21/12/2022
#
#  This script provides automatic installation of the following zabbix components via docker:
#  
#  zabbix-web-nginx-mysql; 
#  zabbix-agent; 
#  zabbix-snmptraps; 
#  zabbix-proxy-sqlite3; 
#  zabbix-server-mysql and 
#  zabbix-snmptraps 
################################################################################################

clear && echo "Start instalation.......................";

f_create_https_certificate(){
   # Create the directory for HTTPS keys.
   sudo mkdir -p /docker/zabbix/ssl
   
   # Creating the self-asignet certificate for https
   sudo apt-get -y install openssl
   
   echo 'Recomended password: 1234'; sleep 5;
   # Create a Private kay
   sudo openssl genrsa -aes256 -out /docker/zabbix/ssl/ssl.key  4096
   
   # private key password <1234>
   sudo cp /docker/zabbix/ssl/ssl.key /docker/zabbix/ssl/ssl.key.org
   
   # Createa a request signature
   sudo openssl rsa -in /docker/zabbix/ssl/ssl.key.org -out /docker/zabbix/ssl/ssl.key
   
   sudo chmod 755 /docker/zabbix/ssl/ssl.key
   
   sudo rm /docker/zabbix/ssl/ssl.key.org
   
   sudo openssl req -new -sha256 -days 365000 -key /docker/zabbix/ssl/ssl.key -out /docker/zabbix/ssl/ssl.csr

   # Make a signature of certificate
   sudo openssl x509 -req -days 3650 -sha256 \
       -in /docker/zabbix/ssl/ssl.csr \
       -signkey /docker/zabbix/ssl/ssl.key \
       -out /docker/zabbix/ssl/ssl.crt
   
   # Create a Diffie-Hellman park keys
   sudo openssl dhparam -out /docker/zabbix/ssl/dhparam.pem 4096
}

# Cherck if the self-sgnature already exists
if [[ -f /docker/zabbix/ssl/ssl.key ]]; then
   echo "File /docker/zabbix/ssl/ssl.key alrady exists";
elif [[ -f /docker/zabbix/ssl/dhparam.pem ]]; then
   echo "file /docker/zabbix/ssl/dhparam.pem alrady exists";
elif [[ -f /docker/zabbix/ssl/ssl.csr ]]; then
   echo "file /docker/zabbix/ssl/ssl.csr alrady exists";
else    
   echo "Make signature again";
   f_create_https_certificate
fi

# Create a direcotry for store data form MySQL, Mibs e SNMP Traps.
sudo mkdir -p /docker/zabbix/mysql/data \
           /docker/zabbix/snmptraps \
           /docker/zabbix/mibs

# Get images from docker hub
ZABBIX_VERSION=ubuntu-6.2-latest

docker pull mysql:8s
docker pull zabbix/zabbix-agent:${ZABBIX_VERSION}
docker pull zabbix/zabbix-proxy-sqlite3:${ZABBIX_VERSION}
docker pull zabbix/zabbix-server-mysql:${ZABBIX_VERSION}
docker pull zabbix/zabbix-web-nginx-mysql:${ZABBIX_VERSION}
docker pull zabbix/zabbix-snmptraps:${ZABBIX_VERSION}

# Create a Virtual Subnet
ZABBIX_SUBNET="172.20.0.0/16"
ZABBIX_IP_RANGE="172.20.240.0/20"

docker network create --subnet ${ZABBIX_SUBNET} --ip-range ${ZABBIX_IP_RANGE} zabbix-net
docker network inspect zabbix-net

# initialize the mysql container
docker run -d --name zabbix-mysql \
           --restart always \
           -p 3306:3306 \
           -v /docker/zabbix/mysql/data:/var/lib/mysql \
           -e MYSQL_ROOT_PASSWORD=secret \
           -e MYSQL_DATABASE=zabbix \
           -e MYSQL_USER=zabbix \
           -e MYSQL_PASSWORD=zabbix \
           --network=zabbix-net \
           mysql:8 \
           --default-authentication-plugin=mysql_native_password \
           --character-set-server=utf8 \
           --collation-server=utf8_bin

#  initialize the SNMP container
docker run -d --name zabbix-snmptraps -t \
           --restart always \
           -p 162:1162/udp \
           -v /docker/zabbix/snmptraps:/var/lib/zabbix/snmptraps:rw \
           -v /docker/zabbix/mibs:/usr/share/snmp/mibs:ro \
           --network=zabbix-net \
           zabbix/zabbix-snmptraps:${ZABBIX_VERSION}

#  initialize the zabbix-server container
docker run -d --name zabbix-server \
           --restart always \
           -p 10051:10051 \
           -e DB_SERVER_HOST="zabbix-mysql" \
           -e DB_SERVER_PORT="3306" \
           -e MYSQL_ROOT_PASSWORD="secret" \
           -e MYSQL_DATABASE="zabbix" \
           -e MYSQL_USER="zabbix" \
           -e MYSQL_PASSWORD="zabbix" \
           -e ZBX_ENABLE_SNMP_TRAPS="true" \
           --network=zabbix-net \
           --volumes-from zabbix-snmptraps \
           zabbix/zabbix-server-mysql:${ZABBIX_VERSION}           

#  initialize the zabbix-web container
docker run -d --name zabbix-web \
           --restart always \
           -p 80:8080 -p 443:8443 \
           -v /docker/zabbix/ssl/ssl.crt:/etc/ssl/nginx/ssl.crt \
           -v /docker/zabbix/ssl/ssl.key:/etc/ssl/nginx/ssl.key \
           -v /docker/zabbix/ssl/dhparam.pem:/etc/ssl/nginx/dhparam.pem \
           -e ZBX_SERVER_HOST="zabbix-server" \
           -e DB_SERVER_HOST="zabbix-mysql" \
           -e DB_SERVER_PORT="3306" \
           -e MYSQL_ROOT_PASSWORD="secret" \
           -e MYSQL_DATABASE="zabbix" \
           -e MYSQL_USER="zabbix" \
           -e MYSQL_PASSWORD="zabbix" \
           -e PHP_TZ="America/Sao_Paulo" \
           --network=zabbix-net \
           zabbix/zabbix-web-nginx-mysql:${ZABBIX_VERSION}

#  initialize the zabbix-agent container
docker run -d --name zabbix-agent \
           --hostname "$(hostname)" \
           --privileged \
           -v /:/rootfs \
           -v /var/run:/var/run \
           --restart always \
           -p 10050:10050 \
           -e ZBX_HOSTNAME="$(hostname)" \
           -e ZBX_SERVER_HOST="172.17.0.1" \
           -e ZBX_PASSIVESERVERS="${ZABBIX_IP_RANGE}" \
           zabbix/zabbix-agent:${ZABBIX_VERSION}

# initialize the zabbit-proxy container           
docker run -d --name zabbix-proxy \
           --restart always \
           -p 10053:10050 \
           -e ZBX_HOSTNAME="$(hostname)" \
           -e ZBX_SERVER_HOST="zabbix-server" \
           -e ZBX_ENABLE_SNMP_TRAPS="true" \
           --network=zabbix-net \
           --volumes-from zabbix-snmptraps \
            zabbix/zabbix-proxy-sqlite3:${ZABBIX_VERSION}


echo ""; echo "";
echo "Instalation finished.....................................";

echo "Acesse: https://$(hostname -I | awk '{print $1}')/"

echo "User: Admin";
echo "Password: zabbix";

#sleep 15 && docker stats