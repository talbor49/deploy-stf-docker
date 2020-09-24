#!/usr/bin/env bash
#######################################################################################
# file:    deploy_stf.sh
# brief:   deploy components of stf with docker
# creator: thinkhy
# date:    2017-04-20
# usage:   ./deploy_stf.sh  Note: run it as ROOT user
# changes: 
#    1. 2017-04-20 init  @thinkhy
#    2. 2017-04-26 add systemd unit  @thinkhy
#    3. 2017-05-04 install adb on host machine @thinkhy
#    4. 2017-07-22 generate and customize nginx.conf
# 
#######################################################################################

display_usage() { 
	echo "This script must be run with super-user privileges." 
  echo -e "\nUsage: $0 [machine_ip_address] \n" 
} 
# Get exported IP Adreess 
# if less than two arguments supplied, display usage 
if [  $# -lt 1 ] 
then 
  display_usage
  exit 1
fi

# check whether user had supplied -h or --help . If yes display usage 
if [[ ( $# == "--help") ||  $# == "-h" ]] 
then 
  display_usage
  exit 0
fi 

# display usage if the script is not run as root user 
if [[ $USER != "root" ]]; then 
  echo "This script must be run as root!" 
  exit 1
fi 
 
NETNAME=""
NETWORK_INTERFACES=$(ls /sys/class/net)

DNS_ADDRESS=$(nmcli device show ${NETNAME}|grep "IP4\.DNS\[1\]"|awk '{print $2}')
echo "DNS Address: ${DNS_ADDRESS}"


IP_ADDRESS=$1
echo "IP ADDRESS: ${IP_ADDRESS}"

check_return_code() {
  if [ $? -ne 0 ]; then
    echo "Failed to run last step!"     
    return 1
  fi
   
  return 0
}

assert_run_ok() {
  if [ $? -ne 0 ]; then
    echo "Failed to run last step!"     
    exit 1
  fi
   
  return 0
}

prepare() {
  echo "setup environment ..."

  # Given advantages of performance and stability, we run adb server and rethinkdb 
  # on host(physical) machine rather than on docker containers, so need to
  #  install package of android-tools-adb first [ thinkhy 2017-05-04 ]

  # install adb
  apt-get install -y android-tools-adb

  apt-get install -y docker.io
  assert_run_ok

  docker pull devicefarmer/stf 
  assert_run_ok

  #docker pull sorccu/adb 
  #assert_run_ok

  docker pull rethinkdb 
  assert_run_ok

  docker pull devicefarmer/ambassador 
  assert_run_ok

  docker pull nginx
  assert_run_ok

  cp -rf adbd.service.template /etc/systemd/system/adbd.service  
  assert_run_ok

  sed -e "s/__IP_ADDRESS__/${IP_ADDRESS}/g"                     \
      -e "s/__DNS_ADDRESS__/${DNS_ADDRESS}/g"	                \
    nginx.conf.template |tee nginx.conf 
  echo 1>"env.ok"

}


if [ ! -e env.ok ]; then
  prepare
fi



# start local adb server
echo "start adb server"
systemctl start adbd 

# start rethinkdb
echo "start docker container: rethinkdb"
docker rm -f rethinkdb
docker run -d --name rethinkdb -v /srv/rethinkdb:/data --net host rethinkdb rethinkdb --bind all --cache-size 8192 --http-port 8090
check_return_code

# start nginx, note: generate nginx.conf first
echo "start docker container: nginx"
docker rm -f nginx
docker run -d -v $(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro --name nginx --net host nginx nginx
check_return_code

# create tables 
echo "start docker container: stf-migrate"
docker rm -f stf-migrate
docker run -d --name stf-migrate --net host devicefarmer/stf stf migrate
check_return_code

# create storage components 
echo "start docker container: storage-plugin-apk-3300"
docker rm -f storage-plugin-apk-3300
docker run -d --net host --name storage-plugin-apk-3300 --dns ${DNS_ADDRESS}  devicefarmer/stf stf storage-plugin-apk --port 3300 --storage-url http://${IP_ADDRESS}/
check_return_code

echo "start docker container: storage-plugin-image-3400"
docker rm -f storage-plugin-image-3400
docker run -d --net host --name storage-plugin-image-3400 --dns ${DNS_ADDRESS}  devicefarmer/stf stf storage-plugin-image  --port 3400 --storage-url http://${IP_ADDRESS}/
check_return_code  

echo "start docker container: storage-temp-3500"
docker rm -f storage-temp-3500
docker run -d --name storage-temp-3500 -v /mnt/storage:/data -p 3500:3000 --dns ${DNS_ADDRESS}  devicefarmer/stf stf storage-temp  --port 3000 --save-dir /home/stf
check_return_code

# tri-proxy
echo "start docker container: triproxy-app"
docker rm -f triproxy-app
docker run -d --name triproxy-app --net host devicefarmer/stf stf triproxy app --bind-pub "tcp://*:7150" --bind-dealer "tcp://*:7160" --bind-pull "tcp://*:7170"
check_return_code

echo "start docker container: triproxy-dev"
docker rm -f triproxy-dev
docker run -d --name triproxy-dev --net host devicefarmer/stf stf triproxy dev --bind-pub "tcp://*:7250" --bind-dealer "tcp://*:7260" --bind-pull "tcp://*:7270"
check_return_code

# auth
echo "start docker container: stf-auth-3200"
docker rm -f stf-auth-3200
docker run -d --name stf-auth-3200 --net host -e "SECRET=YOUR_SESSION_SECRET_HERE" --dns ${DNS_ADDRESS} devicefarmer/stf stf auth-mock --port 3200 --app-url http://${IP_ADDRESS}/
check_return_code

# api 
echo "start docker container: stf-api"
docker rm -f stf-api
docker run -d --name stf-api --net host -e "SECRET=YOUR_SESSION_SECRET_HERE"  devicefarmer/stf stf api --port 3700 --connect-push tcp://${IP_ADDRESS}:7150 --connect-sub tcp://${IP_ADDRESS}:7150  --connect-push-dev tcp://${IP_ADDRESS}:7170 --connect-sub-dev tcp://${IP_ADDRESS}:7170
check_return_code

# stf APP
echo "start docker container: stf-app-3100"
docker rm -f stf-app-3100
docker run -d --name stf-app-3100 --net host -e "SECRET=YOUR_SESSION_SECRET_HERE" -p 3100:3000 devicefarmer/stf stf app --port 3100 --auth-url http://${IP_ADDRESS}/auth/mock/ --websocket-url http://${IP_ADDRESS}/
check_return_code


# processor
echo "start docker container: stf-processor"
docker rm -f stf-processor
docker run -d --name stf-processor --net host devicefarmer/stf stf processor stf-processor.service --connect-app-dealer tcp://${IP_ADDRESS}:7160 --connect-dev-dealer tcp://${IP_ADDRESS}:7260
check_return_code

# websocket
echo "start docker container: websocket"
docker rm -f websocket
docker run -d --name websocket -e "SECRET=YOUR_SESSION_SECRET_HERE" --net host devicefarmer/stf stf websocket --port 3600 --storage-url http://${IP_ADDRESS}/ --connect-sub tcp://${IP_ADDRESS}:7150 --connect-push tcp://${IP_ADDRESS}:7170
check_return_code

# reaper
echo "start docker container: reaper"
docker rm -f reaper
docker run -d --name reaper --net host devicefarmer/stf stf reaper dev --connect-push tcp://${IP_ADDRESS}:7270 --connect-sub tcp://${IP_ADDRESS}:7150 --heartbeat-timeout 30000
check_return_code

# provider
echo "start docker container: provider-${HOSTNAME}"
docker rm -f provider1
docker run -d --name provider1 --net host devicefarmer/stf stf provider --name "provider-${HOSTNAME}" --connect-sub tcp://${IP_ADDRESS}:7250 --connect-push tcp://${IP_ADDRESS}:7270 --storage-url http://${IP_ADDRESS} --public-ip ${IP_ADDRESS} --min-port=15000 --max-port=25000 --heartbeat-interval 20000 --screen-ws-url-pattern "ws://${IP_ADDRESS}/d/floor4/<%= serial %>/<%= publicPort %>/"
check_return_code


