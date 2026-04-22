# LoxiLB Multus SCTP/TCP Vagrant Testbed

This project is a Vagrant-based testbed that provisions k3s, Calico, Multus, and LoxiLB inside a single VM and runs SCTP/TCP end-to-end checks automatically.

## What It Includes

- Single-node k3s cluster
- Calico as the primary CNI
- Multus as the secondary CNI
- LoxiLB and kube-loxilb
- SCTP/TCP client and server Pods with LoadBalancer Services
- Automated functional test script

## Requirements

- Linux, macOS, or Windows with WSL2
- Vagrant
- VirtualBox or libvirt
- Internet access
- At least 4 vCPUs and 4 GB RAM recommended

## Project Layout

- [Vagrantfile](Vagrantfile): full environment provisioning and app deployment
- [scripts/post-provision-functional-tests.sh](scripts/post-provision-functional-tests.sh): post-provision functional test runner
- [checks](checks): generated diagnosis and test logs

## Quick Start

```bash
vagrant up
vagrant ssh
sudo /home/vagrant/run-tests.sh
```

The first build usually takes about 10 to 15 minutes depending on network speed.

## Test Scenarios

Topology used by the functional tests:

```text
SCTP Client Pod                    TCP Client Pod
  [Multus: 10.0.10.110]             [Multus: 10.0.10.111]
            |                                  |
            v                                  v
LoxiLB                               LoxiLB
  [client-net: 10.0.10.50]             [client-net: 10.0.10.50]
  [server-net: 192.168.100.50]         [server-net: 192.168.100.50]
  [VIP: 10.0.10.254]                   [VIP: 10.0.10.254]
            |                                  |
            v                                  v
SCTP Server Pod                    TCP Server Pod
  [Multus: 192.168.100.110]         [Multus: 192.168.100.111]
```

The functional test script checks the following items:

1. Multus interface attachment
2. Server routing toward the client-net subnet
3. L2 ping reachability between Pods and LoxiLB
4. LoxiLB load-balancing rule creation
5. SCTP client -> VIP -> LoxiLB -> server E2E connectivity
6. TCP client -> VIP -> LoxiLB -> server E2E connectivity

## Result Files

- Latest functional test log: [checks/latest-functional-tests.log](checks/latest-functional-tests.log)
- Latest deployment diagnosis log: [checks/latest-diagnosis.txt](checks/latest-diagnosis.txt)
- Re-run functional tests inside the VM with `sudo /home/vagrant/run-tests.sh`

## Manual Verification Example

```bash
kubectl get svc sctp-server-svc
kubectl exec sctp-server -- ip addr show net1

LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[ -n "$LB_VIP" ] || LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
LB_VIP=${LB_VIP#llb-}

kubectl exec -it sctp-client -- sctp_darn -H 10.0.10.110 -h ${LB_VIP} -P 36412 -p 36412 -s
```

## Notes

- In kube-loxilb environments, the LoadBalancer VIP may appear in `status.loadBalancer.ingress[0].hostname` as `llb-10.0.10.254` instead of the `ip` field.
- The functional test script already handles that case.