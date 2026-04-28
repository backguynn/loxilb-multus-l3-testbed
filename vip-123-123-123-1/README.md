# LoxiLB Multus SCTP/TCP Testbed with External VIP

This directory contains a variant of the L3 Vagrant testbed where the LoadBalancer VIP is moved out of the Multus client subnet and set to 123.123.123.1/32.

The environment still provisions a single-node k3s cluster with Calico, Multus, and LoxiLB, but it adjusts the pod-side routes so that SCTP and TCP traffic can reach the external VIP through LoxiLB while keeping the LoxiLB load-balancing mode at its default behavior.

## Key Differences from the Base Testbed

- LoadBalancer VIP is changed from 10.0.10.254 to 123.123.123.1/32.
- The SCTP/TCP client-side Multus network adds an explicit host route for 123.123.123.1/32 via the LoxiLB client-net IP 10.0.10.50.
- The server-side Multus network adds an explicit host route for 123.123.123.1/32 via the LoxiLB server-net IP 192.168.100.50.
- The server-side route for 10.0.10.0/24 remains directed to LoxiLB so return traffic from the server continues to pass through LoxiLB.
- The Vagrantfile in this directory references the functional test script from the parent project at ../scripts/post-provision-functional-tests.sh.

## Topology

```text
SCTP Client Pod                    TCP Client Pod
  [Multus: 10.0.10.110]             [Multus: 10.0.10.111]
            |                                  |
            | route 123.123.123.1/32 via 10.0.10.50
            v                                  v
LoxiLB
  [client-net: 10.0.10.50]
  [server-net: 192.168.100.50]
  [VIP: 123.123.123.1]
            |
            | route back to 10.0.10.0/24 via LoxiLB
            v
SCTP Server Pod                    TCP Server Pod
  [Multus: 192.168.100.110]         [Multus: 192.168.100.111]
```

## Requirements

- Linux, macOS, or Windows with WSL2
- Vagrant
- VirtualBox or libvirt
- Internet access
- At least 4 vCPUs and 4 GB RAM recommended

## Files in This Directory

- Vagrantfile: provisions the external-VIP variant of the testbed
- README.md: documents the variant-specific behavior
- checks: generated logs after provisioning and validation

## Quick Start

Run all commands from this directory.

```bash
vagrant up
vagrant ssh
sudo /home/vagrant/run-tests.sh
```

The first provisioning run usually takes 10 to 15 minutes depending on download speed.

## Validation

The Vagrantfile in this directory was validated with:

```bash
vagrant validate
```

## Manual Verification

Check the SCTP service VIP:

```bash
kubectl get svc sctp-server-svc
```

Resolve the VIP reported by kube-loxilb:

```bash
LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[ -n "$LB_VIP" ] || LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
LB_VIP=${LB_VIP#llb-}
echo "$LB_VIP"
```

Check the relevant pod routes:

```bash
kubectl exec sctp-client -- ip route
kubectl exec sctp-server -- ip route
```

Run an SCTP client test through the external VIP:

```bash
kubectl exec -it sctp-client -- sctp_darn -H 10.0.10.110 -h ${LB_VIP} -P 36412 -p 36412 -s
```

## Expected Routing Behavior

- Client traffic to 123.123.123.1 is forwarded to LoxiLB over client-net.
- LoxiLB load-balances the connection to the server Pod over server-net.
- Server replies to 10.0.10.0/24 are routed back through LoxiLB, preventing direct server-to-client bypass.
- The setup relies on explicit pod routes rather than placing the VIP inside the client-net subnet.

## Notes

- In kube-loxilb environments, the LoadBalancer VIP may appear as status.loadBalancer.ingress[0].hostname with an llb- prefix instead of appearing in the ip field.
- This variant changes the VIP only; it does not switch the LoxiLB LB rule mode away from the default mode.
- Vagrant may warn about host-only interface addresses ending in .1. That warning does not by itself mean the Vagrantfile is invalid.
