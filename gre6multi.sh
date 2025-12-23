#!/bin/bash
# Script to configure or remove multiple GRE6 tunnels (up to 2 Iran servers) with 1 Kharej server
# Supports configuring on Kharej (multiple tunnels to Iran servers) or on one Iran server (single tunnel to Kharej)
# NAT is only applied on Iran servers

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Function to validate IPv6 address
validate_ipv6() {
    local ip=$1
    if [[ $ip =~ ^[0-9a-fA-F:]+$ ]]; then
        return 0
    else
        echo "Invalid IPv6 address: $ip"
        return 1
    fi
}

# Function to create rc.local for Kharej Server (multiple tunnels to 2 Iran servers)
create_rc_local_kharej() {
    local kharej_ipv6=$1
    shift
    local iran_ipv6s=("$@")  # Array of Iran IPv6 addresses

    echo "Creating /etc/rc.local for Kharej Server with ${#iran_ipv6s[@]} Iran server(s)..."

    cat > /etc/rc.local << EOF
#!/bin/bash
# Enable IPv6 and IPv4 forwarding
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv4.conf.all.forwarding=1

EOF

    local index=1
    for iran_ipv6 in "${iran_ipv6s[@]}"; do
        cat >> /etc/rc.local << EOF
# Configure GRE6 tunnel to Iran Server $index
ip -6 tunnel add GRE6-$index mode ip6gre local $kharej_ipv6 remote $iran_ipv6
ip addr add 172.16.$((index)).2/30 dev GRE6-$index
ip link set GRE6-$index mtu 1420
ip link set GRE6-$index up

EOF
        ((index++))
    done

    cat >> /etc/rc.local << EOF
exit 0
EOF

    chmod +x /etc/rc.local
    echo "/etc/rc.local created and made executable."
    echo "Executing /etc/rc.local to apply changes immediately..."
    if bash /etc/rc.local; then
        echo "Changes applied successfully."
    else
        echo "Error: Failed to execute /etc/rc.local."
        exit 1
    fi
}

# Function to create rc.local for Iran Server (single tunnel to Kharej)
create_rc_local_iran() {
    local iran_ipv6=$1
    local kharej_ipv6=$2
    local tunnel_index=$3  # For consistent naming when multiple Irans connect to same Kharej

    echo "Creating /etc/rc.local for Iran Server (tunnel index $tunnel_index)..."

    cat > /etc/rc.local << EOF
#!/bin/bash
# Enable IPv6 and IPv4 forwarding
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv4.conf.all.forwarding=1

# Configure GRE6 tunnel to Kharej Server
ip -6 tunnel add GRE6-$tunnel_index mode ip6gre remote $kharej_ipv6 local $iran_ipv6
ip addr add 172.16.$tunnel_index.1/30 dev GRE6-$tunnel_index
ip link set GRE6-$tunnel_index mtu 1420
ip link set GRE6-$tunnel_index up

# Configure iptables NAT rules (forward traffic from Kharej side)
iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 172.16.$tunnel_index.1
iptables -t nat -A PREROUTING -p tcp --dport 1:65535 -j DNAT --to-destination 172.16.$tunnel_index.2:1-65535
iptables -t nat -A PREROUTING -p udp --dport 1:65535 -j DNAT --to-destination 172.16.$tunnel_index.2:1-65535
iptables -t nat -A POSTROUTING -j MASQUERADE

exit 0
EOF

    chmod +x /etc/rc.local
    echo "/etc/rc.local created and made executable."
    echo "Executing /etc/rc.local to apply changes immediately..."
    if bash /etc/rc.local; then
        echo "Changes applied successfully."
    else
        echo "Error: Failed to execute /etc/rc.local."
        exit 1
    fi
}

# Function to remove all configured tunnels and NAT rules
remove_tunnel() {
    echo "Removing all GRE6 tunnels and NAT rules..."

    # Remove tunnels GRE6-1 and GRE6-2 if they exist
    for i in 1 2; do
        ip -6 tunnel del GRE6-$i 2>/dev/null || echo "No GRE6-$i tunnel found."
    done

    # Flush and delete NAT rules (safe even if not present)
    iptables -t nat -F PREROUTING 2>/dev/null
    iptables -t nat -F POSTROUTING 2>/dev/null
    iptables -t nat -X 2>/dev/null

    # Remove /etc/rc.local if exists
    if [[ -f /etc/rc.local ]]; then
        rm /etc/rc.local
        echo "/etc/rc.local removed."
    fi

    echo "Removal completed."
}

# Prompt for option
echo "Select an option:"
echo "1) Configure Kharej Server (connects to up to 2 Iran servers)"
echo "2) Configure Iran Server (connects to 1 Kharej server)"
echo "3) Remove all tunnels"
read -p "Enter choice (1, 2, or 3): " choice

case "$choice" in
    1)
        echo "Configuring Kharej Server..."
        read -p "Enter Kharej Server Public IPv6 address: " kharej_ipv6
        if ! validate_ipv6 "$kharej_ipv6"; then exit 1; fi

        iran_ipv6s=()
        for i in 1 2; do
            read -p "Enter Iran Server $i Public IPv6 address (press Enter to skip second): " iran_ipv6
            if [[ -z "$iran_ipv6" ]]; then
                break
            fi
            if ! validate_ipv6 "$iran_ipv6"; then exit 1; fi
            iran_ipv6s+=("$iran_ipv6")
        done

        if [[ ${#iran_ipv6s[@]} -eq 0 ]]; then
            echo "At least one Iran server is required."
            exit 1
        fi

        create_rc_local_kharej "$kharej_ipv6" "${iran_ipv6s[@]}"
        ;;
    2)
        echo "Configuring Iran Server..."
        read -p "Enter this Iran Server Public IPv6 address: " iran_ipv6
        if ! validate_ipv6 "$iran_ipv6"; then exit 1; fi

        read -p "Enter Kharej Server Public IPv6 address: " kharej_ipv6
        if ! validate_ipv6 "$kharej_ipv6"; then exit 1; fi

        read -p "Enter tunnel index for this Iran server (1 or 2, must match Kharej side): " tunnel_index
        if [[ "$tunnel_index" != "1" && "$tunnel_index" != "2" ]]; then
            echo "Invalid index. Must be 1 or 2."
            exit 1
        fi

        create_rc_local_iran "$iran_ipv6" "$kharej_ipv6" "$tunnel_index"
        ;;
    3)
        remove_tunnel
        ;;
    *)
        echo "Invalid choice."
        exit 1
        ;;
esac

exit 0
