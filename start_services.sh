#!/bin/bash

cd /home/free5gc_5gcore/free5gc

sudo systemctl start mongod
sleep 2

./bin/nrf -c config/nrfcfg.yaml &
sleep 2

./bin/udr -c config/udrcfg.yaml &
sleep 2

./bin/udm -c config/udmcfg.yaml &
sleep 2

./bin/ausf -c config/ausfcfg.yaml &
sleep 2

./bin/nssf -c config/nssfcfg.yaml &
sleep 2

./bin/pcf -c config/pcfcfg.yaml &
sleep 2

./bin/amf -c config/amfcfg.yaml &
sleep 2

sudo ip netns exec upf1ns ./bin/upf \
-c config/multiUPF/upfcfg011.yaml & / 
> ~/upf1-current.log 2>&1 
sleep 2

sudo ip netns exec upf2ns ./bin/upf \
-c config/multiUPF/upfcfg022.yaml & / 
> ~/upf2-current.log 2>&1 
sleep 2

./bin/smf \
-c config/multiUPF/smfcfg.ulcl1.yaml \
-u config/multiUPF/uerouting.yaml / 
> ~/smf-n9-current.log 2>&1 

echo "free5GC services started"
