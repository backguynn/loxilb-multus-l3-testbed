#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# LoxiLB Multus E2E Functional Tests
#
# Topology:
#   SCTP/TCP Client ──[client-net: 10.0.10.0/24]──► LoxiLB (VIP: 10.0.10.254)
#                                                       │
#                                              [multus-net: 192.168.100.0/24]
#                                                       │
#                                                       ▼
#                                                  SCTP/TCP Server
#
# Usage (vagrant 내부):
#   sudo /home/vagrant/run-tests.sh
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

REPORT_DIR="/vagrant/checks"
TS="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="${REPORT_DIR}/functional-tests-${TS}.log"
LATEST_FILE="${REPORT_DIR}/latest-functional-tests.log"

mkdir -p "${REPORT_DIR}"
exec > >(tee -a "${REPORT_FILE}") 2>&1

# VM 안에 스크립트를 설치 (vagrant provision 시 자동, 수동 실행 시 skip)
INSTALL_PATH="/home/vagrant/run-tests.sh"
SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
if [[ "${SELF}" != "$(realpath "${INSTALL_PATH}" 2>/dev/null || echo "")" ]]; then
  cp -f "${SELF}" "${INSTALL_PATH}"
  chmod 755 "${INSTALL_PATH}"
  chown vagrant:vagrant "${INSTALL_PATH}" 2>/dev/null || true
  echo "[INFO] 테스트 스크립트 설치됨: ${INSTALL_PATH}"
fi

echo "═══════════════════════════════════════════════════════════"
echo " LoxiLB Multus E2E 기능 테스트"
echo " ${TS}"
echo "═══════════════════════════════════════════════════════════"

# ── Helpers ───────────────────────────────────────────────────────────────────

pass_count=0
fail_count=0

record() {
  local name="$1" status="$2" detail="$3"
  if [[ "${status}" == "PASS" ]]; then
    pass_count=$((pass_count + 1))
    echo "[PASS] ${name} — ${detail}"
  else
    fail_count=$((fail_count + 1))
    echo "[FAIL] ${name} — ${detail}"
  fi
}

