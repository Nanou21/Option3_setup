#!/bin/bash

echo "Stopping free5GC processes..."

sudo pkill -x amf  2>/dev/null || true
sudo pkill -x smf  2>/dev/null || true
sudo pkill -x nrf  2>/dev/null || true
sudo pkill -x ausf 2>/dev/null || true
sudo pkill -x udm  2>/dev/null || true
sudo pkill -x udr  2>/dev/null || true
sudo pkill -x nssf 2>/dev/null || true
sudo pkill -x pcf  2>/dev/null || true
sudo pkill -x chf  2>/dev/null || true
sudo pkill -x upf  2>/dev/null || true

echo "Removing stale UPF GTP interfaces..."

sudo ip netns exec upf1ns ip link del upfgtp 2>/dev/null || true
sudo ip netns exec upf2ns ip link del upfgtp 2>/dev/null || true

echo "Checking for remaining 5G processes..."

ps aux | grep -E 'amf|smf|nrf|ausf|udm|udr|nssf|pcf|chf|upf|nr-gnb|nr-ue' | grep -v grep

echo "Cleanup complete."
