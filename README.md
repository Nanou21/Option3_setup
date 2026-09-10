# free5GC Option 3 Multi-UPF N9 Testbed

Comprehensive setup and validation guide for a **two-gNB, two-UPF free5GC testbed** using **UERANSIM, VirtualBox, Linux network namespaces, PFCP/N4, GTP-U/N3, and GTP-U/N9**.

> **Validated:** 9 September 2026  
> **Host:** Ubuntu 24.04.4 x86_64  
> **Virtualization:** VirtualBox 7.1  
> **Core:** free5GC  
> **RAN/UE emulator:** UERANSIM  
> **UPF data plane:** gtp5g

## Overview

Option 3 implements a multi-UPF user-plane architecture in which traffic can be forwarded through an intermediate UPF and then to a second UPF over the 5G **N9** interface.

The testbed uses two gNB/UE pairs connected to a free5GC core with two UPFs. UPF1 acts as the intermediate user-plane node for the chained path, while UPF2 acts as the downstream/anchor UPF. The setup was designed to validate simultaneous multi-gNB operation, PFCP control of both UPFs, N3 connectivity from the RAN, and N9 forwarding between the UPFs.

The validated chained path for UE1 is:

```text
UE1 -> gNB1 -> UPF1 -> UPF2 -> Data Network
               N3      N9
```

UE2 provides a second simultaneous gNB/UE session for comparison and multi-access testing.

## Target Option 3 behavior

The final intended comparison is:

```text
UE1 -> gNB1 -> UPF1 -> UPF2 -> Data Network
               N3      N9

UE2 -> gNB2 --------> UPF2 -> Data Network
               N3
```

The SMF controls both UPFs over **N4/PFCP**, while the gNBs connect to the AMF over **N2/NGAP**.

Both N3 and N9 carry GTP-U over UDP port `2152`. The logical interface is determined by the tunnel endpoints and the forwarding rules installed by the SMF.

## Architecture

### Main IP addressing

| Function | Node / interface | IP address | Protocol / interface |
|---|---|---:|---|
| Core VM shared NIC | `enp0s3` | `192.168.56.4/24` | VirtualBox private network |
| gNB1 | N2/N3 source | `192.168.56.5` | NGAP + GTP-U |
| gNB2 | N2/N3 source | `192.168.56.6` | NGAP + GTP-U |
| SMF PFCP | Loopback | `10.200.0.1/32` | N4 / UDP 8805 |
| UPF1 PFCP | `veth-upf1-ns` | `10.200.1.2/24` | N4 / UDP 8805 |
| UPF2 PFCP | `veth-upf2-ns` | `10.200.2.2/24` | N4 / UDP 8805 |
| UPF1 data transit | `upf1-data-ns` | `10.201.1.2/30` | Namespace routed data path |
| UPF2 data transit | `upf2-data-ns` | `10.201.2.2/30` | Namespace routed data path |
| UPF1 GTP-U endpoint | UPF1 namespace | `192.168.56.41/32` | N3/N9 / UDP 2152 |
| UPF2 GTP-U endpoint | UPF2 namespace | `192.168.56.42/32` | N3/N9 / UDP 2152 |
| UE1 PDU address | `uesimtun0` | `10.60.0.1/32` | DNN `internet` |
| UE2 PDU address | `uesimtun0` | `10.60.0.2/32` | DNN `internet` |

---

# 1. VirtualBox setup

The implementation uses an Ubuntu host running VirtualBox with **three VMs** connected to the same private VirtualBox network:

1. a dedicated **free5GC Core VM**;
2. a dedicated **gNB1 + UE1 UERANSIM VM**; and
3. a dedicated **gNB2 + UE2 UERANSIM VM**.

This separation makes the two access-side test systems independent while allowing both gNBs to reach the same free5GC core.

