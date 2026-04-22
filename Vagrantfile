# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │                    LoxiLB SCTP Testbed                              │
# │                                                                     │
# │   SCTP Client Pod                                                   │
# │    └─[Multus: 10.0.10.x]──► LoxiLB (VIP: 10.0.10.254)             │
# │                                  └─[Multus: 192.168.100.x]──►      │
# │                                           SCTP Server Pod           │
# │                                                                     │
# │  Stack: k3s + Calico CNI + Multus CNI + LoxiLB                     │
# │  VM:    Ubuntu 24.04, 4 vCPU, 4 GB RAM                             │
# │                                                                     │
# │  Usage:                                                             │
# │    vagrant up                  # Full environment setup (~15 min)   │
# │    vagrant ssh                 # Connect to the VM                  │
# │    vagrant destroy -f          # Destroy the environment            │
# │                                                                     │
# │  Provider: VirtualBox (default) / libvirt                           │
# │    For libvirt: vagrant up --provider=libvirt                       │
# └─────────────────────────────────────────────────────────────────────┘

NODE_IP          = "192.168.56.10"
MULTUS_HOST      = "192.168.100.1"
CLIENT_NET_HOST  = "10.0.10.1"
POD_CIDR         = "10.244.0.0/16"
SVC_CIDR         = "10.96.0.0/12"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Base system setup
# ══════════════════════════════════════════════════════════════════════════════
$setup_system = <<~'SHELL'
  set -euo pipefail
  echo "=== [1/6] System setup ==="

  cat > /etc/modules-load.d/k8s.conf <<EOF
br_netfilter
overlay
sctp
EOF
  modprobe br_netfilter overlay sctp 2>/dev/null || true

  cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system -q

  swapoff -a
  sed -i '/\bswap\b/d' /etc/fstab

  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget git jq iproute2 iputils-ping \
    lksctp-tools netcat-openbsd nmap tcpdump

  KERN=$(uname -r)
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    "linux-modules-extra-${KERN}" 2>/dev/null || true
  modprobe sctp 2>/dev/null || true

  # ── Install standard CNI plugins (macvlan, bandwidth, portmap, etc.) ───
  # Multus looks up macvlan / bandwidth binaries under /opt/cni/bin,
  # so they must be placed before installing k3s / Calico to avoid CNI errors during Pod creation.
  CNI_PLUGINS_VER="v1.4.1"
  CNI_TGZ="/opt/cni/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz"
  mkdir -p /opt/cni/bin
  mkdir -p /opt/cni
  curl -sfL \
    "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VER}/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz" \
    -o "${CNI_TGZ}"
  tar -xzf "${CNI_TGZ}" -C /opt/cni/bin
  echo "CNI plugins installed: $(ls /opt/cni/bin | tr '\n' ' ')"

  echo "=== [1/6] Done ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Install k3s
# Pass k3s options through a config file to avoid quote conflicts inside the heredoc.
# ══════════════════════════════════════════════════════════════════════════════
$install_k3s = <<~'SHELL'
  set -euo pipefail
  echo "=== [2/6] Installing k3s ==="

  NODE_IP="192.168.56.10"
  POD_CIDR="10.244.0.0/16"
  SVC_CIDR="10.96.0.0/12"

  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/config.yaml <<EOF
node-ip: "${NODE_IP}"
advertise-address: "${NODE_IP}"
cluster-cidr: "${POD_CIDR}"
service-cidr: "${SVC_CIDR}"
flannel-backend: "none"
disable-network-policy: true
disable:
  - servicelb
  - traefik
  - local-storage
EOF

  curl -sfL https://get.k3s.io | sh -

  mkdir -p /home/vagrant/.kube
  cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
  sed -i "s|127.0.0.1|${NODE_IP}|g" /home/vagrant/.kube/config
  chown vagrant:vagrant /home/vagrant/.kube/config
  chmod 600 /home/vagrant/.kube/config

  echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" > /etc/profile.d/k3s.sh

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo -n "Waiting for k3s API"
  for i in $(seq 1 60); do
    kubectl get nodes > /dev/null 2>&1 && break
    printf "."
    sleep 3
  done
  echo " done"

  # Add the master node label for LoxiLB nodeSelector compatibility.
  kubectl label node "$(hostname)" node-role.kubernetes.io/master='' --overwrite

  echo "=== [2/6] Done ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Calico CNI (primary CNI)
