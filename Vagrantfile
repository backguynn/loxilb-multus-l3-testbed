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
# │    vagrant up                  # 전체 환경 구성 (~15분)             │
# │    vagrant ssh                 # VM 접속                            │
# │    vagrant destroy -f          # 환경 삭제                          │
# │                                                                     │
# │  Provider: VirtualBox (기본) / libvirt                              │
# │    libvirt 사용 시: vagrant up --provider=libvirt                   │
# └─────────────────────────────────────────────────────────────────────┘

NODE_IP          = "192.168.56.10"
MULTUS_HOST      = "192.168.100.1"
CLIENT_NET_HOST  = "10.0.10.1"
POD_CIDR         = "10.244.0.0/16"
SVC_CIDR         = "10.96.0.0/12"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — 시스템 기본 설정
# ══════════════════════════════════════════════════════════════════════════════
$setup_system = <<~'SHELL'
  set -euo pipefail
  echo "=== [1/6] 시스템 설정 ==="

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

  # ── 표준 CNI 플러그인 설치 (macvlan, bandwidth, portmap 등) ──────────────
  # Multus가 /opt/cni/bin 에서 macvlan / bandwidth 바이너리를 찾으므로
  # k3s / Calico 설치 전에 미리 배치해야 Pod 생성 시 CNI 오류가 발생하지 않음
  CNI_PLUGINS_VER="v1.4.1"
  CNI_TGZ="/opt/cni/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz"
  mkdir -p /opt/cni/bin
  mkdir -p /opt/cni
  curl -sfL \
    "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VER}/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz" \
    -o "${CNI_TGZ}"
  tar -xzf "${CNI_TGZ}" -C /opt/cni/bin
  echo "CNI 플러그인 설치 완료: $(ls /opt/cni/bin | tr '\n' ' ')"

  echo "=== [1/6] 완료 ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — k3s 설치
# k3s 옵션을 config 파일로 전달 → heredoc 내 따옴표 충돌 없음
# ══════════════════════════════════════════════════════════════════════════════
$install_k3s = <<~'SHELL'
  set -euo pipefail
  echo "=== [2/6] k3s 설치 ==="

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
  echo -n "k3s API 대기 중"
  for i in $(seq 1 60); do
    kubectl get nodes > /dev/null 2>&1 && break
    printf "."
    sleep 3
  done
  echo " 완료"

  # master 노드 라벨 추가 (LoxiLB nodeSelector 호환)
  kubectl label node "$(hostname)" node-role.kubernetes.io/master='' --overwrite

  echo "=== [2/6] 완료 ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Calico CNI (primary CNI)