| Component | Role | Address / network | Notes |
|---|---|---|---|
| Physical host | Virtualization host | Ubuntu 24.04.4 x86_64 | VirtualBox 7.1 |
| Core VM | free5GC control plane + UPF1 + UPF2 | `192.168.56.4/24` | Contains `upf1ns` and `upf2ns` |
| UERANSIM VM 1 | gNB1 + UE1 | gNB1 `192.168.56.5` | Dedicated VM for the first gNB/UE pair |
| UERANSIM VM 2 | gNB2 + UE2 | gNB2 `192.168.56.6` | Dedicated VM for the second gNB/UE pair |
| Shared VM network | N2/N3/N9 reachability | `192.168.56.0/24` | Common private VirtualBox segment |
| Data Network | Validation destination | `8.8.8.8` | Reached through UPF2/N6 |

The VirtualBox-level layout is therefore:

```text
                           VirtualBox private network
                              192.168.56.0/24

+----------------------+      +----------------------+      +----------------------+
| Core VM              |      | UERANSIM VM 1       |      | UERANSIM VM 2       |
| 192.168.56.4         |      | gNB1: 192.168.56.5  |      | gNB2: 192.168.56.6  |
|                      |      | UE1                  |      | UE2                  |
| AMF / SMF / UPFs     |<---->|                      |      |                      |
| upf1ns / upf2ns      |<--------------------------------->|                      |
+----------------------+      +----------------------+      +----------------------+
```

Before debugging any 5G-specific issue, verify that the Core VM can reach both UERANSIM VMs and that both gNB-side VMs can reach `192.168.56.4` on the shared `192.168.56.0/24` network.

---

# 2. Linux network namespace design

Two Linux namespaces isolate the two UPF instances so they can run independently on one Core VM.

- `upf1ns` hosts UPF1.
- `upf2ns` hosts UPF2.
- Each UPF has a dedicated **PFCP/N4 veth pair**.
- Each UPF also has a separate **data-plane veth pair**.
- The GTP-U addresses `.41` and `.42` remain inside their respective namespaces as `/32` addresses.

![Namespace topology](images/option3_namespaces.png)

## Namespace layout

```text
Root namespace / Core VM

                 SMF PFCP
                10.200.0.1/32
                      |
        +-------------+-------------+
        |                           |
  10.200.1.1                    10.200.2.1
 veth-upf1-host                veth-upf2-host
        |                           |
        |                           |
  veth-upf1-ns                  veth-upf2-ns
  10.200.1.2                    10.200.2.2
     upf1ns                        upf2ns

Data-plane transit:

Root                                  Namespace
10.201.1.1/30 <- upf1-data-host --- upf1-data-ns -> 10.201.1.2/30
                                               +-> 192.168.56.41/32

10.201.2.1/30 <- upf2-data-host --- upf2-data-ns -> 10.201.2.2/30
                                               +-> 192.168.56.42/32
```

---

# 3. Create the namespaces

```bash
sudo ip netns add upf1ns
sudo ip netns add upf2ns

sudo ip netns exec upf1ns ip link set lo up
sudo ip netns exec upf2ns ip link set lo up
```

## 3.1 PFCP/N4 veth pairs

### UPF1

```bash
sudo ip link add veth-upf1-host type veth peer name veth-upf1-ns
sudo ip link set veth-upf1-ns netns upf1ns

sudo ip addr add 10.200.1.1/24 dev veth-upf1-host
sudo ip link set veth-upf1-host up

sudo ip netns exec upf1ns ip addr add 10.200.1.2/24 dev veth-upf1-ns
sudo ip netns exec upf1ns ip link set veth-upf1-ns up
```

### UPF2

```bash
sudo ip link add veth-upf2-host type veth peer name veth-upf2-ns
sudo ip link set veth-upf2-ns netns upf2ns

sudo ip addr add 10.200.2.1/24 dev veth-upf2-host
sudo ip link set veth-upf2-host up

sudo ip netns exec upf2ns ip addr add 10.200.2.2/24 dev veth-upf2-ns
sudo ip netns exec upf2ns ip link set veth-upf2-ns up
```

### SMF PFCP endpoint and namespace return routes

```bash
sudo ip addr add 10.200.0.1/32 dev lo

sudo ip netns exec upf1ns ip route add 10.200.0.1/32 via 10.200.1.1
sudo ip netns exec upf2ns ip route add 10.200.0.1/32 via 10.200.2.1
```