wait_ready() {
  local ns="$1" pod="$2" timeout_sec=180 elapsed=0
  echo -n "[wait] ${ns}/${pod} Ready 대기"
  while [[ "${elapsed}" -lt "${timeout_sec}" ]]; do
    local ready
    ready=$(kubectl -n "${ns}" get pod "${pod}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "${ready}" == "True" ]]; then
      echo " OK"
      return 0
    fi
    printf "."
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo " TIMEOUT"
  return 1
}

wait_lb_ip() {
  local svc="$1" timeout_sec=180 elapsed=0 ip=""
  while [[ "${elapsed}" -lt "${timeout_sec}" ]]; do
    ip=$(kubectl get svc "${svc}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -z "${ip}" ]]; then
      ip=$(kubectl get svc "${svc}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    fi
    if [[ -z "${ip}" ]]; then
      ip=$(kubectl get svc "${svc}" \
        -o jsonpath='{.spec.loadBalancerIP}' 2>/dev/null || true)
    fi
    if [[ -z "${ip}" ]]; then
      ip=$(kubectl get svc "${svc}" \
        -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null || true)
    fi
    if [[ -n "${ip}" ]]; then
      # kube-loxilb 이 "llb-" 접두어를 붙이는 경우 제거
      echo "${ip#llb-}"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

get_multus_ip() {
  local ns="$1" pod="$2" dev="${3:-net1}"
  kubectl -n "${ns}" exec "${pod}" -- \
    ip -4 -o addr show dev "${dev}" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1
}

# ── Pod readiness ─────────────────────────────────────────────────────────────
echo ""
echo "── Pod 준비 상태 확인 ──"
wait_ready default sctp-server
wait_ready default sctp-client
wait_ready default tcp-server
wait_ready default tcp-client

LOXILB_POD=$(kubectl -n kube-system get pod -l app=loxilb-app \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${LOXILB_POD}" ]]; then
  echo "[ERROR] LoxiLB pod not found"
  exit 0
fi
wait_ready kube-system "${LOXILB_POD}"

# ── Collect IPs ───────────────────────────────────────────────────────────────
echo ""
echo "── IP 정보 수집 ──"
SCTP_CLIENT_NET1=$(get_multus_ip default sctp-client net1)
SCTP_SERVER_NET1=$(get_multus_ip default sctp-server net1)
TCP_CLIENT_NET1=$(get_multus_ip default tcp-client net1)
TCP_SERVER_NET1=$(get_multus_ip default tcp-server net1)
LOXILB_NET1=$(get_multus_ip kube-system "${LOXILB_POD}" net1)
LOXILB_NET2=$(get_multus_ip kube-system "${LOXILB_POD}" net2)

SCTP_VIP=$(wait_lb_ip sctp-server-svc || true)
TCP_VIP=$(wait_lb_ip tcp-server-svc || true)

echo "sctp-client net1 (client-net) : ${SCTP_CLIENT_NET1:-<none>}"
echo "sctp-server net1 (multus-net) : ${SCTP_SERVER_NET1:-<none>}"
echo "tcp-client  net1 (client-net) : ${TCP_CLIENT_NET1:-<none>}"
echo "tcp-server  net1 (multus-net) : ${TCP_SERVER_NET1:-<none>}"
echo "loxilb      net1 (multus-net) : ${LOXILB_NET1:-<none>}"
echo "loxilb      net2 (client-net) : ${LOXILB_NET2:-<none>}"
echo "SCTP VIP                      : ${SCTP_VIP:-<none>}"
echo "TCP  VIP                      : ${TCP_VIP:-<none>}"

# ══════════════════════════════════════════════════════════════════════════════
# [1] Multus 인터페이스 확인
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── [1] Multus 인터페이스 확인 ──"

[[ -n "${SCTP_CLIENT_NET1}" ]] \
  && record "SCTP_CLIENT_NET1" "PASS" "${SCTP_CLIENT_NET1}" \
  || record "SCTP_CLIENT_NET1" "FAIL" "net1 not found"

[[ -n "${SCTP_SERVER_NET1}" ]] \
  && record "SCTP_SERVER_NET1" "PASS" "${SCTP_SERVER_NET1}" \
  || record "SCTP_SERVER_NET1" "FAIL" "net1 not found"

[[ -n "${TCP_CLIENT_NET1}" ]] \
  && record "TCP_CLIENT_NET1" "PASS" "${TCP_CLIENT_NET1}" \
  || record "TCP_CLIENT_NET1" "FAIL" "net1 not found"

[[ -n "${TCP_SERVER_NET1}" ]] \
  && record "TCP_SERVER_NET1" "PASS" "${TCP_SERVER_NET1}" \
  || record "TCP_SERVER_NET1" "FAIL" "net1 not found"

[[ -n "${LOXILB_NET1}" && -n "${LOXILB_NET2}" ]] \
  && record "LOXILB_MULTUS" "PASS" "net1=${LOXILB_NET1}, net2=${LOXILB_NET2}" \
  || record "LOXILB_MULTUS" "FAIL" "net1=${LOXILB_NET1:-<none>}, net2=${LOXILB_NET2:-<none>}"

# ══════════════════════════════════════════════════════════════════════════════
# [2] Server → client-net 라우팅 확인
#    Server 가 10.0.10.0/24 대역을 LoxiLB(192.168.100.50) 경유하는지 검증
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── [2] Server → client-net 라우팅 확인 ──"

if kubectl exec sctp-server -- ip route show 10.0.10.0/24 2>/dev/null | grep -q "${LOXILB_NET1:-x}"; then
  record "SERVER_ROUTE" "PASS" "10.0.10.0/24 via ${LOXILB_NET1}"
else
  record "SERVER_ROUTE" "FAIL" "route to 10.0.10.0/24 via LoxiLB not found"
  echo "  [diag] sctp-server ip route:"
  kubectl exec sctp-server -- ip route 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# [3] Multus L2 ping 확인
#    같은 macvlan bridge 위에서 Pod ↔ LoxiLB 간 L2 통신 가능 여부
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── [3] Multus L2 ping 확인 ──"

if kubectl exec sctp-client -- ping -c 2 -W 3 "${LOXILB_NET2:-10.0.10.50}" >/dev/null 2>&1; then
  record "CLIENT_PING_LOXILB" "PASS" "client → loxilb(${LOXILB_NET2}) on client-net"
else
  record "CLIENT_PING_LOXILB" "FAIL" "client → loxilb(${LOXILB_NET2}) unreachable"
fi

if kubectl exec sctp-server -- ping -c 2 -W 3 "${LOXILB_NET1:-192.168.100.50}" >/dev/null 2>&1; then
  record "SERVER_PING_LOXILB" "PASS" "server → loxilb(${LOXILB_NET1}) on multus-net"
else
  record "SERVER_PING_LOXILB" "FAIL" "server → loxilb(${LOXILB_NET1}) unreachable"
fi

# ══════════════════════════════════════════════════════════════════════════════
# [4] LoxiLB LB 규칙 확인
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── [4] LoxiLB LB 규칙 확인 ──"

LB_RULES=$(kubectl -n kube-system exec "${LOXILB_POD}" -- loxicmd get lb 2>/dev/null || true)
echo "${LB_RULES}"

if echo "${LB_RULES}" | grep -q "36412"; then
  record "LOXILB_SCTP_RULE" "PASS" "SCTP LB rule exists"
else
  record "LOXILB_SCTP_RULE" "FAIL" "SCTP LB rule not found"
fi

if echo "${LB_RULES}" | grep -q "38080"; then
  record "LOXILB_TCP_RULE" "PASS" "TCP LB rule exists"
else
  record "LOXILB_TCP_RULE" "FAIL" "TCP LB rule not found"
fi

# ══════════════════════════════════════════════════════════════════════════════
# [5] SCTP E2E: client(client-net) → VIP → LoxiLB → server(multus-net)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── [5] SCTP E2E: client(${SCTP_CLIENT_NET1:-?}) → VIP(${SCTP_VIP:-?}):36412 → server ──"

if [[ -z "${SCTP_VIP}" ]]; then
  record "SCTP_E2E" "FAIL" "VIP not allocated"
elif [[ -z "${SCTP_CLIENT_NET1}" ]]; then
  record "SCTP_E2E" "FAIL" "client net1 IP not available"
else
  # sctp_darn -H <bind_ip> -h <dest_ip> -P <src_port> -p <dst_port> -s
  # client-net IP를 bind 하여 Multus 경로 사용을 강제한다.
  # sctp_darn 은 association 성립 후에도 timeout 종료로 비정상 exit 할 수 있어,
  # 종료 코드 대신 SCTP_COMM_UP 이벤트를 성공 신호로 판정한다.
  SCTP_E2E_OUTPUT=$(kubectl exec sctp-client -- sh -c \
    "printf 'sctp-e2e-test\n' | timeout 10 sctp_darn -H ${SCTP_CLIENT_NET1} -h ${SCTP_VIP} -P 36412 -p 36412 -s" \
    2>&1 || true)
  if printf '%s\n' "${SCTP_E2E_OUTPUT}" | grep -q 'Received SCTP_COMM_UP'; then
    record "SCTP_E2E" "PASS" "${SCTP_CLIENT_NET1} → ${SCTP_VIP}:36412 → server"
  else
    record "SCTP_E2E" "FAIL" "SCTP_COMM_UP not observed"
    echo "  [diag] sctp_darn output:"
    printf '%s\n' "${SCTP_E2E_OUTPUT}"
    echo "  [diag] client routes:"
    kubectl exec sctp-client -- ip route 2>/dev/null || true
    echo "  [diag] server routes:"
    kubectl exec sctp-server -- ip route 2>/dev/null || true
    echo "  [diag] loxilb conntrack:"
    kubectl -n kube-system exec "${LOXILB_POD}" -- loxicmd get conntrack 2>/dev/null | head -30 || true
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# [6] TCP E2E: client(client-net) → VIP → LoxiLB → server(multus-net)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── [6] TCP E2E: client(${TCP_CLIENT_NET1:-?}) → VIP(${TCP_VIP:-?}):38080 → server ──"

if [[ -z "${TCP_VIP}" ]]; then
  record "TCP_E2E" "FAIL" "VIP not allocated"
elif [[ -z "${TCP_CLIENT_NET1}" ]]; then
  record "TCP_E2E" "FAIL" "client net1 IP not available"
else
  # nc -s <bind_ip> 로 client-net 경로 강제
  if kubectl exec tcp-client -- sh -c \
    "printf 'tcp-e2e-ok\n' | timeout 10 nc -s ${TCP_CLIENT_NET1} -w 5 ${TCP_VIP} 38080" \
    2>/dev/null | grep -q 'tcp-e2e-ok'; then
    record "TCP_E2E" "PASS" "${TCP_CLIENT_NET1} → ${TCP_VIP}:38080 → server"
  else
    record "TCP_E2E" "FAIL" "no echo response"
    echo "  [diag] client routes:"
    kubectl exec tcp-client -- ip route 2>/dev/null || true
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " 결과: PASS=${pass_count}  FAIL=${fail_count}"
if [[ "${fail_count}" -eq 0 ]]; then
  echo " 모든 테스트 통과!"
else
  echo " 일부 테스트 실패 — 위 로그를 확인하세요."
fi
echo "═══════════════════════════════════════════════════════════"

cp -f "${REPORT_FILE}" "${LATEST_FILE}"
echo "report: ${LATEST_FILE}"

echo ""
echo "※ VM 내부에서 재실행: sudo /home/vagrant/run-tests.sh"