# ══════════════════════════════════════════════════════════════════════════════
$install_calico = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "=== [3/6] Calico CNI 설치 ==="

  POD_CIDR="10.244.0.0/16"
  CALICO_VER="v3.27.3"

  curl -sfL \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml" \
    | sed "s|192\.168\.0\.0/16|${POD_CIDR}|g" \
    | kubectl apply -f -

  echo -n "Calico DaemonSet 대기 중"
  for i in $(seq 1 30); do
    kubectl -n kube-system get ds calico-node > /dev/null 2>&1 && break
    printf "."
    sleep 5
  done
  kubectl -n kube-system rollout status ds/calico-node --timeout=300s

  echo -n "Node Ready 대기 중"
  for i in $(seq 1 40); do
    kubectl get nodes | grep -q " Ready" && break
    printf "."
    sleep 5
  done
  echo " 완료"

  # Multus 기본(delegate) CNI가 /opt/cni/bin/* 를 참조하므로,
  # provision 재실행 중 덮어쓰기 레이스를 피하기 위해 누락 파일만 보강한다.
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
    echo "[INFO] Calico CNI 바이너리 보강 진행"

    # 1) k3s current bin 경로에서 우선 복구
    if [ -x /var/lib/rancher/k3s/data/current/bin/calico ] && [ ! -x /opt/cni/bin/calico ]; then
      cp -f /var/lib/rancher/k3s/data/current/bin/calico /opt/cni/bin/calico
    fi
    if [ -x /var/lib/rancher/k3s/data/current/bin/calico-ipam ] && [ ! -x /opt/cni/bin/calico-ipam ]; then
      cp -f /var/lib/rancher/k3s/data/current/bin/calico-ipam /opt/cni/bin/calico-ipam
    fi

    # 2) 여전히 없으면 calico-node pod에서 가능한 경로(/host/opt/cni/bin 또는 /opt/cni/bin)로 시도
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

    # 3) 그래도 없으면 calico-node를 재시작해 init-container가 다시 host CNI 경로를 채우게 한다.
    if [ ! -x /opt/cni/bin/calico ] || [ ! -x /opt/cni/bin/calico-ipam ]; then
      kubectl -n kube-system rollout restart ds/calico-node || true
      kubectl -n kube-system rollout status ds/calico-node --timeout=300s || true
    fi

    [ -f /opt/cni/bin/calico ] && chmod 755 /opt/cni/bin/calico || true
    [ -f /opt/cni/bin/calico-ipam ] && chmod 755 /opt/cni/bin/calico-ipam || true
  else
    echo "[INFO] Calico CNI 바이너리 이미 존재하여 보강 생략"
  fi

  # k3s current bin 경로를 참조하는 경우도 있어 /opt/cni/bin 내용을 동기화한다.
  K3S_CNI_BIN="/var/lib/rancher/k3s/data/current/bin"
  mkdir -p "${K3S_CNI_BIN}"
  cp -af /opt/cni/bin/* "${K3S_CNI_BIN}/"

  test -x /opt/cni/bin/calico
  test -x /opt/cni/bin/calico-ipam
  test -x /opt/cni/bin/macvlan
  test -x /opt/cni/bin/bandwidth
  test -x /opt/cni/bin/portmap
  echo "CNI 바이너리 확인 완료: calico/calico-ipam/macvlan/bandwidth/portmap"

  echo "=== [3/6] 완료 ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Multus CNI + NetworkAttachmentDefinition
# ══════════════════════════════════════════════════════════════════════════════
$install_multus = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "=== [4/6] Multus CNI 설치 ==="

  MULTUS_IFACE=$(ip -o addr show | awk '/192\.168\.100\./{print $2}' | head -1)
  if [ -z "${MULTUS_IFACE}" ]; then
    echo "[ERROR] Multus(server-net) 인터페이스 감지 실패"
    ip addr show
    exit 1
  fi
  echo "Multus server-net master 인터페이스: ${MULTUS_IFACE}"

  CLIENT_IFACE=$(ip -o addr show | awk '/10\.0\.10\./{print $2}' | head -1)
  if [ -z "${CLIENT_IFACE}" ]; then
    echo "[ERROR] Multus(client-net) 인터페이스 감지 실패"
    ip addr show
    exit 1
  fi
  echo "Multus client-net master 인터페이스: ${CLIENT_IFACE}"

  kubectl apply -f \
    https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.0.2/deployments/multus-daemonset-thick.yml

  # multus daemon 로그에 /opt/cni/bin not found가 반복되는 케이스 대응:
  # kube-multus 컨테이너에도 host /opt/cni/bin(cnibin volume)을 직접 마운트한다.
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

  # Multus thick 데몬은 기본 메모리 limit이 낮아 OOMKilled 될 수 있다. 상향 조정.
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

  # multus 서비스어카운트가 cluster-scope pod list/watch를 못해 reflector 에러가 나는 케이스 보강
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

  echo -n "Multus DaemonSet 대기 중"
  for i in $(seq 1 20); do
    kubectl -n kube-system get ds kube-multus-ds > /dev/null 2>&1 && break
    printf "."
    sleep 5
  done
  kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s
  kubectl -n kube-system rollout restart ds/kube-multus-ds
  kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s

  echo "[INFO] Multus 관점 CNI 바이너리 최종 점검"
  CNI_PLUGINS_VER="v1.4.1"
  CNI_TGZ="/opt/cni/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz"
  MISSING=0
  for p in calico calico-ipam macvlan bandwidth portmap; do
    [ -x "/opt/cni/bin/${p}" ] || MISSING=1
  done

  if [ "${MISSING}" -eq 1 ]; then
    echo "[WARN] /opt/cni/bin 누락 감지, 즉시 복구 진행"

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
  echo " 완료"

  # NAD — default 네임스페이스 (SCTP Server용)
  # gateway=LoxiLB IP, route로 client-net 대역을 LoxiLB 경유하도록 설정
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

  # NAD — kube-system 네임스페이스 (LoxiLB용)
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

  # NAD — default 네임스페이스 (SCTP Client용 client-net)
  # gateway=LoxiLB IP
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

  # NAD — kube-system 네임스페이스 (LoxiLB용 client-net)
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

  echo "=== [4/6] 완료 ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — LoxiLB 배포
# ══════════════════════════════════════════════════════════════════════════════
$deploy_loxilb = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "=== [5/6] LoxiLB 배포 ==="

  # loxilb.yml 적용 후 DaemonSet pod template에 Multus 어노테이션을 명시적으로 patch
  # (sed 주입 실패/위치 오류를 방지)
  curl -sfL \
    https://raw.githubusercontent.com/loxilb-io/loxilb/main/cicd/k3s-incluster/loxilb.yml \
    | sed 's|hostNetwork: true|hostNetwork: false|g' \
    | kubectl apply -f -

  kubectl -n kube-system patch ds loxilb-lb --type merge -p \
    '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"multus-net\",\"ips\":[\"192.168.100.50/24\"]},{\"name\":\"client-net\",\"ips\":[\"10.0.10.50/24\"]}]"}}}}}'

  echo -n "LoxiLB DaemonSet 대기 중"
  for i in $(seq 1 30); do
    kubectl -n kube-system get ds loxilb-lb > /dev/null 2>&1 && break
    printf "."
    sleep 5
  done
  kubectl -n kube-system rollout status ds/loxilb-lb --timeout=300s
  echo " 완료"

  # LB VIP를 client-net 대역의 마지막 IP로 설정
  LB_CIDR="10.0.10.254/32"
  echo "LB_CIDR 설정: ${LB_CIDR} (client-net 대역)"

  curl -sfL \
    https://raw.githubusercontent.com/loxilb-io/loxilb/main/cicd/k3s-incluster/kube-loxilb.yml \
    | sed "s|--cidrPools=defaultPool=.*|--cidrPools=defaultPool=${LB_CIDR}|g" \
    | kubectl apply -f -

  echo -n "kube-loxilb 컨트롤러 대기 중"
  for i in $(seq 1 20); do
    kubectl -n kube-system get deploy kube-loxilb > /dev/null 2>&1 && break
    printf "."
    sleep 5
  done
  kubectl -n kube-system rollout status deploy/kube-loxilb --timeout=180s
  echo " 완료"

  echo "=== [5/6] 완료 ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — SCTP Server / Client Pod 배포
# 내부 heredoc은 'EOF' (따옴표 있음) → 셸 변수 확장 없이 YAML 그대로 전달
# ══════════════════════════════════════════════════════════════════════════════
$deploy_apps = <<~'SHELL'
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "=== [6/6] SCTP/TCP 앱 배포 ==="

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
      echo "=== SCTP Server 시작 ===" &&
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
      echo "=== SCTP Client 준비 완료 ===" &&
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
      echo "=== TCP Server 시작 ===" &&
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
      echo "=== TCP Client 준비 완료 ===" &&
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

    echo -n "${pod_name} 대기 중"
    while [ "${elapsed}" -lt "${timeout_sec}" ]; do
      local ready
      ready=$(kubectl -n "${namespace}" get pod "${pod_name}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

      if [ "${ready}" = "True" ]; then
        echo " 완료"
        return 0
      fi

      # ImagePull 오류, CNI 플러그인 누락 등 영구 오류만 즉시 실패
      # FailedCreatePodSandBox / failed to setup network 는 Multus 데몬
      # 일시 불안정으로 발생할 수 있으므로 재시도를 허용한다.
      if kubectl -n "${namespace}" describe pod "${pod_name}" 2>/dev/null | \
          grep -Eqi 'failed to find plugin|ImagePullBackOff|ErrImagePull'; then
        echo " [FAIL] 즉시 종료"
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
  echo " Testbed 구성 완료!"
  echo "=================================================="
  kubectl get nodes -o wide
  echo ""
  kubectl get pods -o wide
  echo ""
  kubectl get svc
  echo ""
  echo "=================================================="
  echo " 테스트 방법 (vagrant ssh 후)"
  echo "=================================================="
  echo " # VIP 확인"
  echo " kubectl get svc sctp-server-svc"
  echo ""
  echo " # Server Multus IP 확인"
  echo " kubectl exec sctp-server -- ip addr show net1"
  echo ""
  echo " # SCTP 연결 테스트"
  echo ' LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='"'"'{.status.loadBalancer.ingress[0].ip}'"'"' 2>/dev/null || true); [ -n "$LB_VIP" ] || LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='"'"'{.status.loadBalancer.ingress[0].hostname}'"'"' 2>/dev/null || true); LB_VIP=${LB_VIP#llb-}'
  echo " # Client의 client-net IP(net1)를 소스로 사용"
  echo " kubectl exec -it sctp-client -- sctp_darn -H 10.0.10.110 -h \${LB_VIP} -P 36412 -p 36412 -s"
  echo ""
  echo " # LoxiLB 규칙 확인"
  echo ' LOXILB_POD=$(kubectl get pods -n kube-system -l app=loxilb-app -o jsonpath='"'"'{.items[0].metadata.name}'"'"')'
  echo " kubectl exec -n kube-system \${LOXILB_POD} -- loxicmd get lb"
  echo "=================================================="
  echo "=== [6/6] 완료 ==="
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — 배포 점검 및 리포트 내보내기 (/vagrant/checks)
# VM 외부(호스트)에서 결과 확인 가능
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

  echo "=== [7/7] 배포 점검 시작 ==="
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

  echo "\n[1] CNI 바이너리 확인"
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

  echo "\n[2] Kubernetes 리소스 상태"
  kubectl get nodes -o wide || true
  kubectl get pods -A -o wide || true
  kubectl get net-attach-def -A || true

  echo "\n[3] LoxiLB Multus 어노테이션 확인"
  LOXI_DS_NETS="$(kubectl -n kube-system get ds loxilb-lb -o jsonpath='{.spec.template.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks}' 2>/dev/null || true)"
  echo "loxilb ds annotation: ${LOXI_DS_NETS}"
  if echo "${LOXI_DS_NETS}" | grep -q "multus-net" && echo "${LOXI_DS_NETS}" | grep -q "client-net" && echo "${LOXI_DS_NETS}" | grep -q "192.168.100.50" && echo "${LOXI_DS_NETS}" | grep -q "10.0.10.50"; then
    check_ok "LOXILB_DS_MULTUS_ANNOTATION" "PASS"
  else
    check_ok "LOXILB_DS_MULTUS_ANNOTATION" "FAIL"
  fi

  echo "\n[4] Pod net1 인터페이스 확인"
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

  echo "\n[5] 최근 네트워크 관련 경고 이벤트"
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null \
    | grep -E "FailedCreatePodSandBox|failed to find plugin|multus-shim|calico" || true

  echo "\n[6] Multus RBAC 확인"
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

  # latest-summary.env를 기반으로 실패 항목별 원인/조치 가이드 생성
  {
    echo "# Multus/LoxiLB 자동 진단"
    echo "time=${TS}"
    echo "overall=${OVERALL}"
    echo ""

    if [ "${OVERALL}" = "PASS" ]; then
      echo "모든 체크가 PASS입니다."
      echo "추가 조치가 필요하지 않습니다."
    else
      # shellcheck disable=SC1090
      . "${SUMMARY_FILE}"

      echo "실패 항목별 가이드:"
      echo ""

      if [ "${CALICO_BIN:-FAIL}" != "PASS" ]; then
        echo "[CALICO_BIN]"
        echo "- 원인: /opt/cni/bin 에 calico 또는 calico-ipam 바이너리 누락"
        echo "- 영향: Multus 기본(delegate) CNI 호출 시 FailedCreatePodSandBox 발생"
        echo "- 조치: calico-node pod에서 /opt/cni/bin/calico* 복구 후 chmod 755 적용"
        echo ""
      fi

      if [ "${STD_CNI_BIN:-FAIL}" != "PASS" ]; then
        echo "[STD_CNI_BIN]"
        echo "- 원인: /opt/cni/bin 에 macvlan/bandwidth/portmap 표준 CNI 바이너리 누락"
        echo "- 영향: Multus DEL/ADD 단계에서 macvlan, bandwidth 플러그인 호출 실패"
        echo "- 조치: containernetworking/plugins tgz 재압축 해제 후 바이너리 권한 확인"
        echo ""
      fi

      if [ "${K3S_CNI_SYNC:-FAIL}" != "PASS" ]; then
        echo "[K3S_CNI_SYNC]"
        echo "- 원인: /opt/cni/bin 과 /var/lib/rancher/k3s/data/current/bin 간 플러그인 불일치"
        echo "- 영향: 호출 주체에 따라 플러그인 탐색 경로가 달라 간헐 실패 발생"
        echo "- 조치: /opt/cni/bin 내용을 k3s current bin 경로로 동기화"
        echo ""
      fi

      if [ "${MULTUS_VIEW_CNI:-FAIL}" != "PASS" ]; then
        echo "[MULTUS_VIEW_CNI]"
        echo "- 원인: VM에서 파일이 있어도 multus pod(/hostroot) 관점에서 CNI 바이너리가 보이지 않음"
        echo "- 영향: multus ADD/DEL 시 macvlan/bandwidth/calico not found 오류 발생"
        echo "- 조치: kube-multus-ds 재시작 후 /hostroot/opt/cni/bin 경로 재검증"
        echo ""
      fi

      if [ "${LOXILB_DS_MULTUS_ANNOTATION:-FAIL}" != "PASS" ]; then
        echo "[LOXILB_DS_MULTUS_ANNOTATION]"
        echo "- 원인: loxilb DaemonSet Pod template에 Multus networks annotation 미적용"
        echo "- 영향: loxilb pod에 net1 인터페이스가 생성되지 않음"
        echo "- 조치: ds/loxilb-lb에 k8s.v1.cni.cncf.io/networks=multus-net patch 적용"
        echo ""
      fi

      if [ "${SCTP_SERVER_NET1:-FAIL}" != "PASS" ]; then
        echo "[SCTP_SERVER_NET1]"
        echo "- 원인: sctp-server pod의 Multus 첨부 실패 또는 NAD 설정 불일치"
        echo "- 영향: server가 multus 대역(192.168.100.0/24)으로 수신 불가"
        echo "- 조치: pod annotation, NAD(default/multus-net), multus ds 상태 재확인"
        echo ""
      fi

      if [ "${LOXILB_POD_NET1:-FAIL}" != "PASS" ]; then
        echo "[LOXILB_POD_NET1]"
        echo "- 원인: loxilb pod Multus 첨부 실패 또는 kube-system NAD 부재"
        echo "- 영향: loxilb → server 경로(multus-net)가 형성되지 않음"
        echo "- 조치: NAD(kube-system/multus-net), loxilb pod 재시작, 이벤트 점검"
        echo ""
      fi

      if [ "${LOXILB_POD_NET2:-FAIL}" != "PASS" ]; then
        echo "[LOXILB_POD_NET2]"
        echo "- 원인: loxilb pod에 client-net Multus 첨부 실패"
        echo "- 영향: client → loxilb 경로(client-net)가 형성되지 않음"
        echo "- 조치: NAD(kube-system/client-net), loxilb ds annotation 확인, 이벤트 점검"
        echo ""
      fi

      if [ "${SCTP_CLIENT_NET1:-FAIL}" != "PASS" ]; then
        echo "[SCTP_CLIENT_NET1]"
        echo "- 원인: sctp-client pod의 client-net Multus 첨부 실패"
        echo "- 영향: client가 client-net 대역(10.0.10.0/24)으로 LB VIP 접근 불가"
        echo "- 조치: pod annotation, NAD(default/client-net), multus ds 상태 재확인"
        echo ""
      fi

      if [ "${MULTUS_RBAC:-FAIL}" != "PASS" ]; then
        echo "[MULTUS_RBAC]"
        echo "- 원인: system:serviceaccount:kube-system:multus 의 cluster-scope pod list/watch 권한 부족"
        echo "- 영향: multus reflector 에러 지속, 상태 추적 및 정리 로직 불안정"
        echo "- 조치: multus SA에 pods/events/nodes/namespaces get/list/watch ClusterRoleBinding 추가"
        echo ""
      fi

      echo "추천 확인 명령:"
      echo "- kubectl get net-attach-def -A"
      echo "- kubectl -n kube-system describe ds loxilb-lb"
      echo "- kubectl describe pod sctp-server"
      echo "- kubectl get events -A --sort-by=.lastTimestamp | tail -n 80"
    fi
  } > "${DIAG_TS_FILE}"

  cp -f "${REPORT_FILE}" "${LATEST_FILE}"
  cp -f "${DIAG_TS_FILE}" "${DIAG_FILE}"
  echo "${REPORT_FILE}" > "${REPORT_DIR}/latest-path.txt"

  echo "\n=== [7/7] 배포 점검 완료: ${OVERALL} ==="
  echo "host 확인 경로: ${LATEST_FILE}"
  echo "host 요약 경로: ${SUMMARY_FILE}"
  echo "host 진단 경로: ${DIAG_FILE}"
SHELL

# ══════════════════════════════════════════════════════════════════════════════
# Vagrant 설정
# ══════════════════════════════════════════════════════════════════════════════
Vagrant.configure("2") do |config|

  config.vm.define "loxilb-k8s" do |node|
    node.vm.box      = "bento/ubuntu-24.04"
    node.vm.hostname = "loxilb-k8s"

    # eth1: K8s 관리 네트워크 (k3s advertise-address)
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
      # macvlan 동작을 위해 promiscuous 모드 필수
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
    # 테스트 스크립트: provision 시 자동 실행 + VM 내 /home/vagrant/run-tests.sh 로 설치
    node.vm.provision "shell", name: "8-functional-tests", path: "scripts/post-provision-functional-tests.sh"
    node.vm.provision "shell", name: "9-test-script-hint", inline: <<~'HINT'
      echo ""
      echo "════════════════════════════════════════════════════════════════"
      echo " VM 내부에서 테스트 재실행:"
      echo "   vagrant ssh"
      echo "   sudo /home/vagrant/run-tests.sh"
      echo "════════════════════════════════════════════════════════════════"
    HINT
  end
end