## 3.2 UPF data-plane veth pairs

### UPF1

```bash
sudo ip link add upf1-data-host type veth peer name upf1-data-ns
sudo ip link set upf1-data-ns netns upf1ns

sudo ip addr add 10.201.1.1/30 dev upf1-data-host
sudo ip link set upf1-data-host up

sudo ip netns exec upf1ns ip addr add 10.201.1.2/30 dev upf1-data-ns
sudo ip netns exec upf1ns ip addr add 192.168.56.41/32 dev upf1-data-ns
sudo ip netns exec upf1ns ip link set upf1-data-ns up
```

### UPF2

```bash
sudo ip link add upf2-data-host type veth peer name upf2-data-ns
sudo ip link set upf2-data-ns netns upf2ns

sudo ip addr add 10.201.2.1/30 dev upf2-data-host
sudo ip link set upf2-data-host up

sudo ip netns exec upf2ns ip addr add 10.201.2.2/30 dev upf2-data-ns
sudo ip netns exec upf2ns ip addr add 192.168.56.42/32 dev upf2-data-ns
sudo ip netns exec upf2ns ip link set upf2-data-ns up
```

## 3.3 Host and namespace routes

```bash
# Host routes to the UPF GTP-U /32 endpoints
sudo ip route add 192.168.56.41/32 via 10.201.1.2 dev upf1-data-host
sudo ip route add 192.168.56.42/32 via 10.201.2.2 dev upf2-data-host

# Namespace routes back to the shared VM network
sudo ip netns exec upf1ns ip route add 192.168.56.0/24 via 10.201.1.1
sudo ip netns exec upf2ns ip route add 192.168.56.0/24 via 10.201.2.1

# Core VM forwarding and ARP behavior
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.conf.enp0s3.proxy_arp=1
```

The `/32` GTP-U endpoints remain in their namespaces. The root namespace reaches them using the explicit host routes through the `10.201.x.x` transit links.

---

# 4. gtp5g kernel module

The UPFs use the `gtp5g` kernel module.

```bash
sudo modprobe gtp5g
lsmod | grep gtp5g
```

During testing, a kernel update changed the running kernel to `7.0.0-30-generic`, while `gtp5g` had only been built for the previous kernel. The UPF then failed with:

```text
UPF Cli Run Error: open Gtp5g: open link: create: operation not supported
```

Rebuild the module for the current kernel:

```bash
cd ~/gtp5g
make clean
make
sudo make install
sudo depmod -a
sudo modprobe gtp5g
```

Verify:

```bash
uname -r
lsmod | grep gtp5g
modinfo gtp5g | grep filename
```

---

# 5. free5GC configuration

## 5.1 SMF PFCP endpoint

The SMF uses a dedicated loopback address reachable from both namespaces:

```yaml
pfcp:
  nodeID: 10.200.0.1
  listenAddr: 10.200.0.1
  externalAddr: 10.200.0.1
```

## 5.2 Slice and DNN

Validated slice and DNN:

```yaml
sNssai:
  sst: 1
  sd: 112233

dnn: internet
```

The local UPF DNN configuration includes both UE CIDR ranges:

```text
10.60.0.0/16
10.61.0.0/16
```

The UE address pool should be associated with the anchor/PSA side in the SMF user-plane configuration. Defining the same pool on both UPFs in the **SMF** configuration caused:

```text
overlap cidr value between UPFs
```

## 5.3 SMF user-plane topology

The relevant `userplaneInformation` topology is:

```yaml
userplaneInformation:
  upNodes:
    gNB1:
      type: AN
      an_ip: 192.168.56.5

    gNB2:
      type: AN
      an_ip: 192.168.56.6

    UPF1:
      type: UPF
      nodeID: 10.200.1.2
      addr: 10.200.1.2
      interfaces:
        - interfaceType: N3
          endpoints: [192.168.56.41]
          networkInstances: [internet]
        - interfaceType: N9
          endpoints: [192.168.56.41]
          networkInstances: [internet]

    UPF2:
      type: UPF
      nodeID: 10.200.2.2
      addr: 10.200.2.2
      interfaces:
        - interfaceType: N3
          endpoints: [192.168.56.42]
          networkInstances: [internet]
        - interfaceType: N9
          endpoints: [192.168.56.42]
          networkInstances: [internet]

  links:
    - A: gNB1
      B: UPF1
    - A: UPF1
      B: UPF2
    - A: gNB2
      B: UPF2

  ulcl: true
```

