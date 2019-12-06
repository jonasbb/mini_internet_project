#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"

# read configs
readarray groups < "${DIRECTORY}"/config/AS_config.txt
readarray routers < "${DIRECTORY}"/config/router_config.txt
readarray l2_hosts < "${DIRECTORY}"/config/layer2_hosts_config.txt

group_numbers=${#groups[@]}
n_routers=${#routers[@]}
n_l2_hosts=${#l2_hosts[@]}


port_offset=0

# Create vpn a directory for each group
for ((k=0;k<group_numbers;k++)); do
    group_k=(${groups[$k]})
    group_number="${group_k[0]}"
    group_as="${group_k[1]}"

    ip_range_offset=0

    if [ "${group_as}" != "IXP" ];then
        mkdir -p "${DIRECTORY}"/groups/g"${group_number}"/vpn

        # start hosts
        for ((l=0;l<n_l2_hosts;l++)); do
            host_l=(${l2_hosts[$l]})
            hname="${host_l[0]}"
            vlan="${host_l[4]}"

            if [[ $hname == vpn* ]]; then

                echo "ovs-vsctl add-br vpnbr_${group_k}_${host_l}" >> "${DIRECTORY}"/groups/add_vpns.sh


                location="${DIRECTORY}"/groups/g"${group_number}"/vpn/"$hname"
                mkdir -p $location

                # Generate the keys and certificate request for the server
                openssl genrsa 1024 > $location/serv.key 2>/dev/null
                openssl req -nodes -new \
                    -key $location/serv.key \
                    -out  $location/serv.csr \
                    -subj "/C=CH/ST=Zurich/L=Zurich/O=ETHZ/OU=TIK/CN=server" 2>/dev/null


                # Generate the master CA key and certificate
                openssl genrsa 1024 > $location/ca.key 2>/dev/null
                openssl req -nodes -new -x509 \
                    -days 365 \
                    -key $location/ca.key \
                    -out $location/ca.crt \
                    -subj "/C=CH/ST=Zurich/L=Zurich/O=ETHZ/OU=TIK/CN=OpenVPN-CA" 2>/dev/null

                # Signature of the server certificat by the master CA
                openssl x509 -req \
                    -in $location/serv.csr \
                    -out $location/serv.crt \
                    -CA $location/ca.crt -CAkey $location/ca.key \
                    -CAcreateserial -CAserial $location/ca.srl 2>/dev/null


                # Create the keys and certificate request for the client
                for cname in 'client'
                do
                    openssl genrsa 1024 > $location/${cname}.key 2>/dev/null

                    openssl req -nodes -new \
                        -key $location/$cname.key \
                        -out $location/$cname.csr \
                        -subj "/C=CH/ST=Zurich/L=Zurich/O=ETHZ/OU=TIK/CN=$cname" 2>/dev/null

                    openssl x509 -req \
                        -in $location/$cname.csr \
                        -out $location/$cname.crt \
                        -CA $location/ca.crt -CAkey $location/ca.key \
                        -CAcreateserial -CAserial $location/ca.srl 2>/dev/null
                done

                DH_KEY_SIZE=512
                openssl dhparam -out $location/dh.pem ${DH_KEY_SIZE} 2>/dev/null


                echo "proto udp" >> $location/server.conf
                echo "port "$(($port_offset+10000)) >> $location/server.conf
                echo "dev tap_g"${group_number}_$hname >> $location/server.conf
                echo "dev-type tap" >> $location/server.conf
                echo "ca $location/ca.crt" >> $location/server.conf
                echo "cert $location/serv.crt" >> $location/server.conf
                echo "key $location/serv.key" >> $location/server.conf
                echo "dh $location/dh.pem" >> $location/server.conf
                echo "server-bridge $group_number.200.$vlan.1 255.255.255.0 $group_number.200.$vlan.$((50+$ip_range_offset)) $group_number.200.$vlan.$((60+$ip_range_offset))" >> $location/server.conf
                echo "keepalive 10 120" >> $location/server.conf
                echo "cipher AES-256-CBC" >> $location/server.conf
                echo "persist-key" >> $location/server.conf
                echo "persist-tun" >> $location/server.conf
                echo "status openvpn-status.log" >> $location/server.conf
                echo "verb 3" >> $location/server.conf
                echo "explicit-exit-notify 1" >> $location/server.conf
                echo "auth-user-pass-verify $location/cred.sh via-file" >> $location/server.conf
                echo "script-security 2" >> $location/server.conf
                echo "verify-client-cert none" >> $location/server.conf

                passwd_loc=$(pwd "${DIRECTORY}")/groups/ssh_passwords.txt
                echo "#!/bin/bash" >> $location/cred.sh
                echo "passwd=\$(sed \"${group_number}q;d\" $passwd_loc)" >> $location/cred.sh
                echo "readarray -t lines < \$1" >> $location/cred.sh
                echo "username=\${lines[0]}" >> $location/cred.sh
                echo "password=\${lines[1]}" >> $location/cred.sh
                echo "if [ \"\$username\" == \"group$group_number\" ] && [ \"\$password\" == \"\$passwd\" ]; then" >> $location/cred.sh
                echo "exit 0" >> $location/cred.sh
                echo "else" >> $location/cred.sh
                echo "exit 1" >> $location/cred.sh
                echo "fi" >> $location/cred.sh
                chmod +x "${location}"/cred.sh

                echo "client" >> $location/client.conf
                echo "remote VPN_IP VPN_PORT" >> $location/client.conf
                echo "dev tap" >> $location/client.conf
                echo "proto udp" >> $location/client.conf
                echo "resolv-retry infinite" >> $location/client.conf
                echo "nobind" >> $location/client.conf
                echo "persist-key" >> $location/client.conf
                echo "persist-tun" >> $location/client.conf
                echo "ca ca.crt" >> $location/client.conf
                echo "cipher AES-256-CBC" >> $location/client.conf
                echo "verb 3" >> $location/client.conf
                echo "auth-user-pass" >> $location/client.conf

                echo "openvpn --config $location/server.conf --log $location/log.txt &" >> "${DIRECTORY}"/groups/add_vpns.sh
                echo "echo kill \$! >> groups/del_vpns.sh" >> "${DIRECTORY}"/groups/add_vpns.sh

                port_offset=$(($port_offset+1))
                ip_range_offset=$(($ip_range_offset+5))
            fi
        done
    fi
done