# ══════════════════════════════════════════════════════════════════════════════
$install_calico = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "=== [3/6] Installing Calico CNI ==="

  POD_CIDR="10.244.0.0/16"
  CALICO_VER="v3.27.3"

  curl -sfL \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml" \
    | sed "s|192\.168\.0\.0/16|${POD_CIDR}|g" \
    | kubectl apply -f -

  echo -n "Waiting for Calico DaemonSet"
  for i in $(seq 1 30); do
    kubectl -n kube-system get ds calico-node > /dev/null 2>&1 && break
    printf "."
    sleep 5
  done
  kubectl -n kube-system rollout status ds/calico-node --timeout=300s

  echo -n "Waiting for node readiness"
  for i in $(seq 1 40); do
    kubectl get nodes | grep -q " Ready" && break
    printf "."
    sleep 5
  done
  echo " done"

  # The default delegate CNI used by Multus reads /opt/cni/bin/*,
  # so only missing files are repaired to avoid overwrite races during reprovisioning.
  CNI_PLUGINS_VER="v1.4.1"
  CNI_TGZ="/opt/cni/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz"
  if [ ! -f "${CNI_TGZ}" ]; then
    curl -sfL \
      "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VER}/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz" \
      -o "${CNI_TGZ}"
  fi

  TMP_CNI_DIR="$(mktemp -d)"
  tar -xzf "${CNI_TGZ}" -C "${TMP_CNI_DIR}"
  for p in macvlan bandwidth portmap host-local loopback bridge; do
    if [ ! -x "/opt/cni/bin/${p}" ] && [ -f "${TMP_CNI_DIR}/${p}" ]; then
      install -m 755 "${TMP_CNI_DIR}/${p}" "/opt/cni/bin/${p}"
    fi
  done
  rm -rf "${TMP_CNI_DIR}"

  if [ ! -x /opt/cni/bin/calico ] || [ ! -x /opt/cni/bin/calico-ipam ]; then
    echo "[INFO] Repairing Calico CNI binaries"

    # 1) First, restore from the k3s current bin path.
    if [ -x /var/lib/rancher/k3s/data/current/bin/calico ] && [ ! -x /opt/cni/bin/calico ]; then
      cp -f /var/lib/rancher/k3s/data/current/bin/calico /opt/cni/bin/calico
    fi
    if [ -x /var/lib/rancher/k3s/data/current/bin/calico-ipam ] && [ ! -x /opt/cni/bin/calico-ipam ]; then
      cp -f /var/lib/rancher/k3s/data/current/bin/calico-ipam /opt/cni/bin/calico-ipam
    fi

    # 2) If still missing, try available paths in the calico-node Pod (/host/opt/cni/bin or /opt/cni/bin).
    if [ ! -x /opt/cni/bin/calico ] || [ ! -x /opt/cni/bin/calico-ipam ]; then
      CALICO_POD=""
      for i in $(seq 1 30); do
        CALICO_POD=$(kubectl -n kube-system get pod -l k8s-app=calico-node \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [ -n "${CALICO_POD}" ] && break
        sleep 2
      done

      if [ -n "${CALICO_POD}" ]; then
        kubectl -n kube-system exec "${CALICO_POD}" -c calico-node -- sh -c \
          'for p in /host/opt/cni/bin/calico /opt/cni/bin/calico; do [ -x "$p" ] && cat "$p" && exit 0; done; exit 1' \
          > /opt/cni/bin/calico || true
        kubectl -n kube-system exec "${CALICO_POD}" -c calico-node -- sh -c \
          'for p in /host/opt/cni/bin/calico-ipam /opt/cni/bin/calico-ipam; do [ -x "$p" ] && cat "$p" && exit 0; done; exit 1' \
          > /opt/cni/bin/calico-ipam || true
      fi
    fi

    # 3) If still missing, restart calico-node so the init container repopulates the host CNI path.
    if [ ! -x /opt/cni/bin/calico ] || [ ! -x /opt/cni/bin/calico-ipam ]; then
      kubectl -n kube-system rollout restart ds/calico-node || true
      kubectl -n kube-system rollout status ds/calico-node --timeout=300s || true
    fi

    [ -f /opt/cni/bin/calico ] && chmod 755 /opt/cni/bin/calico || true
    [ -f /opt/cni/bin/calico-ipam ] && chmod 755 /opt/cni/bin/calico-ipam || true
  else
    echo "[INFO] Calico CNI binaries already present, skipping repair"
  fi

  # Some callers still reference the k3s current bin path, so sync /opt/cni/bin into it.
  K3S_CNI_BIN="/var/lib/rancher/k3s/data/current/bin"
  mkdir -p "${K3S_CNI_BIN}"
  cp -af /opt/cni/bin/* "${K3S_CNI_BIN}/"

  test -x /opt/cni/bin/calico
  test -x /opt/cni/bin/calico-ipam
  test -x /opt/cni/bin/macvlan
  test -x /opt/cni/bin/bandwidth
  test -x /opt/cni/bin/portmap
  echo "Verified CNI binaries: calico/calico-ipam/macvlan/bandwidth/portmap"

  echo "=== [3/6] Done ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Multus CNI + NetworkAttachmentDefinition
# ══════════════════════════════════════════════════════════════════════════════
$install_multus = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "=== [4/6] Installing Multus CNI ==="

  MULTUS_IFACE=$(ip -o addr show | awk '/192\.168\.100\./{print $2}' | head -1)
  if [ -z "${MULTUS_IFACE}" ]; then
    echo "[ERROR] Failed to detect Multus (server-net) interface"
    ip addr show
    exit 1
  fi
  echo "Multus server-net master interface: ${MULTUS_IFACE}"

  CLIENT_IFACE=$(ip -o addr show | awk '/10\.0\.10\./{print $2}' | head -1)
  if [ -z "${CLIENT_IFACE}" ]; then
    echo "[ERROR] Failed to detect Multus (client-net) interface"
    ip addr show
    exit 1
  fi
  echo "Multus client-net master interface: ${CLIENT_IFACE}"

  kubectl apply -f \
    https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.0.2/deployments/multus-daemonset-thick.yml

  # Handle cases where multus daemon logs repeatedly show /opt/cni/bin not found:
  # directly mount host /opt/cni/bin (cnibin volume) into the kube-multus container as well.
  if ! kubectl -n kube-system get ds kube-multus-ds \
      -o jsonpath='{range .spec.template.spec.containers[?(@.name=="kube-multus")].volumeMounts[*]}{.mountPath}{"\n"}{end}' \
      | grep -qx '/opt/cni/bin'; then
    kubectl -n kube-system patch ds kube-multus-ds --type='json' -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "name": "cnibin",
          "mountPath": "/opt/cni/bin",
          "mountPropagation": "HostToContainer"
        }
      }
    ]'
  fi

  # The Multus thick daemon can be OOMKilled with the default memory limit, so raise it.
  kubectl -n kube-system patch ds kube-multus-ds --type='json' -p='[
    {
      "op": "replace",
      "path": "/spec/template/spec/containers/0/resources",
      "value": {
        "requests": {"cpu": "100m", "memory": "128Mi"},
        "limits":   {"cpu": "1",    "memory": "512Mi"}
      }
    }
  ]'

  # Add protection for cases where the Multus service account lacks cluster-scope pod list/watch and triggers reflector errors.
  cat >/tmp/multus-extra-rbac.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: multus-extra-read
rules:
- apiGroups: [""]
  resources: ["pods", "pods/status", "events", "nodes", "namespaces"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: multus-extra-read
subjects:
- kind: ServiceAccount
  name: multus
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: multus-extra-read
EOF
  kubectl apply -f /tmp/multus-extra-rbac.yaml

  echo -n "Waiting for Multus DaemonSet"
  for i in $(seq 1 20); do
    kubectl -n kube-system get ds kube-multus-ds > /dev/null 2>&1 && break
    printf "."
    sleep 5
  done
  kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s
  kubectl -n kube-system rollout restart ds/kube-multus-ds
  kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s

  echo "[INFO] Final CNI binary check from the Multus view"
  CNI_PLUGINS_VER="v1.4.1"
  CNI_TGZ="/opt/cni/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz"
  MISSING=0
  for p in calico calico-ipam macvlan bandwidth portmap; do
    [ -x "/opt/cni/bin/${p}" ] || MISSING=1
  done

  if [ "${MISSING}" -eq 1 ]; then
    echo "[WARN] Missing entries detected in /opt/cni/bin, starting immediate recovery"

    if [ ! -f "${CNI_TGZ}" ]; then
      curl -sfL \
        "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VER}/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz" \
        -o "${CNI_TGZ}"
    fi

    TMP_CNI_DIR="$(mktemp -d)"
    tar -xzf "${CNI_TGZ}" -C "${TMP_CNI_DIR}"
    for p in macvlan bandwidth portmap host-local loopback bridge; do
      [ -f "${TMP_CNI_DIR}/${p}" ] && install -m 755 "${TMP_CNI_DIR}/${p}" "/opt/cni/bin/${p}"
    done
    rm -rf "${TMP_CNI_DIR}"

    CALICO_POD="$(kubectl -n kube-system get pod -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "${CALICO_POD}" ]; then
      kubectl -n kube-system exec "${CALICO_POD}" -c calico-node -- sh -c \
        'for p in /host/opt/cni/bin/calico /opt/cni/bin/calico; do [ -x "$p" ] && cat "$p" && exit 0; done; exit 1' \
        > /opt/cni/bin/calico || true
      kubectl -n kube-system exec "${CALICO_POD}" -c calico-node -- sh -c \
        'for p in /host/opt/cni/bin/calico-ipam /opt/cni/bin/calico-ipam; do [ -x "$p" ] && cat "$p" && exit 0; done; exit 1' \
        > /opt/cni/bin/calico-ipam || true
    fi
    [ -f /opt/cni/bin/calico ] && chmod 755 /opt/cni/bin/calico || true
    [ -f /opt/cni/bin/calico-ipam ] && chmod 755 /opt/cni/bin/calico-ipam || true

    K3S_CNI_BIN="/var/lib/rancher/k3s/data/current/bin"
    mkdir -p "${K3S_CNI_BIN}"
    cp -af /opt/cni/bin/* "${K3S_CNI_BIN}/"

    kubectl -n kube-system rollout restart ds/kube-multus-ds
    kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s
  fi

  MULTUS_POD="$(kubectl -n kube-system get pod -l name=multus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${MULTUS_POD}" ]; then
    kubectl -n kube-system exec "${MULTUS_POD}" -- ls -l \
      /hostroot/opt/cni/bin/calico /hostroot/opt/cni/bin/calico-ipam \
      /hostroot/opt/cni/bin/macvlan /hostroot/opt/cni/bin/bandwidth \
      /hostroot/opt/cni/bin/portmap
  fi
  echo " done"

  # NAD — default namespace (for the SCTP server)
  # Use the LoxiLB IP as the gateway and route the client-net subnet through LoxiLB.
  cat > /tmp/nad-default.yaml <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: multus-net
  namespace: default
spec:
  config: >-
    {
      "cniVersion": "0.3.1",
      "name": "multus-net",
      "type": "macvlan",
      "master": "${MULTUS_IFACE}",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.100.0/24",
        "rangeStart": "192.168.100.100",
        "rangeEnd":   "192.168.100.200",
        "gateway":    "192.168.100.50",
        "routes": [
          {"dst": "10.0.10.0/24", "gw": "192.168.100.50"}
        ]
      }
    }
EOF
  kubectl apply -f /tmp/nad-default.yaml

  # NAD — kube-system namespace (for LoxiLB)
  cat > /tmp/nad-kube-system.yaml <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: multus-net
  namespace: kube-system
spec:
  config: >-
    {
      "cniVersion": "0.3.1",
      "name": "multus-net",
      "type": "macvlan",
      "master": "${MULTUS_IFACE}",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.100.0/24",
        "rangeStart": "192.168.100.50",
        "rangeEnd":   "192.168.100.99",
        "gateway":    "192.168.100.1"
      }
    }
EOF
  kubectl apply -f /tmp/nad-kube-system.yaml

  # NAD — default namespace (client-net for the SCTP client)
  # gateway = LoxiLB IP
  cat > /tmp/nad-client-default.yaml <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: client-net
  namespace: default
spec:
  config: >-
    {
      "cniVersion": "0.3.1",
      "name": "client-net",
      "type": "macvlan",
      "master": "${CLIENT_IFACE}",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "10.0.10.0/24",
        "rangeStart": "10.0.10.100",
        "rangeEnd":   "10.0.10.200",
        "gateway":    "10.0.10.50"
      }
    }
EOF
  kubectl apply -f /tmp/nad-client-default.yaml

  # NAD — kube-system namespace (client-net for LoxiLB)
  cat > /tmp/nad-client-kube-system.yaml <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: client-net
  namespace: kube-system
spec:
  config: >-
    {
      "cniVersion": "0.3.1",
      "name": "client-net",
      "type": "macvlan",
      "master": "${CLIENT_IFACE}",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "10.0.10.0/24",
        "rangeStart": "10.0.10.50",
        "rangeEnd":   "10.0.10.99",
        "gateway":    "10.0.10.1"
      }
    }
EOF
  kubectl apply -f /tmp/nad-client-kube-system.yaml

  echo "=== [4/6] Done ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Deploy LoxiLB
# ══════════════════════════════════════════════════════════════════════════════
$deploy_loxilb = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "=== [5/6] Deploying LoxiLB ==="

  # After applying loxilb.yml, explicitly patch the DaemonSet Pod template with the Multus annotation
  # to avoid sed injection failures or misplaced edits.
  curl -sfL \
    https://raw.githubusercontent.com/loxilb-io/loxilb/main/cicd/k3s-incluster/loxilb.yml \
    | sed 's|hostNetwork: true|hostNetwork: false|g' \
    | kubectl apply -f -

  kubectl -n kube-system patch ds loxilb-lb --type merge -p \
    '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"multus-net\",\"ips\":[\"192.168.100.50/24\"]},{\"name\":\"client-net\",\"ips\":[\"10.0.10.50/24\"]}]"}}}}}'

  echo -n "Waiting for LoxiLB DaemonSet"
  for i in $(seq 1 30); do
    kubectl -n kube-system get ds loxilb-lb > /dev/null 2>&1 && break
    printf "."
    sleep 5
  done
  kubectl -n kube-system rollout status ds/loxilb-lb --timeout=300s
  echo " done"

  # Set the LB VIP to the last IP in the client-net range.
  LB_CIDR="10.0.10.254/32"
  echo "LB_CIDR configured: ${LB_CIDR} (client-net range)"

  curl -sfL \
    https://raw.githubusercontent.com/loxilb-io/loxilb/main/cicd/k3s-incluster/kube-loxilb.yml \
    | sed "s|--cidrPools=defaultPool=.*|--cidrPools=defaultPool=${LB_CIDR}|g" \
    | kubectl apply -f -

  echo -n "Waiting for kube-loxilb controller"
  for i in $(seq 1 20); do
    kubectl -n kube-system get deploy kube-loxilb > /dev/null 2>&1 && break
    printf "."
    sleep 5
  done
  kubectl -n kube-system rollout status deploy/kube-loxilb --timeout=180s
  echo " done"

  echo "=== [5/6] Done ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Deploy SCTP server/client Pods
# The inner heredoc uses 'EOF' (quoted) so YAML is passed as-is without shell variable expansion.
# ══════════════════════════════════════════════════════════════════════════════
$deploy_apps = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "=== [6/6] Deploying SCTP/TCP apps ==="

  # SCTP Server Pod
  cat > /tmp/sctp-server.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: sctp-server
  namespace: default
  labels:
    app: sctp-server
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"multus-net","ips":["192.168.100.110/24"]}]'
spec:
  containers:
  - name: server
    image: ubuntu:24.04
    command:
    - /bin/bash
    - -c
    - |
      apt-get update -qq &&
      apt-get install -y -qq lksctp-tools iproute2 iputils-ping &&
      echo "=== Starting SCTP server ===" &&
      sctp_darn -H 0.0.0.0 -P 36412 -l
    ports:
    - containerPort: 36412
      protocol: SCTP
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
EOF
  kubectl apply -f /tmp/sctp-server.yaml

  # SCTP Server Service
  cat > /tmp/sctp-server-svc.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: sctp-server-svc
  namespace: default
  annotations:
    loxilb.io/multus-nets: "multus-net"
spec:
  selector:
    app: sctp-server
  ports:
  - name: sctp-s1ap
    port: 36412
    protocol: SCTP
    targetPort: 36412
  type: LoadBalancer
EOF
  kubectl apply -f /tmp/sctp-server-svc.yaml

  # SCTP Client Pod
  cat > /tmp/sctp-client.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: sctp-client
  namespace: default
  labels:
    app: sctp-client
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"client-net","ips":["10.0.10.110/24"]}]'
spec:
  containers:
  - name: client
    image: ubuntu:24.04
    command:
    - /bin/bash
    - -c
    - |
      apt-get update -qq &&
      apt-get install -y -qq lksctp-tools iproute2 iputils-ping &&
      echo "=== SCTP client ready ===" &&
      sleep infinity
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
EOF
  kubectl apply -f /tmp/sctp-client.yaml

  # TCP Server Pod
  cat > /tmp/tcp-server.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: tcp-server
  namespace: default
  labels:
    app: tcp-server
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"multus-net","ips":["192.168.100.111/24"]}]'
spec:
  containers:
  - name: server
    image: ubuntu:24.04
    command:
    - /bin/bash
    - -c
    - |
      apt-get update -qq &&
      apt-get install -y -qq socat iproute2 &&
      echo "=== Starting TCP server ===" &&
      socat -d -d TCP-LISTEN:38080,reuseaddr,fork SYSTEM:'/bin/cat'
    ports:
    - containerPort: 38080
      protocol: TCP
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
EOF
  kubectl apply -f /tmp/tcp-server.yaml

  # TCP Server Service
  cat > /tmp/tcp-server-svc.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: tcp-server-svc
  namespace: default
  annotations:
    loxilb.io/multus-nets: "multus-net"
spec:
  selector:
    app: tcp-server
  ports:
  - name: tcp-echo
    port: 38080
    protocol: TCP
    targetPort: 38080
  type: LoadBalancer
EOF
  kubectl apply -f /tmp/tcp-server-svc.yaml

  # TCP Client Pod
  cat > /tmp/tcp-client.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: tcp-client
  namespace: default
  labels:
    app: tcp-client
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"client-net","ips":["10.0.10.111/24"]}]'
spec:
  containers:
  - name: client
    image: ubuntu:24.04
    command:
    - /bin/bash
    - -c
    - |
      apt-get update -qq &&
      apt-get install -y -qq netcat-openbsd iproute2 iputils-ping &&
      echo "=== TCP client ready ===" &&
      sleep infinity
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
EOF
  kubectl apply -f /tmp/tcp-client.yaml

  wait_pod_or_fail_fast() {
    local pod_name="$1"
    local namespace="default"
    local timeout_sec=300
    local elapsed=0

    echo -n "Waiting for ${pod_name}"
    while [ "${elapsed}" -lt "${timeout_sec}" ]; do
      local ready
      ready=$(kubectl -n "${namespace}" get pod "${pod_name}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

      if [ "${ready}" = "True" ]; then
        echo " ready"
        return 0
      fi

      # Fail fast only on permanent errors such as ImagePull failures or missing CNI plugins.
      # FailedCreatePodSandBox / failed to setup network can be caused by transient Multus daemon instability,
      # so retries are allowed in those cases.
      if kubectl -n "${namespace}" describe pod "${pod_name}" 2>/dev/null | \
          grep -Eqi 'failed to find plugin|ImagePullBackOff|ErrImagePull'; then
        echo " [FAIL] aborting early"
        echo "----- describe pod/${pod_name} -----"
        kubectl -n "${namespace}" describe pod "${pod_name}" || true
        echo "----- recent events (default ns) -----"
        kubectl -n "${namespace}" get events --sort-by=.lastTimestamp | tail -n 60 || true
        return 1
      fi

      printf "."
      sleep 3
      elapsed=$((elapsed + 3))
    done

    echo " [FAIL] timeout"
    echo "----- describe pod/${pod_name} -----"
    kubectl -n "${namespace}" describe pod "${pod_name}" || true
    echo "----- recent events (default ns) -----"
    kubectl -n "${namespace}" get events --sort-by=.lastTimestamp | tail -n 60 || true
    return 1
  }

  wait_pod_or_fail_fast "sctp-server"
  wait_pod_or_fail_fast "sctp-client"
  wait_pod_or_fail_fast "tcp-server"
  wait_pod_or_fail_fast "tcp-client"

  echo ""
  echo "=================================================="
  echo " Testbed setup complete!"
  echo "=================================================="
  kubectl get nodes -o wide
  echo ""
  kubectl get pods -o wide
  echo ""
  kubectl get svc
  echo ""
  echo "=================================================="
  echo " How to test (after vagrant ssh)"
  echo "=================================================="
  echo " # Check VIP"
  echo " kubectl get svc sctp-server-svc"
  echo ""
  echo " # Check server Multus IP"
  echo " kubectl exec sctp-server -- ip addr show net1"
  echo ""
  echo " # SCTP connectivity test"
  echo ' LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='"'"'{.status.loadBalancer.ingress[0].ip}'"'"' 2>/dev/null || true); [ -n "$LB_VIP" ] || LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='"'"'{.status.loadBalancer.ingress[0].hostname}'"'"' 2>/dev/null || true); LB_VIP=${LB_VIP#llb-}'
  echo " # Use the client's client-net IP (net1) as the source"
  echo " kubectl exec -it sctp-client -- sctp_darn -H 10.0.10.110 -h \${LB_VIP} -P 36412 -p 36412 -s"
  echo ""
  echo " # Check LoxiLB rules"
  echo ' LOXILB_POD=$(kubectl get pods -n kube-system -l app=loxilb-app -o jsonpath='"'"'{.items[0].metadata.name}'"'"')'
  echo " kubectl exec -n kube-system \${LOXILB_POD} -- loxicmd get lb"
  echo "=================================================="
  echo "=== [6/6] Done ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Deployment verification and report export (/vagrant/checks)
# Results can be inspected from outside the VM on the host.
# ══════════════════════════════════════════════════════════════════════════════
$verify_deploy = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  REPORT_DIR="/vagrant/checks"
  TS="$(date +%Y%m%d-%H%M%S)"
  REPORT_FILE="${REPORT_DIR}/multus-loxilb-check-${TS}.log"
  SUMMARY_FILE="${REPORT_DIR}/latest-summary.env"
  LATEST_FILE="${REPORT_DIR}/latest.log"
  DIAG_TS_FILE="${REPORT_DIR}/multus-loxilb-diagnosis-${TS}.txt"
  DIAG_FILE="${REPORT_DIR}/latest-diagnosis.txt"

  mkdir -p "${REPORT_DIR}"
  exec > >(tee -a "${REPORT_FILE}") 2>&1

  echo "=== [7/7] Deployment verification start ==="
  echo "time=${TS}"

  FAIL_COUNT=0

  check_ok() {
    local key="$1"
    local value="$2"
    if [ "${value}" = "PASS" ]; then
      echo "[PASS] ${key}"
    else
      echo "[FAIL] ${key}"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    printf "%s=%s\n" "${key}" "${value}" >> "${SUMMARY_FILE}"
  }

  : > "${SUMMARY_FILE}"
  printf "REPORT_FILE=%s\n" "${REPORT_FILE}" >> "${SUMMARY_FILE}"

  echo "\n[1] Check CNI binaries"
  CALICO_BIN="FAIL"
  STD_CNI_BIN="FAIL"
  K3S_CNI_SYNC="FAIL"
  MULTUS_VIEW_CNI="FAIL"

  if [ -x /opt/cni/bin/calico ] && [ -x /opt/cni/bin/calico-ipam ]; then
    CALICO_BIN="PASS"
  fi
  if [ -x /opt/cni/bin/macvlan ] && [ -x /opt/cni/bin/bandwidth ] && [ -x /opt/cni/bin/portmap ]; then
    STD_CNI_BIN="PASS"
  fi
  if [ -x /var/lib/rancher/k3s/data/current/bin/calico ] && [ -x /var/lib/rancher/k3s/data/current/bin/macvlan ]; then
    K3S_CNI_SYNC="PASS"
  fi

  ls -l /opt/cni/bin/calico /opt/cni/bin/calico-ipam /opt/cni/bin/macvlan /opt/cni/bin/bandwidth /opt/cni/bin/portmap 2>/dev/null || true
  ls -l /var/lib/rancher/k3s/data/current/bin/calico /var/lib/rancher/k3s/data/current/bin/macvlan 2>/dev/null || true
  check_ok "CALICO_BIN" "${CALICO_BIN}"
  check_ok "STD_CNI_BIN" "${STD_CNI_BIN}"
  check_ok "K3S_CNI_SYNC" "${K3S_CNI_SYNC}"

  MULTUS_POD_CHECK="$(kubectl -n kube-system get pod -l name=multus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${MULTUS_POD_CHECK}" ] \
    && kubectl -n kube-system exec "${MULTUS_POD_CHECK}" -- test -x /hostroot/opt/cni/bin/calico \
    && kubectl -n kube-system exec "${MULTUS_POD_CHECK}" -- test -x /hostroot/opt/cni/bin/macvlan \
    && kubectl -n kube-system exec "${MULTUS_POD_CHECK}" -- test -x /hostroot/opt/cni/bin/bandwidth; then
    MULTUS_VIEW_CNI="PASS"
  fi
  check_ok "MULTUS_VIEW_CNI" "${MULTUS_VIEW_CNI}"

  echo "\n[2] Kubernetes resource status"
  kubectl get nodes -o wide || true
  kubectl get pods -A -o wide || true
  kubectl get net-attach-def -A || true

  echo "\n[3] Check LoxiLB Multus annotation"
  LOXI_DS_NETS="$(kubectl -n kube-system get ds loxilb-lb -o jsonpath='{.spec.template.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks}' 2>/dev/null || true)"
  echo "loxilb ds annotation: ${LOXI_DS_NETS}"
  if echo "${LOXI_DS_NETS}" | grep -q "multus-net" && echo "${LOXI_DS_NETS}" | grep -q "client-net" && echo "${LOXI_DS_NETS}" | grep -q "192.168.100.50" && echo "${LOXI_DS_NETS}" | grep -q "10.0.10.50"; then
    check_ok "LOXILB_DS_MULTUS_ANNOTATION" "PASS"
  else
    check_ok "LOXILB_DS_MULTUS_ANNOTATION" "FAIL"
  fi

  echo "\n[4] Check Pod net1 interface"
  SCTP_SERVER_NET1="FAIL"
  for i in $(seq 1 10); do
    if kubectl exec sctp-server -- ip -o -4 addr show dev net1 >/dev/null 2>&1; then
      SCTP_SERVER_NET1="PASS"
      break
    fi
    sleep 2
  done
  kubectl exec sctp-server -- ip -o -4 addr show dev net1 2>/dev/null || true
  check_ok "SCTP_SERVER_NET1" "${SCTP_SERVER_NET1}"

  SCTP_CLIENT_NET1="FAIL"
  for i in $(seq 1 10); do
    if kubectl exec sctp-client -- ip -o -4 addr show dev net1 >/dev/null 2>&1; then
      SCTP_CLIENT_NET1="PASS"
      break
    fi
    sleep 2
  done
  kubectl exec sctp-client -- ip -o -4 addr show dev net1 2>/dev/null || true
  check_ok "SCTP_CLIENT_NET1" "${SCTP_CLIENT_NET1}"

  LOXI_POD="$(kubectl -n kube-system get pods -l app=loxilb-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  LOXILB_POD_NET1="FAIL"
  LOXILB_POD_NET2="FAIL"
  if [ -n "${LOXI_POD}" ]; then
    # net1 = multus-net (192.168.100.x), net2 = client-net (10.0.10.x)
    if kubectl -n kube-system exec "${LOXI_POD}" -- ip -o -4 addr show dev net1 >/dev/null 2>&1; then
      LOXILB_POD_NET1="PASS"
    fi
    if kubectl -n kube-system exec "${LOXI_POD}" -- ip -o -4 addr show dev net2 >/dev/null 2>&1; then
      LOXILB_POD_NET2="PASS"
    fi
    kubectl -n kube-system exec "${LOXI_POD}" -- ip -o -4 addr 2>/dev/null || true
  fi
  check_ok "LOXILB_POD_NET1" "${LOXILB_POD_NET1}"
  check_ok "LOXILB_POD_NET2" "${LOXILB_POD_NET2}"

  echo "\n[5] Recent network-related warning events"
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null \
    | grep -E "FailedCreatePodSandBox|failed to find plugin|multus-shim|calico" || true

  echo "\n[6] Check Multus RBAC"
  MULTUS_RBAC="FAIL"
  if kubectl auth can-i --as=system:serviceaccount:kube-system:multus list pods --all-namespaces >/dev/null 2>&1; then
    MULTUS_RBAC="PASS"
  fi
  kubectl auth can-i --as=system:serviceaccount:kube-system:multus list pods --all-namespaces || true
  check_ok "MULTUS_RBAC" "${MULTUS_RBAC}"

  if [ "${FAIL_COUNT}" -eq 0 ]; then
    OVERALL="PASS"
  else
    OVERALL="FAIL"
  fi
  printf "OVERALL=%s\n" "${OVERALL}" >> "${SUMMARY_FILE}"

  # Generate a cause/action guide per failed item from latest-summary.env.
  {
    echo "# Multus/LoxiLB automated diagnosis"
    echo "time=${TS}"
    echo "overall=${OVERALL}"
    echo ""

    if [ "${OVERALL}" = "PASS" ]; then
      echo "All checks passed."
      echo "No additional action is required."
    else
      # shellcheck disable=SC1090
      . "${SUMMARY_FILE}"

      echo "Guide by failed item:"
      echo ""

      if [ "${CALICO_BIN:-FAIL}" != "PASS" ]; then
        echo "[CALICO_BIN]"
        echo "- Cause: Missing calico or calico-ipam binaries under /opt/cni/bin"
        echo "- Impact: FailedCreatePodSandBox can occur when Multus calls the default delegate CNI"
        echo "- Action: Restore /opt/cni/bin/calico* from the calico-node Pod and apply chmod 755"
        echo ""
      fi

      if [ "${STD_CNI_BIN:-FAIL}" != "PASS" ]; then
        echo "[STD_CNI_BIN]"
        echo "- Cause: Missing standard CNI binaries macvlan/bandwidth/portmap under /opt/cni/bin"
        echo "- Impact: Multus DEL/ADD steps can fail when invoking macvlan or bandwidth plugins"
        echo "- Action: Re-extract the containernetworking/plugins tgz and verify binary permissions"
        echo ""
      fi

      if [ "${K3S_CNI_SYNC:-FAIL}" != "PASS" ]; then
        echo "[K3S_CNI_SYNC]"
        echo "- Cause: Plugin mismatch between /opt/cni/bin and /var/lib/rancher/k3s/data/current/bin"
        echo "- Impact: Intermittent failures can occur because plugin lookup paths differ by caller"
        echo "- Action: Sync /opt/cni/bin into the k3s current bin path"
        echo ""
      fi

      if [ "${MULTUS_VIEW_CNI:-FAIL}" != "PASS" ]; then
        echo "[MULTUS_VIEW_CNI]"
        echo "- Cause: CNI binaries exist on the VM but are not visible from the Multus Pod (/hostroot)"
        echo "- Impact: multus ADD/DEL can fail with macvlan/bandwidth/calico not found errors"
        echo "- Action: Restart kube-multus-ds and re-check /hostroot/opt/cni/bin"
        echo ""
      fi

      if [ "${LOXILB_DS_MULTUS_ANNOTATION:-FAIL}" != "PASS" ]; then
        echo "[LOXILB_DS_MULTUS_ANNOTATION]"
        echo "- Cause: Multus networks annotation is missing from the loxilb DaemonSet Pod template"
        echo "- Impact: The loxilb Pod does not get a net1 interface"
        echo "- Action: Patch ds/loxilb-lb with k8s.v1.cni.cncf.io/networks=multus-net"
        echo ""
      fi

      if [ "${SCTP_SERVER_NET1:-FAIL}" != "PASS" ]; then
        echo "[SCTP_SERVER_NET1]"
        echo "- Cause: Multus attachment failed for the sctp-server Pod or the NAD configuration does not match"
        echo "- Impact: The server cannot receive traffic on the multus range (192.168.100.0/24)"
        echo "- Action: Re-check the Pod annotation, NAD(default/multus-net), and Multus DaemonSet status"
        echo ""
      fi

      if [ "${LOXILB_POD_NET1:-FAIL}" != "PASS" ]; then
        echo "[LOXILB_POD_NET1]"
        echo "- Cause: Multus attachment failed for the loxilb Pod or the kube-system NAD is missing"
        echo "- Impact: The loxilb -> server path (multus-net) is not formed"
        echo "- Action: Check NAD(kube-system/multus-net), restart the loxilb Pod, and inspect events"
        echo ""
      fi

      if [ "${LOXILB_POD_NET2:-FAIL}" != "PASS" ]; then
        echo "[LOXILB_POD_NET2]"
        echo "- Cause: client-net Multus attachment failed on the loxilb Pod"
        echo "- Impact: The client -> loxilb path (client-net) is not formed"
        echo "- Action: Check NAD(kube-system/client-net), verify the loxilb DS annotation, and inspect events"
        echo ""
      fi

      if [ "${SCTP_CLIENT_NET1:-FAIL}" != "PASS" ]; then
        echo "[SCTP_CLIENT_NET1]"
        echo "- Cause: client-net Multus attachment failed on the sctp-client Pod"
        echo "- Impact: The client cannot reach the LB VIP through the client-net range (10.0.10.0/24)"
        echo "- Action: Re-check the Pod annotation, NAD(default/client-net), and Multus DaemonSet status"
        echo ""
      fi

      if [ "${MULTUS_RBAC:-FAIL}" != "PASS" ]; then
        echo "[MULTUS_RBAC]"
        echo "- Cause: system:serviceaccount:kube-system:multus lacks cluster-scope pod list/watch permissions"
        echo "- Impact: Multus reflector errors persist and status tracking/cleanup logic becomes unstable"
        echo "- Action: Add a ClusterRoleBinding granting the Multus SA get/list/watch on pods/events/nodes/namespaces"
        echo ""
      fi

      echo "Recommended verification commands:"
      echo "- kubectl get net-attach-def -A"
      echo "- kubectl -n kube-system describe ds loxilb-lb"
      echo "- kubectl describe pod sctp-server"
      echo "- kubectl get events -A --sort-by=.lastTimestamp | tail -n 80"
    fi
  } > "${DIAG_TS_FILE}"

  cp -f "${REPORT_FILE}" "${LATEST_FILE}"
  cp -f "${DIAG_TS_FILE}" "${DIAG_FILE}"
  echo "${REPORT_FILE}" > "${REPORT_DIR}/latest-path.txt"

  echo "\n=== [7/7] Deployment verification complete: ${OVERALL} ==="
  echo "host log path: ${LATEST_FILE}"
  echo "host summary path: ${SUMMARY_FILE}"
  echo "host diagnosis path: ${DIAG_FILE}"
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# Vagrant configuration
# ══════════════════════════════════════════════════════════════════════════════
Vagrant.configure("2") do |config|

  config.vm.define "loxilb-k8s" do |node|
    node.vm.box      = "bento/ubuntu-24.04"
    node.vm.hostname = "loxilb-k8s"

    # eth1: Kubernetes management network (k3s advertise-address)
    node.vm.network "private_network", ip: NODE_IP

    # eth2: Multus server-net (macvlan master, LoxiLB ↔ SCTP Server)
    node.vm.network "private_network",
      ip:                 MULTUS_HOST,
      virtualbox__intnet: "multus-net"

    # eth3: Multus client-net (macvlan master, SCTP Client ↔ LoxiLB)
    node.vm.network "private_network",
      ip:                 CLIENT_NET_HOST,
      virtualbox__intnet: "client-net"

    node.vm.provider "virtualbox" do |vb|
      vb.name   = "loxilb-k8s"
      vb.memory = 4096
      vb.cpus   = 4
      vb.gui    = false
      # Promiscuous mode is required for macvlan to work.
      vb.customize ["modifyvm", :id, "--nicpromisc3", "allow-all"]  # eth2 (server-net)
      vb.customize ["modifyvm", :id, "--nicpromisc4", "allow-all"]  # eth3 (client-net)
      vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
    end

    node.vm.provider "libvirt" do |lv|
      lv.memory = 4096
      lv.cpus   = 4
      lv.driver = "kvm"
    end

    node.vm.provision "shell", name: "1-system", inline: $setup_system
    node.vm.provision "shell", name: "2-k3s",    inline: $install_k3s
    node.vm.provision "shell", name: "3-calico", inline: $install_calico
    node.vm.provision "shell", name: "4-multus", inline: $install_multus
    node.vm.provision "shell", name: "5-loxilb", inline: $deploy_loxilb
    node.vm.provision "shell", name: "6-apps",   inline: $deploy_apps
    node.vm.provision "shell", name: "7-verify", inline: $verify_deploy
    # Test script: run automatically during provision and install as /home/vagrant/run-tests.sh inside the VM.
    node.vm.provision "shell", name: "8-functional-tests", path: "scripts/post-provision-functional-tests.sh"
    node.vm.provision "shell", name: "9-test-script-hint", inline: <<~'HINT'
      echo ""
      echo "════════════════════════════════════════════════════════════════"
      echo " Re-run tests inside the VM:"
      echo "   vagrant ssh"
      echo "   sudo /home/vagrant/run-tests.sh"
      echo "════════════════════════════════════════════════════════════════"
    HINT
  end
end
