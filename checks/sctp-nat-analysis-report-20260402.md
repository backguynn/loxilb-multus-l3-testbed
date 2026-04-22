# SCTP NAT 동작 이슈 분석 레포트

- 작성일: 2026-04-02
- 환경: Vagrant 기반 k3s + Multus + loxilb
- 테스트 시나리오 요약:
  - 서비스 VIP: 192.168.100.50 (loxilb Pod net1 IP)
  - 클라이언트: sctp-client에서 `sctp_darn` 사용
  - 서버: sctp-server (192.168.100.110)

## 1) 관찰된 현상

1. `sctp-client -> VIP(192.168.100.50)` 경로 테스트 시
- NAT 자체는 수행됨
- 패킷은 tcpdump 상 `sctp-server`까지 정상 도달
- 하지만 `sctp-server` 애플리케이션 응답 미반환

2. `loxilb pod -> sctp-server(192.168.100.110)` direct 테스트 시
- `sctp_darn` 응답 정상 수신

3. tcpdump 관점
- NAT 경유 패킷과 direct 패킷이 겉보기에는 유사/동일

## 2) 핵심 해석

"서버 NIC에서 패킷이 보인다"와 "서버 SCTP 소켓이 유효 패킷으로 수용한다"는 동일하지 않다.

즉, L2/L3 전달이 성립해도 SCTP 커널 스택 레벨에서 검증 실패 또는 세션 상태 불일치가 발생하면 애플리케이션 응답이 없을 수 있다.

## 3) 우선 의심 원인 (우선순위 순)

### A. NAT 이후 SCTP 무결성(체크섬/헤더) 검증 실패

- SCTP는 NAT에 민감하며 주소/포트 변경 시 CRC32c 및 관련 필드 정합성이 정확해야 함
- tcpdump 상 패킷이 보여도, 커널이 checksum/verification tag/association 상태 불일치로 드롭 가능
- 결과적으로 서버 프로세스는 수신하지 못하고 응답도 없음

### B. 리턴 경로 비대칭 (정책 라우팅, rp_filter, NAT 상태 불일치)

- 요청은 NAT를 통해 들어왔지만 응답 경로가 NAT 기대 경로와 어긋날 수 있음
- `direct` 테스트는 경로가 단순해 성공, VIP 경유는 NAT/라우팅 조건이 추가되어 실패 가능
- `rp_filter` strict 설정 시 비대칭 경로 패킷 드롭 가능

### C. SCTP NAT 구현 범위/모드 불일치

- 장비/컴포넌트별로 SCTP 처리 시 FullNAT(SNAT+DNAT) 전제가 필요한 경우가 있음
- DNAT 위주 처리 또는 conntrack 상태 유지 미흡 시 서버 응답 경로에서 세션 불일치 발생 가능

## 4) 왜 "tcpdump는 동일한데 결과가 다를 수 있는가"

tcpdump는 "관측된 프레임/패킷"을 보여주지만,
실제 애플리케이션 전달 여부는 커널의 추가 검증을 통과해야 한다.

대표적으로 아래 계층에서 차이가 발생할 수 있다.

- NIC/오프로딩: 캡처 지점에 따라 checksum이 정상처럼 보이거나 반대로 비정상처럼 보일 수 있음
- 커널 SCTP 스택: verification tag, association state, checksum, 정책 필터에서 드롭 가능
- conntrack/NAT state: 역방향 매핑 불일치 시 응답이 세션으로 복원되지 못함

## 5) 권장 검증 절차 (10분 분리 진단)

1. 체크섬/오프로딩 영향 제거
- 서버/loxilb 관련 인터페이스에서 일시적으로 offload 비활성화 후 재테스트
- 확인 항목: 재현성 변화 여부

2. SCTP conntrack 상태 확인
- NAT 전후 노드에서 SCTP conntrack 엔트리 확인
- 확인 항목: 요청/응답 방향 모두 동일 association로 추적되는지

3. rp_filter 및 라우팅 정책 점검
- 서버/loxilb에서 `net.ipv4.conf.*.rp_filter` 값 확인
- strict(1)인 경우 loose(2) 또는 disable(0) 비교 테스트

4. NAT 모드 확인
- loxilb 서비스가 SCTP에 대해 SNAT+DNAT이 기대대로 적용되는지 확인
- 필요 시 동일 플로우에 대해 FullNAT 정책으로 비교

5. 양단 동시 캡처
- loxilb ingress/egress + server ingress/egress 동시 캡처
- 확인 항목: 요청-응답 4튜플, SCTP 청크 타입, 상태 진행(INIT/INIT-ACK/COOKIE-ECHO/COOKIE-ACK, DATA/SACK)

## 6) 결론

본 이슈는 "패킷 전달 실패"보다는 "SCTP 세션 수용/복원 실패" 계열일 가능성이 높다.

가장 가능성이 높은 축은 아래 두 가지다.

- NAT 후 SCTP 유효성 검증 실패(체크섬/상태/태그)
- 응답 경로 비대칭으로 인한 conntrack/NAT 상태 불일치

direct 테스트 성공은 서버 애플리케이션 자체 문제 가능성을 낮추며,
VIP 경유 경로의 NAT/커널/라우팅 조합에서만 문제가 유발된다는 강한 증거다.

## 7) 권장 후속 조치

- 우선 `offload`, `rp_filter`, `conntrack -p sctp` 3가지를 한 세트로 점검
- 이후 loxilb SCTP NAT 모드(특히 SNAT 포함 여부)와 리턴 경로 대칭성 확보
- 필요 시 임시로 경로를 단순화(정적 라우트/정책 제거)하여 원인 축소 후 단계적으로 원복