> Exact key spelling can differ across free5GC releases. The values and relationships above describe the working setup documented in this repository.

---

# 6. `uerouting.yaml` — critical N9 routing policy

This was the decisive configuration change.

```yaml
info:
  version: 1.0.7
  description: Routing information for UE

ueRoutingInfo:
  UE1:
    members:
      - imsi-208930000000001

    topology:
      - A: gNB1
        B: UPF1
      - A: UPF1
        B: UPF2

  UE2:
    members:
      - imsi-208930000000002

    topology:
      - A: gNB2
        B: UPF2

    specificPath:
      - dest: 8.8.8.8/32
        path: [UPF2]
```

### Why this matters

For UE1, the topology itself defines the default chained path:

```text
gNB1 -> UPF1 -> UPF2
```

No `specificPath` is required for UE1 in the final working configuration.

UE2 keeps an explicit steering rule:

```yaml
specificPath:
  - dest: 8.8.8.8/32
    path: [UPF2]
```

The key distinction is:

```text
topology     = the default UPF path available to the UE
specificPath = an explicit steering rule for matching destination traffic
```

Therefore, UE1 follows the topology-derived UPF1 -> UPF2 chain, while UE2 explicitly selects UPF2 for traffic destined to `8.8.8.8/32`.

---

# 7. Local UPF configuration

## 7.1 UPF1

UPF1 participates on both the access-side **N3** interface and the inter-UPF **N9** interface.

```yaml
pfcp:
  addr: 10.200.1.2
  nodeID: 10.200.1.2

gtpu:
  forwarder: gtp5g
  ifList:
    - addr: 192.168.56.41
      type: N3
    - addr: 192.168.56.41
      type: N9

dnnList:
  - dnn: internet
    cidr: 10.60.0.0/16
  - dnn: internet
    cidr: 10.61.0.0/16
```

Both logical interfaces use GTP-U/UDP 2152. In this configuration, the same UPF1 GTP-U endpoint is listed for both N3 and N9.

## 7.2 UPF2

In the **UPF2 local configuration file**, the GTP-U interface is kept as **N9 only**. This is separate from the SMF `userplaneInformation` block above, where UPF2 is still advertised with both N3 and N9 capabilities.

```yaml
pfcp:
  addr: 10.200.2.2
  nodeID: 10.200.2.2

gtpu:
  forwarder: gtp5g
  ifList:
    - addr: 192.168.56.42
      type: N9

dnnList:
  - dnn: internet
    cidr: 10.60.0.0/16
  - dnn: internet
    cidr: 10.61.0.0/16
```

---

# 8. UERANSIM configuration

## 8.1 gNB1

```yaml
linkIp: 192.168.56.5
ngapIp: 192.168.56.5
gtpIp: 192.168.56.5

amfConfigs:
  - address: 192.168.56.4
    port: 38412
```

## 8.2 gNB2

```yaml
linkIp: 192.168.56.6
ngapIp: 192.168.56.6
gtpIp: 192.168.56.6

amfConfigs:
  - address: 192.168.56.4
    port: 38412
```

## 8.3 UE session configuration

UE1:

```text
IMSI: 208930000000001
```

UE2:

```text
IMSI: 208930000000002
```

Both use:

```yaml
sessions:
  - type: IPv4
    apn: internet
    slice:
      sst: 0x01
      sd: 0x112233

configured-nssai:
  - sst: 0x01
    sd: 0x112233

default-nssai:
  - sst: 0x01
    sd: 0x112233
```

The free5GC subscriber profile, UE `sessions.slice`, `configured-nssai`, `default-nssai`, and SMF slice/DNN entries must all agree. A mismatch previously produced:

```text
DNN_NOT_SUPPORTED_OR_NOT_SUBSCRIBED
```

---

# 9. Recommended startup sequence

