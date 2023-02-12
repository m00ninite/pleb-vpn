#!/bin/bash

# script to enable split-tunneling of tor on or off for pleb-vpn

# command info
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "-help" ]; then
  echo "config script to turn tor split-tunnelng on or off"
  echo "tor.split-tunnel.sh [on|off|status]"
  exit 1
fi

plebVPNConf="/home/admin/pleb-vpn/pleb-vpn.conf"

function setting() # FILE LINENUMBER NAME VALUE
{
  FILE=$1
  LINENUMBER=$2
  NAME=$3
  VALUE=$4
  settingExists=$(cat ${FILE} | grep -c "^${NAME}=")
  echo "# setting ${FILE} ${LINENUMBER} ${NAME} ${VALUE}"
  echo "# ${NAME} exists->(${settingExists})"
  if [ "${settingExists}" == "0" ]; then
    echo "# adding setting (${NAME})"
    sudo sed -i --follow-symlinks "${LINENUMBER}i${NAME}=" ${FILE}
  fi
  echo "# updating setting (${NAME}) with value(${VALUE})"
  sudo sed -i --follow-symlinks "s/^${NAME}=.*/${NAME}=${VALUE}/g" ${FILE}
}

status() {
  source ${plebVPNConf}
  local skipWhiptail="${1}"
  if [ ! "${skipWhiptail}" = "1" ]; then
    whiptail --title "Tor Split-Tunnel status check" --msgbox "If you interrupt this test (Ctrl + C) then you should make sure your VPN is active with 
'sudo systemctl start openvpn@plebvpn' before resuming operations. This test will temporarily 
deactivate the VPN to see if tor can connect without the VPN operational. 

This test can take some time. 

A failure of this test does not necessarily indicate that split-tunneling is not active, 
it could be that tor is down or having issues.
" 15 100
  fi
  echo "NOTE: If you interrupt this test (Ctrl + C) then you should make sure your VPN is active with 
'sudo systemctl start openvpn@plebvpn' before resuming operations. This test will temporarily 
deactivate the VPN to see if tor can connect without the VPN operational. This test can take some time. 
A failure of this test does not necessarily indicate that split-tunneling is not active, it could be 
that tor is down or having issues."
  echo "checking configuration"
  if [ ! "${torSplitTunnel}" = "on" ]; then
    whiptail --title "Tor Split-Tunnel status" --msgbox "
Tor Split-Tunnel service is off by config.
Use menu to install Pleb-VPN.
" 9 40
    exit 0
  else
    message="Tor Split-Tunnel service is working normally"
    echo "Checking connection over clearnet with VPN on..."
    VPNclearnetIP=$(curl https://api.ipify.org)
    sleep 5
    echo "Stopping VPN"
    systemctl stop openvpn@plebvpn
    sleep 5
    echo "Checking connection over clearnet with VPN off (should fail)" 
    noVPNclearnetIP=$(curl https://api.ipify.org)
    sleep 5
    if [ "${noVPNclearnetIP}" = "" ]; then
      firewallOK="yes"
    else
      firewallOK="no"
      message="error...firewall not configured. Clearnet accessible when VPN is off. Uninstall and re-install pleb-vpn"
    fi
    echo "Checking connection over tor with VPN off (can take some time, possibly multiple tries)..."
    echo "Will attempt a connection up to 5 times before giving up..."
    inc=1
    while [ $inc -le 5 ]
    do
      echo "attempt number ${inc}"
      noVPNtorIP=$(torify curl http://api.ipify.org)
      echo "tor IP = (${noVPNtorIP})...should not be blank, should not be your home IP, and should not be your VPN IP."
      if [ ! "${noVPNtorIP}" = "" ]; then
        inc=11
      else
        ((inc++))
      fi
    done
    sleep 5
    if [ ! "${noVPNtorIP}" = "" ]; then
      torSplitTunnelOK="yes"
    else 
      message="error...unable to connect over tor when VPN is down. It's possible that it needs more time to establish a connection. 
Try checking the status using STATUS menu later. If unable to connect, uninstall and re-install Tor Split-Tunnel."
      torSplitTunnelOK="no"
    fi
    echo "Restarting VPN"
    systemctl start openvpn@plebvpn
    sleep 5
    echo "Checking connection over clearnet with VPN on..."
    currentIP=$(curl https://api.ipify.org)
    sleep 5
    if ! [ "${currentIP}" = "${vpnIP}" ]; then
      vpnWorking="no"
      message="ERROR: your current IP does not match your vpnIP"
    else
      vpnWorking="yes"
    fi 
    whiptail --title "Tor Split-Tunnel status" --msgbox "
Split-Tunnel activated: yes
VPN operating: ${vpnWorking}
Tor able to connect through firewall when VPN is down: ${torSplitTunnelOK}
VPN server IP: ${vpnIP}
VPN server port: ${vpnPort}
Current IP (should match VPN server IP): ${currentIP}
Firewall configuration OK: ${firewallOK}
${message}
" 16 100
    exit 0
  fi
}

on() {
  # configure tor to skip pleb-vpn for redundancy
  source ${plebVPNConf}

  # install dependencies
echo "Checking and installing requirements..."
  # check for cgroup and install
  echo "Checking cgroup-tools..."
  checkcgroup=$(cgcreate -h 2>/dev/null | grep -c "Usage")
  if [ $checkcgroup -eq 0 ]; then
    echo "Installing cgroup-tools..."
    if apt-get install -y cgroup-tools >/dev/null; then
      echo "> cgroup-tools installed"
      echo
    else
      echo "> failed to install cgroup-tools"
      echo
      exit 1
    fi
  else
    echo "> cgroup-tools found"
    echo
  fi
  # check nftables
  echo "Checking nftables installation..."
  checknft=$(nft -v 2>/dev/null | grep -c "nftables")
  if [ $checknft -eq 0 ]; then
    echo "Installing nftables..."
    if apt-get install -y nftables >/dev/null; then
      echo "> nftables installed"
      echo
    else
      echo "> failed to install nftables"
      echo
      exit 1
    fi
  else
    echo "> nftables found"
    echo
  fi

  # clean rules from failed install attempts
  echo "cleaning ip rules to prevent duplicate rules"
  OIFNAME=$(ip r | grep default | cut -d " " -f5)
  GATEWAY=$(ip r | grep default | cut -d " " -f3)

  # first check for and remove old names from prior starts
  ip_nat_handles=$(nft -a list table ip nat | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
  while [ $(nft list table ip nat | grep -c "meta cgroup 1114129 counter") -gt 0 ]
  do
    ruleNumber=$(nft list table ip nat | grep -c "meta cgroup 1114129 counter")
    ip_nat_handle=$(echo "${ip_nat_handles}" | sed -n ${ruleNumber}p)
    nft delete rule ip nat POSTROUTING handle ${ip_nat_handle}
  done
  while [ $(nft list tables | grep -c mangle) -gt 0 ]
  do
    nft delete table ip mangle
  done
  ip_filter_input_handles=$(nft -a list chain ip filter ufw-user-input | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
  while [ $(nft list chain ip filter ufw-user-input | grep -c "meta cgroup 1114129 counter") -gt 0 ]
  do
    ruleNumber=$(nft list chain ip filter ufw-user-input | grep -c "meta cgroup 1114129 counter")
    ip_filter_input_handle=$(echo "${ip_filter_input_handles}" | sed -n ${ruleNumber}p)
    nft delete rule ip filter ufw-user-input handle ${ip_filter_input_handle}
  done
  ip_filter_output_handles=$(nft -a list chain ip filter ufw-user-output | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
  while [ $(nft list chain ip filter ufw-user-output | grep -c "meta cgroup 1114129 counter") -gt 0 ]
  do
    ruleNumber=$(nft list chain ip filter ufw-user-output | grep -c "meta cgroup 1114129 counter")
    ip_filter_output_handle=$(echo "${ip_filter_output_handles}" | sed -n ${ruleNumber}p)
    nft delete rule ip filter ufw-user-output handle ${ip_filter_output_handle}
  done
  while [ $(ip rule | grep -c "fwmark 0xb lookup novpn") -gt 0 ]
  do
    ip rule del from all table novpn fwmark 11
  done
  while [ $(ip rule | grep -c novpn) -gt 0 ]
  do
    ip rou del from all table novpn default via ${GATEWAY}
  done

  # create group novpn
  sudo groupadd novpn

  # create routing table
  if [ ! -d /etc/iproute2/rt_tables.d ]; then
    mkdir /etc/iproute2/rt_tables.d/
  fi
  echo "1000 novpn" | tee /etc/iproute2/rt_tables.d/novpn-route.conf

  # create-cgroup.sh
  echo "create create-cgroup.sh in pleb-vpn/split-tunnel..."
  if [ ! -d /home/admin/pleb-vpn/split-tunnel ]; then
    mkdir /home/admin/pleb-vpn/split-tunnel
  fi
  echo '#!/bin/bash

# creates cgroup novpn for processes to skip vpn
modprobe cls_cgroup
if [ ! -d /sys/fs/cgroup/net_cls ]; then
  mkdir /sys/fs/cgroup/net_cls
fi
mount -t cgroup -o net_cls novpn /sys/fs/cgroup/net_cls
cgcreate -t debian-tor:novpn -a debian-tor:novpn -d 775 -f 664 -s 664 -g net_cls:novpn
echo 0x00110011 > /sys/fs/cgroup/net_cls/novpn/net_cls.classid

' | tee /home/admin/pleb-vpn/split-tunnel/create-cgroup.sh
  chmod 755 -R /home/admin/pleb-vpn/split-tunnel
  # run create-cgroup.sh
  echo "execute create-cgroup.sh"
  /home/admin/pleb-vpn/split-tunnel/create-cgroup.sh

  # create pleb-vpn-create-cgroup.service
  echo "create create-cgroup.service to auto-create cgroup on start"
  echo "[Unit]
Description=Creates cgroup for split-tunneling tor from vpn
StartLimitInterval=200
StartLimitBurst=5
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash /home/admin/pleb-vpn/split-tunnel/create-cgroup.sh
[Install]
WantedBy=multi-user.target
" | tee /etc/systemd/system/pleb-vpn-create-cgroup.service

  # add pleb-vpn-create-cgroup.service as a tor requirement
  echo "adding pleb-vpn-create-cgroup.service as a requirement to start tor"
  if [ ! -d /etc/systemd/system/tor@default.service.d ]; then
    mkdir /etc/systemd/system/tor@default.service.d >/dev/null
  fi
  echo "#Don't edit this file, it is created by pleb-vpn split-tunnel
[Unit]
Requires=pleb-vpn-create-cgroup.service
After=pleb-vpn-create-cgroup.service
" | tee /etc/systemd/system/tor@default.service.d/tor-cgroup.conf

  # tor-split-tunnel.sh
  echo "create tor-split-tunnel.sh in pleb-vpn/split-tunnel to add tor to cgroup for split-tunnel"
  echo '#!/bin/bash

# adds tor to cgroup for split-tunneling
tor_pid=$(pgrep -x tor)
cgclassify -g net_cls:novpn $tor_pid
' | tee /home/admin/pleb-vpn/split-tunnel/tor-split-tunnel.sh
  chmod 755 -R /home/admin/pleb-vpn/split-tunnel
  # run tor-split-tunnel.sh
  echo "execute tor-split-tunnel.sh"
  /home/admin/pleb-vpn/split-tunnel/tor-split-tunnel.sh
  
  # create pleb-vpn-tor-split-tunnel.service
  echo "Create tor-split-tunnel.service systemd service..."
  echo "[Unit]
Description=Adding tor process to cgroup novpn
Requires=tor@default.service
After=tor@default.service
[Service]
Type=oneshot
ExecStart=/bin/bash /home/admin/pleb-vpn/split-tunnel/tor-split-tunnel.sh
[Install]
WantedBy=multi-user.target
" | tee /etc/systemd/system/pleb-vpn-tor-split-tunnel.service
  # create pleb-vpn-tor-split-tunnel.timer
  echo "Create tor-split-tunnel.timer systemd service..."
  echo "[Unit]
Description=1 min timer to add tor process to cgroup novpn
[Timer]
OnBootSec=10
OnUnitActiveSec=10
Persistent=true
[Install]
WantedBy=timers.target
" | tee /etc/systemd/system/pleb-vpn-tor-split-tunnel.timer

  # nftables-config.sh
  echo "Creating nftables-config.sh in pleb-vpn/split-tunnel..."
  echo '#!/bin/bash

# adds route and rules to allow novpn cgroup past firewall

# first clean tables from existing duplicate rules
OIFNAME=$(ip r | grep default | cut -d " " -f5)
GATEWAY=$(ip r | grep default | cut -d " " -f3)

# first check for and remove old names from prior starts
ip_nat_handles=$(nft -a list table ip nat | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
while [ $(nft list table ip nat | grep -c "meta cgroup 1114129 counter") -gt 0 ]
do
  ruleNumber=$(nft list table ip nat | grep -c "meta cgroup 1114129 counter")
  ip_nat_handle=$(echo "${ip_nat_handles}" | sed -n ${ruleNumber}p)
  nft delete rule ip nat POSTROUTING handle ${ip_nat_handle}
done
while [ $(nft list tables | grep -c mangle) -gt 0 ]
do
  nft delete table ip mangle
done
ip_filter_input_handles=$(nft -a list chain ip filter ufw-user-input | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
while [ $(nft list chain ip filter ufw-user-input | grep -c "meta cgroup 1114129 counter") -gt 0 ]
do
  ruleNumber=$(nft list chain ip filter ufw-user-input | grep -c "meta cgroup 1114129 counter")
  ip_filter_input_handle=$(echo "${ip_filter_input_handles}" | sed -n ${ruleNumber}p)
  nft delete rule ip filter ufw-user-input handle ${ip_filter_input_handle}
done
ip_filter_output_handles=$(nft -a list chain ip filter ufw-user-output | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
while [ $(nft list chain ip filter ufw-user-output | grep -c "meta cgroup 1114129 counter") -gt 0 ]
do
  ruleNumber=$(nft list chain ip filter ufw-user-output | grep -c "meta cgroup 1114129 counter")
  ip_filter_output_handle=$(echo "${ip_filter_output_handles}" | sed -n ${ruleNumber}p)
  nft delete rule ip filter ufw-user-output handle ${ip_filter_output_handle}
done
while [ $(ip rule | grep -c "fwmark 0xb lookup novpn") -gt 0 ]
do
  ip rule del from all table novpn fwmark 11
done
while [ $(ip rule | grep -c novpn) -gt 0 ]
do
  ip rou del from all table novpn default via ${GATEWAY}
done

# add/refresh rules
nft add rule ip nat POSTROUTING oifname ${OIFNAME} meta cgroup 1114129 counter masquerade
nft add table ip mangle
nft add chain ip mangle markit "{type route hook output priority filter; policy accept;}"
nft add rule ip mangle markit meta cgroup 1114129 counter meta mark set 0xb
nft add rule ip filter ufw-user-input meta cgroup 1114129 counter accept
nft add rule ip filter ufw-user-output meta cgroup 1114129 counter accept
ip route add default via ${GATEWAY} table novpn
ip rule add fwmark 11 table novpn
' | tee /home/admin/pleb-vpn/split-tunnel/nftables-config.sh
  chmod 755 -R /home/admin/pleb-vpn/split-tunnel
  # run it once
  /home/admin/pleb-vpn/split-tunnel/nftables-config.sh

  # create nftables-config.service
  echo "Create nftables-config systemd service..."
  echo "[Unit]
Description=Configure nftables for split-tunnel process
Requires=pleb-vpn-tor-split-tunnel.service
After=pleb-vpn-tor-split-tunnel.service
[Service]
Type=oneshot
ExecStart=/bin/bash /home/admin/pleb-vpn/split-tunnel/nftables-config.sh
[Install]
WantedBy=multi-user.target
" | tee /etc/systemd/system/pleb-vpn-nftables-config.service

  # enable and start all services
  echo "enabling services..."
  systemctl daemon-reload >/dev/null
  systemctl enable pleb-vpn-create-cgroup.service
  systemctl enable pleb-vpn-tor-split-tunnel.service
  systemctl enable pleb-vpn-nftables-config.service
  systemctl enable pleb-vpn-tor-split-tunnel.timer
  echo "restart tor to pick up new split-tunnel configuration..."
  systemctl stop tor@default.service
  systemctl start pleb-vpn-create-cgroup.service
  systemctl start tor@default.service
  systemctl start pleb-vpn-tor-split-tunnel.service
  systemctl start pleb-vpn-nftables-config.service
  systemctl start pleb-vpn-tor-split-tunnel.timer

  # copy service config files to /mnt/hdd to preserve through updates
  cp -p -r /home/admin/pleb-vpn/split-tunnel /mnt/hdd/app-data/pleb-vpn/

  # check configuration
  echo "OK...tor is configured. Wait 2 minutes for tor to start..."
  sleep 60
  echo "wait 1 minute for tor to start..."
  sleep 60
  echo "checking configuration"
  echo "stop vpn"
  systemctl stop openvpn@plebvpn
  echo "vpn stopped"
  echo "checking firewall"
  currentIP=$(curl https://api.ipify.org)
  echo "current IP = (${currentIP})...should be blank"
  if [ "${currentIP}" = "" ]; then
    echo "firewall config ok"
  else 
    echo "error...firewall not configured. Clearnet accessible when VPN is off. Uninstall and re-install pleb-vpn"
    systemctl start openvpn@plebvpn
    exit 1
  fi
  echo "Checking connection over tor with VPN off (takes some time, likely multiple tries)..."
  echo "Will attempt a connection up to 10 times before giving up..."
  inc=1
  while [ $inc -le 10 ]
  do
    echo "attempt number ${inc}"
    torIP=$(torify curl http://api.ipify.org)
    echo "tor IP = (${torIP})...should not be blank, should not be your home IP, and should not be your VPN IP."
    if [ ! "${torIP}" = "" ]; then
      inc=11
    else
      ((inc++))
    fi
  done
  if [ ! "${torIP}" = "" ]; then
    echo "tor split-tunnel successful"
  else 
    echo "error...unable to connect over tor when VPN is down. It's possible that it needs more time to establish a connection. 
Try checking the status using STATUS menu later. If unable to connect, uninstall and re-install Tor Split-Tunnel."
  fi
  sleep 2
  echo "restarting vpn"
  systemctl start openvpn@plebvpn
  sleep 2
  echo "checking vpn IP"
  currentIP=$(curl https://api.ipify.org)
  echo "current IP = (${currentIP})...should be ${vpnIP}"
  echo "tor split-tunneling enabled!"
  sleep 2
  setting ${plebVPNConf} "2" "torSplitTunnel" "on"
  if [ ! $(ls /etc/systemd/system | grep -c lnd.service) -eq 0 ]; then
    systemctl restart lnd
  fi
  if [ ! $(ls /etc/systemd/system | grep -c lightningd.service) -eq 0 ]; then
    systemctl restart lightningd
  fi
  exit 0
}

off() {
  # remove tor split-tunneling process
  source ${plebVPNConf}
  local skipTest="${1}"

  # remove services
  echo "stop and remove systemd services"
  echo "stopping tor..."
  systemctl stop tor@default.service
  echo "stopping split-tunnel services..."
  systemctl stop pleb-vpn-create-cgroup.service
  systemctl stop pleb-vpn-tor-split-tunnel.service
  systemctl stop pleb-vpn-nftables-config.service
  systemctl stop pleb-vpn-tor-split-tunnel.timer
  systemctl disable pleb-vpn-create-cgroup.service
  systemctl disable pleb-vpn-tor-split-tunnel.service
  systemctl disable pleb-vpn-nftables-config.service
  systemctl disable pleb-vpn-tor-split-tunnel.timer
  rm /etc/systemd/system/pleb-vpn-create-cgroup.service
  rm /etc/systemd/system/pleb-vpn-tor-split-tunnel.service
  rm /etc/systemd/system/pleb-vpn-nftables-config.service
  rm /etc/systemd/system/pleb-vpn-tor-split-tunnel.timer

  # fix tor dependency
  echo "remove tor dependency"
  rm /etc/systemd/system/tor@default.service.d/tor-cgroup.conf

  # uninstall cgroup-tools
  echo "uninstall cgroup-tools"
  apt purge -y cgroup-tools

  # clean ip rules
  echo "cleaning ip rules"
  OIFNAME=$(ip r | grep default | cut -d " " -f5)
  GATEWAY=$(ip r | grep default | cut -d " " -f3)
  ip_nat_handles=$(nft -a list table ip nat | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
  while [ $(nft list table ip nat | grep -c "meta cgroup 1114129 counter") -gt 0 ]
  do
    ruleNumber=$(nft list table ip nat | grep -c "meta cgroup 1114129 counter")
    ip_nat_handle=$(echo "${ip_nat_handles}" | sed -n ${ruleNumber}p)
    nft delete rule ip nat POSTROUTING handle ${ip_nat_handle}
  done
  while [ $(nft list tables | grep -c mangle) -gt 0 ]
  do
    nft delete table ip mangle
  done
  ip_filter_input_handles=$(nft -a list chain ip filter ufw-user-input | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
  while [ $(nft list chain ip filter ufw-user-input | grep -c "meta cgroup 1114129 counter") -gt 0 ]
  do
    ruleNumber=$(nft list chain ip filter ufw-user-input | grep -c "meta cgroup 1114129 counter")
    ip_filter_input_handle=$(echo "${ip_filter_input_handles}" | sed -n ${ruleNumber}p)
    nft delete rule ip filter ufw-user-input handle ${ip_filter_input_handle}
  done
  ip_filter_output_handles=$(nft -a list chain ip filter ufw-user-output | grep "meta cgroup 1114129 counter" | sed "s/.*handle //")
  while [ $(nft list chain ip filter ufw-user-output | grep -c "meta cgroup 1114129 counter") -gt 0 ]
  do
    ruleNumber=$(nft list chain ip filter ufw-user-output | grep -c "meta cgroup 1114129 counter")
    ip_filter_output_handle=$(echo "${ip_filter_output_handles}" | sed -n ${ruleNumber}p)
    nft delete rule ip filter ufw-user-output handle ${ip_filter_output_handle}
  done
  while [ $(ip rule | grep -c "fwmark 0xb lookup novpn") -gt 0 ]
  do
    ip rule del from all table novpn fwmark 11
  done
  while [ $(ip rule | grep -c novpn) -gt 0 ]
  do
    ip rou del from all table novpn default via ${GATEWAY}
  done

  # remove routing table
  rm /etc/iproute2/rt_tables.d/novpn-route.conf

  # remove split-tunnel scripts
  echo "removing split-tunnel scripts"
  rm -rf /home/admin/pleb-vpn/split-tunnel
  rm -rf /mnt/hdd/app-data/pleb-vpn/split-tunnel

  # remove group novpn
  sudo groupdel novpn

  # restart tor
  echo "starting tor..."
  systemctl daemon-reload >/dev/null
  systemctl start tor@default.service

  # check configuration
  if [ ! "${skipTest}" = "1" ]; then
    echo "OK...tor is configured to run over the VPN. Wait 2 minutes for tor to start..."
    sleep 60
    echo "wait 1 minute for tor to start..."
    sleep 60
    echo "checking configuration"
    echo "stop VPN"
    systemctl stop openvpn@plebvpn
    sleep 5
    echo "VPN stopped"
    echo "checking firewall"
    currentIP=$(curl https://api.ipify.org)
    echo "current IP = (${currentIP})...should be blank"
    if [ "${currentIP}" = "" ]; then
      echo "firewall config ok"
    else 
      echo "error...firewall not configured. Clearnet accessible when VPN is off. Uninstall and re-install all of pleb-vpn."
      systemctl start openvpn@plebvpn
      exit 1
    fi
    torIP=$(torify curl http://api.ipify.org)
    echo "tor IP = (${torIP})...should be blank."
    if [ "${torIP}" = "" ]; then
      echo "tor configuration successful"
    else 
      echo "error...tor configuration unsuccessful. Uninstall all of Pleb-VPN to restore configuration."
      systemctl start openvpn@plebvpn
      exit 1
    fi
    sleep 2
    echo "restarting vpn"
    systemctl start openvpn@plebvpn
    systemctl restart tor@default.service
    sleep 2
    echo "checking VPN IP"
    currentIP=$(curl https://api.ipify.org)
    echo "current IP = (${currentIP})...should be ${vpnIP}"
    echo "Checking connection over tor with VPN on (takes some time, likely multiple tries)..."
    echo "Will attempt a connection up to 10 times before giving up..."
    inc=1
    while [ $inc -le 10 ]
    do
      echo "attempt number ${inc}"
      torIP=$(torify curl http://api.ipify.org)
      echo "tor IP = (${torIP})...should not be blank, should not be your home IP, and should not be your VPN IP."
      if [ ! "${torIP}" = "" ]; then
        inc=11
      else
        ((inc++))
      fi
    done
    if [ ! "${torIP}" = "" ]; then
      echo "tor configuration successful"
    else 
      echo "error...unable to connect over tor when VPN is up. It's possible that it needs more time to establish a connection. 
  Try checking the status of tor later. If still unable to connect over tor, try rebooting the node."
    fi
    sleep 5
    echo "tor split-tunneling is disabled and removed"
    sleep 2
  fi
  setting ${plebVPNConf} "2" "torSplitTunnel" "off"
  exit 0
}

case "${1}" in
  on) on ;;
  off) off "${2}" ;;
  status) status "${2}" ;;
esac
