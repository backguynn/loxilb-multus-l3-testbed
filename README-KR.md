# LoxiLB Multus SCTP/TCP Vagrant Testbed

이 프로젝트는 단일 VM 안에 k3s, Calico, Multus, LoxiLB를 구성하고, SCTP/TCP E2E 테스트까지 자동으로 수행하는 Vagrant 기반 테스트베드다.

## 포함 내용

- k3s 단일 노드 클러스터
- Calico primary CNI
- Multus secondary CNI
- LoxiLB + kube-loxilb
- SCTP/TCP client/server Pod 및 LoadBalancer Service
- 자동 기능 테스트 스크립트

## 요구 사항

- Linux, macOS, 또는 Windows + WSL2
- Vagrant
- VirtualBox 또는 libvirt
- 인터넷 연결
- 최소 4 vCPU, 4 GB RAM 권장

## 파일 구성

- [Vagrantfile](Vagrantfile): 전체 환경 구성 및 앱 배포
- [scripts/post-provision-functional-tests.sh](scripts/post-provision-functional-tests.sh): 프로비저닝 후 기능 테스트 스크립트
- [checks](checks): 실행 후 생성되는 진단 및 테스트 로그

## 빠른 시작

```bash
vagrant up
vagrant ssh
sudo /home/vagrant/run-tests.sh
```

최초 구성은 네트워크 다운로드 환경에 따라 약 10~15분 정도 걸릴 수 있다.

## 테스트 시나리오

기능 테스트에서 사용하는 토폴로지는 아래와 같다.

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

기능 테스트 스크립트는 아래 항목을 점검한다.

1. Multus 인터페이스 부착 여부
2. server에서 client-net 대역으로의 라우팅 여부
3. Pod와 LoxiLB 간 L2 ping 통신 여부
4. LoxiLB LB rule 생성 여부
5. SCTP client -> VIP -> LoxiLB -> server E2E 여부
6. TCP client -> VIP -> LoxiLB -> server E2E 여부

## 실행 결과 확인

- 최신 기능 테스트 로그: [checks/latest-functional-tests.log](checks/latest-functional-tests.log)
- 최신 배포 진단 로그: [checks/latest-diagnosis.txt](checks/latest-diagnosis.txt)
- 기능 테스트 재실행: VM 내부에서 `sudo /home/vagrant/run-tests.sh`

## 수동 점검 예시

```bash
kubectl get svc sctp-server-svc
kubectl exec sctp-server -- ip addr show net1

LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[ -n "$LB_VIP" ] || LB_VIP=$(kubectl get svc sctp-server-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
LB_VIP=${LB_VIP#llb-}

kubectl exec -it sctp-client -- sctp_darn -H 10.0.10.110 -h ${LB_VIP} -P 36412 -p 36412 -s
```

## 참고

- kube-loxilb 환경에서는 LoadBalancer VIP가 `status.loadBalancer.ingress[0].hostname` 에 `llb-10.0.10.254` 형태로 나타날 수 있다.
- 기능 테스트 스크립트는 이 경우를 처리하도록 되어 있다.