The test should be executed in the following order:

1. create the UPF namespaces on the Core VM;
2. start all free5GC services;
3. verify the **N4/PFCP** connections between the SMF and both UPFs;
4. start gNB1/UE1 and gNB2/UE2 on their respective UERANSIM VMs;
5. generate UE traffic and perform the **N3/N9** forwarding tests; and
6. stop the free5GC services when the experiment is complete.

### 9.1 Create the UPF namespaces

On the **Core VM**, first create the namespace and veth setup:

```bash
sudo bash create_ns.sh
```

Verify that both namespaces exist:

```bash
ip netns list
```

Expected:

```text
upf1ns
upf2ns
```

### 9.2 Start all free5GC services

Still on the **Core VM**, start the configured free5GC services:

```bash
sudo bash start_services.sh
```

Verify that the required processes are running:

```bash
pgrep -af 'nrf|amf|smf|ausf|udm|udr|nssf|pcf|upf'
```

Also verify that both UPFs are listening on PFCP and GTP-U:

```bash
sudo ip netns exec upf1ns ss -lunp | grep -E '8805|2152'
sudo ip netns exec upf2ns ss -lunp | grep -E '8805|2152'
```

Expected addresses include:

```text
UPF1 PFCP: 10.200.1.2:8805
UPF1 GTP-U: 192.168.56.41:2152

UPF2 PFCP: 10.200.2.2:8805
UPF2 GTP-U: 192.168.56.42:2152
```

### 9.3 Verify N4/PFCP on the Core VM

Before starting either gNB or UE, verify that the SMF can communicate with **both UPFs over N4/PFCP**.

Run:

```bash
sudo tshark -i any \
  -f "udp port 8805" \
  -Y "pfcp" \
  -T fields \
  -e frame.time_relative \
  -e ip.src \
  -e ip.dst \
  -e pfcp.msg_type
```

The validated setup showed PFCP communication between:

```text
SMF  10.200.0.1 <-> 10.200.1.2  UPF1
SMF  10.200.0.1 <-> 10.200.2.2  UPF2
```

During association setup, PFCP message types `5` and `6` correspond to:

```text
5 = Association Setup Request
6 = Association Setup Response
```

This N4 check should be completed before proceeding to the RAN and UE side of the experiment.

### 9.4 Start gNB1 and UE1 on UERANSIM VM 1

Start gNB1:

```bash
cd ~/UERANSIM
sudo ./build/nr-gnb -c config/free5gc-gnb1.yaml
```

In a second terminal on the same VM, start UE1:

```bash
cd ~/UERANSIM
sudo ./build/nr-ue -c config/free5gc-ue.yaml
```

### 9.5 Start gNB2 and UE2 on UERANSIM VM 2

Start gNB2:

```bash
cd ~/UERANSIM
sudo ./build/nr-gnb -c config/free5gc-gnb2.yaml
```

In a second terminal on the same VM, start UE2:

```bash
cd ~/UERANSIM
sudo ./build/nr-ue -c config/free5gc-ue2.yaml
```

After successful PDU-session establishment, each UE VM should expose a `uesimtun0` interface. In the validated test, UE1 received `10.60.0.1/32` and UE2 received `10.60.0.2/32`.

### 9.6 Run the N3/N9 forwarding tests

After both gNBs and UEs are running:

1. start the GTP-U capture on the **Core VM**;
2. generate traffic from each UE through `uesimtun0`; and
3. verify the N3 and N9 hops from the captured GTP-U packets.

The complete UE-side and Core-side commands are provided in Section 10.

### 9.7 Stop all free5GC services

At the end of the experiment, stop the free5GC services with:

```bash
sudo bash kill5g.sh
```

Verify that the processes have exited:

```bash
pgrep -af 'nrf|amf|smf|ausf|udm|udr|nssf|pcf|upf'
```


---

# 10. Validation

The validation sequence follows the same order as the startup workflow: first verify **N4/PFCP** on the Core VM, then start the gNBs and UEs, and finally perform the **N3/N9 user-plane tests**.

## 10.1 Core-side N3/N9 GTP-U test

On the **Core VM**, start with a broad GTP-U capture:

