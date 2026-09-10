#!/bin/bash

#!/bin/bash

# Create namespaces if they don't exist
sudo ip netns add upf1ns 2>/dev/null || true
sudo ip netns add upf2ns 2>/dev/null || true
sudo ip netns add dn2ns  2>/dev/null || true

# Clean stale gtp5g interfaces
sudo ip netns exec upf1ns ip link del upfgtp 2>/dev/null || true
sudo ip netns exec upf2ns ip link del upfgtp 2>/dev/null || true

# Clean stale N6 interfaces
sudo ip netns exec upf2ns ip link del upf2-n6 2>/dev/null || true
sudo ip netns exec dn2ns ip link del dn2-veth 2>/dev/null || true

# Clean old host-side veths
sudo ip link del veth-upf1-host 2>/dev/null || true
sudo ip link del veth-upf2-host 2>/dev/null || true
sudo ip link del upf1-data-host 2>/dev/null || true
sudo ip link del upf2-data-host 2>/dev/null || true

# Bring loopback up
sudo ip netns exec upf1ns ip link set lo up
sudo ip netns exec upf2ns ip link set lo up
sudo ip netns exec dn2ns  ip link set lo up


# =========================
# UPF1 N4
# =========================

sudo ip link add veth-upf1-host type veth peer name veth-upf1-ns
sudo ip link set veth-upf1-ns netns upf1ns

sudo ip addr add 10.200.1.1/24 dev veth-upf1-host
sudo ip link set veth-upf1-host up

sudo ip netns exec upf1ns ip addr add 10.200.1.2/24 dev veth-upf1-ns
sudo ip netns exec upf1ns ip link set veth-upf1-ns up


# =========================
# UPF2 N4
# =========================

sudo ip link add veth-upf2-host type veth peer name veth-upf2-ns
sudo ip link set veth-upf2-ns netns upf2ns

sudo ip addr add 10.200.2.1/24 dev veth-upf2-host
sudo ip link set veth-upf2-host up

sudo ip netns exec upf2ns ip addr add 10.200.2.2/24 dev veth-upf2-ns
sudo ip netns exec upf2ns ip link set veth-upf2-ns up


# =========================
# UPF1 N3 / DATA
# =========================

sudo ip link add upf1-data-host type veth peer name upf1-data-ns
sudo ip link set upf1-data-ns netns upf1ns

sudo ip addr add 10.201.1.1/30 dev upf1-data-host
sudo ip link set upf1-data-host up

sudo ip netns exec upf1ns ip addr add 10.201.1.2/30 dev upf1-data-ns
sudo ip netns exec upf1ns ip addr add 192.168.56.41/32 dev upf1-data-ns
sudo ip netns exec upf1ns ip link set upf1-data-ns up


# =========================
# UPF2 N3 / DATA
# =========================

sudo ip link add upf2-data-host type veth peer name upf2-data-ns
sudo ip link set upf2-data-ns netns upf2ns

sudo ip addr add 10.201.2.1/30 dev upf2-data-host
sudo ip link set upf2-data-host up

sudo ip netns exec upf2ns ip addr add 10.201.2.2/30 dev upf2-data-ns
sudo ip netns exec upf2ns ip addr add 192.168.56.42/32 dev upf2-data-ns
sudo ip netns exec upf2ns ip link set upf2-data-ns up

# =========================
# UPF2 N6 / DATA NETWORK
# =========================


# Create N6 veth pair
sudo ip link add upf2-n6 type veth peer name dn2-veth

# UPF-facing side -> UPF2 namespace
sudo ip link set upf2-n6 netns upf2ns

# DN-facing side -> DN namespace
sudo ip link set dn2-veth netns dn2ns

# UPF2 N6 address
sudo ip netns exec upf2ns \
    ip addr add 10.100.0.254/24 dev upf2-n6

sudo ip netns exec upf2ns \
    ip link set upf2-n6 up

# DN host address
sudo ip netns exec dn2ns \
    ip addr add 10.100.0.1/24 dev dn2-veth

sudo ip netns exec dn2ns \
    ip link set dn2-veth up
# =========================
# SMF PFCP ADDRESS
# =========================

sudo ip addr replace 10.200.0.1/32 dev lo


# =========================
# ROUTES
# =========================

sudo ip route replace 192.168.56.41/32 via 10.201.1.2 dev upf1-data-host
sudo ip route replace 192.168.56.42/32 via 10.201.2.2 dev upf2-data-host

sudo ip netns exec upf1ns ip route replace 192.168.56.0/24 via 10.201.1.1
sudo ip netns exec upf2ns ip route replace 192.168.56.0/24 via 10.201.2.1

sudo ip netns exec upf1ns ip route replace 10.200.0.1/32 via 10.200.1.1
sudo ip netns exec upf2ns ip route replace 10.200.0.1/32 via 10.200.2.1

# =========================
# DN RETURN ROUTES
# =========================

sudo ip netns exec dn2ns \
    ip route replace 10.60.0.0/16 via 10.100.0.254
    
sudo ip netns exec dn2ns \
    ip route replace 10.61.0.0/16 via 10.100.0.254
# =========================
# FORWARDING / PROXY ARP
# =========================

sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.conf.enp0s3.proxy_arp=1

sudo ip netns exec upf2ns sysctl -w net.ipv4.ip_forward=1


echo "UPF namespace networking configured."