```bash
sudo tcpdump -ni any -nn 'udp port 2152'
```

For a more detailed trace showing the outer tunnel endpoints, inner UE/DN addresses, UDP ports, and TEID, use:

```bash
sudo tshark -i any \
  -f "udp port 2152" \
  -Y "gtp" \
  -T fields \
  -e frame.time_relative \
  -e ip.src \
  -e ip.dst \
  -e udp.srcport \
  -e udp.dstport \
  -e gtp.teid
```

For the working UE1 chain, the expected sequence is:

```text
192.168.56.5,10.60.0.1 -> 192.168.56.41,8.8.8.8
10.201.1.2,10.60.0.1   -> 192.168.56.42,8.8.8.8
```

This corresponds to:

```text
UE1 -> gNB1 (.5) -> UPF1 (.41) -> UPF2 (.42) -> DN
                       N3              N9
```

The first packet is the **N3** hop from gNB1 to UPF1. The second packet carries the same inner UE packet from UPF1 toward UPF2 and therefore demonstrates the **N9** hop.

To isolate the N9 traffic from UPF1 toward UPF2:

```bash
sudo tshark -i any \
  -f "udp port 2152" \
  -Y 'gtp && ip.src==10.201.1.2 && ip.dst==192.168.56.42'
```

> Because the capture uses `-i any`, Linux can display the same packet more than once as it crosses different interfaces. These duplicate observations do not represent additional 5G hops.

## 10.2 UE-side traffic generation

After the N4 check is complete, start both gNB/UE pairs as described in Section 9.

On **UERANSIM VM 1**, verify UE1's tunnel and generate traffic:

```bash
ip addr show uesimtun0
ping -I uesimtun0 -c 5 8.8.8.8
```

On **UERANSIM VM 2**, verify UE2's tunnel and generate traffic:

```bash
ip addr show uesimtun0
ping -I uesimtun0 -c 5 8.8.8.8
```

The `-I uesimtun0` option forces the ICMP traffic through the UE's PDU-session tunnel rather than through the VM's ordinary network interface.

For simultaneous testing, start the Core-side GTP-U capture first and then generate traffic from UE1 and UE2.

## 10.3 Validated UE1 N9 trace

A validated UE1 packet sequence was:

```text
3.151885  192.168.56.5,10.60.0.1 -> 192.168.56.41,8.8.8.8  2152 2152  0x00000002
3.151935  10.201.1.2,10.60.0.1   -> 192.168.56.42,8.8.8.8  2152 2152  0x00000002
```

Interpretation:

```text
Inner packet:
10.60.0.1 -> 8.8.8.8

N3 outer tunnel:
192.168.56.5 -> 192.168.56.41
     gNB1            UPF1

N9 outer tunnel:
10.201.1.2 -> 192.168.56.42
 UPF1 namespace      UPF2
```

The same inner UE packet is visible on both hops, demonstrating that UPF1 receives the UE traffic and forwards it toward UPF2.

## 10.4 Simultaneous two-gNB validation

During the simultaneous two-UE test, independent TEIDs were observed:

```text
UE1 / TEID 0x00000002
192.168.56.5,10.60.0.1 -> 192.168.56.41,8.8.8.8
10.201.1.2,10.60.0.1   -> 192.168.56.42,8.8.8.8

UE2 / TEID 0x00000006
192.168.56.6,10.60.0.2 -> 192.168.56.41,8.8.8.8
10.201.1.2,10.60.0.2   -> 192.168.56.42,8.8.8.8
```

The final routing configuration distinguishes the two UE groups as follows:

```text
UE1 topology:      gNB1 -> UPF1 -> UPF2
UE1 specificPath:  none

UE2 topology:      gNB2 -> UPF2
UE2 specificPath:  [UPF2]
```

UE1 relies on the topology-derived default path, while UE2 uses an explicit `specificPath` for traffic destined to `8.8.8.8/32`.

---

# 11. Save a PCAP

Capture both GTP-U and PFCP:

```bash
sudo tshark -i any \
  -f "udp port 2152 or udp port 8805" \
  -w /tmp/working-n9-test.pcap
```

After stopping the capture:

```bash
sudo mv /tmp/working-n9-test.pcap ~/working-n9-test.pcap
sudo chown free5gc_5gcore:free5gc_5gcore ~/working-n9-test.pcap
```

> When capturing with `-i any`, the same packet can appear more than once because Linux sees it on both ingress and egress interfaces. Matching timestamps, TEIDs, inner addresses, and packet contents can be used to identify duplicates.

---

# 12. Troubleshooting record

| Issue | Observed symptom | Cause | Resolution |
|---|---|---|---|
| Incorrect anchor/path selection | SMF selected one UPF and ignored the other | UE1 `specificPath` listed multiple UPFs | Remove `specificPath` from UE1 and let its topology define `gNB1 -> UPF1 -> UPF2` |
| PFCP `retry-out` | SMF could not associate with UPFs | UPFs were not fully running | Fix UPF startup / `gtp5g` first |
| `gtp5g operation not supported` | UPF could not create `upfgtp` | Kernel upgraded and module was missing for the new kernel | Rebuild `gtp5g` for current kernel |
| Overlap CIDR | SMF startup error | Same UE pool configured on both UPFs in SMF | Keep the SMF pool on anchor UPF2 |
| Duplicate capture lines | Every GTP-U packet appeared twice | Capturing on Linux `any` | Treat as one packet observed on multiple interfaces |
| N9 chain not realized as intended | SMF did not preserve both UPFs in the intended order | UE1 was given an unnecessary `specificPath` | Use UE1 topology only; keep `specificPath: [UPF2]` only for UE2 |
| Wrapper says services started but NFs exited | NRF showed NF deregistration | Startup script/process handling | Check `pgrep` and logs instead of trusting the final `echo` |

---

# 13. Verification checklist

| Check | Command / evidence | Expected result |
|---|---|---|
| `gtp5g` loaded | `lsmod \| grep gtp5g` | Module listed |
| UPF1 PFCP | `sudo ip netns exec upf1ns ss -lunp \| grep 8805` | `10.200.1.2:8805` |
| UPF2 PFCP | `sudo ip netns exec upf2ns ss -lunp \| grep 8805` | `10.200.2.2:8805` |
| UPF1 GTP-U | `sudo ip netns exec upf1ns ss -lunp \| grep 2152` | `192.168.56.41:2152` |
| UPF2 GTP-U | `sudo ip netns exec upf2ns ss -lunp \| grep 2152` | `192.168.56.42:2152` |
| SMF associations | PFCP types 5/6 | Both `10.200.1.2` and `10.200.2.2` associated |
| UE1 N3 | `tshark` GTP-U | `192.168.56.5 -> 192.168.56.41` |
| UE1 N9 | `tshark` GTP-U | UPF1 namespace egress -> `192.168.56.42` with same inner packet |
| UE1 routing policy | `uerouting.yaml` | Topology only; no `specificPath` |
| UE2 routing policy | `uerouting.yaml` | `specificPath: [UPF2]` |
| UE2 direct path | final `uerouting.yaml` + `tshark` | `192.168.56.6 -> 192.168.56.42` |

---

# Final status

The Option 3 testbed reached a validated multi-UPF state:

- N4/PFCP association to **UPF1 and UPF2**: validated.
- N3 **gNB1 -> UPF1**: validated.
- N9 **UPF1 -> UPF2**: validated by observing the same inner UE packet across both GTP-U hops.
- Two simultaneous gNB/UE sessions: validated.
- Final intended policy: **UE1 has no `specificPath` and follows `gNB1 -> UPF1 -> UPF2`; UE2 uses `specificPath: [UPF2]` with topology `gNB2 -> UPF2`.**

The key implementation lesson is that UE1's chained forwarding is derived from its **topology** and does not require a `specificPath`. UE2 retains the explicit `specificPath: [UPF2]` rule. Adding a multi-UPF `specificPath` to UE1 caused the SMF to select one UPF and ignore the other rather than preserving the intended chain.

```

The YAML configuration files and PCAP should be copied from the validated testbed so the repository remains a reproducible snapshot of the working configuration.
