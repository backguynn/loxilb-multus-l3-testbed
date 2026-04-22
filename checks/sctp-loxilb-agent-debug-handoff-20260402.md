# SCTP NAT 장애 디버깅 핸드오프 (for AI Agent)

- 작성일: 2026-04-02
- 대상: loxilb 코드 수정 + 재현 디버깅 수행 에이전트
- 환경: 단일 노드 Vagrant + k3s + Multus + loxilb

## 1. 목표

SCTP 서비스가 VIP 경유 시 세션 성립 실패하는 원인을 코드 레벨로 특정하고, 수정 후 재현 테스트에서 정상 응답을 확인한다.

## 2. 현재까지 확정된 사실

1. 서버 리스너는 정상이다.
- `sctp-server`는 `192.168.100.110:36412`에서 LISTEN 상태.

2. VIP 경유 클라이언트 접근은 실패한다.
- `sctp-client -> 172.16.96.196:36412` 실행 시 타임아웃.
- 노드 conntrack에서 `CLOSED [UNREPLIED]`로 남음.

3. NAT 경로에서 INIT 재전송만 관측된다.
- `loxilb net1` 캡처: `192.168.100.50:36412 -> 192.168.100.110:36412` INIT 반복.
- `sctp-server net1` 캡처: 동일하게 INIT만 보이고 INIT-ACK 미관측.

4. 직접 경로는 부분적으로 성립한다.
- `loxilb pod -> sctp-server(192.168.100.110)`에서 `SCTP_COMM_UP` 관측 사례 존재.

5. rp_filter 원인 가능성은 낮다.
- node/server/loxilb 모두 `rp_filter=2(loose)`.

## 3. 우선 결론

원인은 서버 애플리케이션 불량이 아니라, "VIP 경유 SCTP NAT/세션 복원 경로" 쪽일 가능성이 매우 높다.

특히 다음 시그널이 핵심이다.
- NAT된 source(`192.168.100.50`)에서 backend(`192.168.100.110`)로 INIT는 전달됨
- 하지만 association이 성립되지 않아 INIT-ACK 왕복/복원이 진행되지 않음
- conntrack이 `UNREPLIED`로 남음

## 4. loxilb 관점 핵심 단서

`loxicmd get lb`에서 SCTP 룰은 올라와 있으며 mode는 `onearm`.

로그에서 확인된 룰 문자열 예:
- `lb-rule added ... -do-fullnat:onearm:eip-192.168.100.110 ...`

추가 관찰:
- 시간대별로 LB VIP가 변동된 흔적(`192.168.56.200 -> 192.168.100.254 -> 172.16.96.196`)
- `192.168.100.50` 관련 route add 에러 로그 존재

## 5. 재현 절차 (최소)

### 5.1 환경 확인

1. VM 접속
- `vagrant ssh`

2. 파드/서비스 확인
- `sudo k3s kubectl get pods -A -o wide`
- `sudo k3s kubectl -n default get svc sctp-server-svc -o wide`
- `sudo k3s kubectl -n default exec sctp-server -- ip -4 addr show net1`

### 5.2 실패 재현 (client -> VIP)

- `sudo k3s kubectl -n default exec sctp-client -- sh -c 'printf "probe\n" | timeout 8 sctp_darn -H 172.16.96.198 -h 172.16.96.196 -P 36412 -p 36412 -s'`

예상 결과:
- timeout
- conntrack:
  - `sudo conntrack -L -p sctp | grep 36412`
  - `CLOSED [UNREPLIED] src=172.16.96.198 dst=172.16.96.196 sport=36412 dport=36412 ...`

### 5.3 패킷 증거 확보

1. loxilb net1 캡처
- `sudo k3s kubectl -n kube-system exec loxilb-lb-95f2r -- sh -c 'timeout 12 tcpdump -vvv -nn -i net1 sctp and port 36412 -c 10'`

2. server net1 캡처
- `sudo k3s kubectl -n default exec sctp-server -- sh -c 'timeout 12 tcpdump -nn -i net1 sctp and port 36412 -c 20'`

예상 결과:
- INIT 재전송만 보이고 INIT-ACK 미관측

## 6. 코드 수정 포인트 (탐색 가이드)

아래 항목을 loxilb 코드에서 우선 검색/추적할 것.

1. SCTP NAT rewrite
- IP/port rewrite 이후 SCTP checksum(CRC32c) 재계산 경로
- INIT/INIT-ACK/COOKIE-ECHO 처리 시 header/chunk 무결성 유지

2. SCTP state tracking
- NAT + conntrack state key(4/5 tuple, zone, direction) 일관성
- reverse path에서 association 매핑 복원 실패 여부

3. FullNAT/onearm 경로 차이
- SCTP에서 onearm 모드와 fullnat 플래그 해석 차이
- DNAT/SNAT 적용 순서 및 예외 분기

4. VIP/interface binding
- VIP 변경/재할당 시 stale rule/ct flush 타이밍
- net1/eth0/lo 바인딩과 route programming 실패 시 fallback 동작

## 7. 코드 수정 후 검증 기준 (Acceptance)

아래를 모두 만족해야 "수정 완료"로 간주.

1. 기능
- `sctp-client -> VIP`가 timeout 없이 association 성립
- 서버에서 SCTP session 수립 로그 확인

2. 트래픽
- 캡처에서 INIT -> INIT-ACK -> COOKIE-ECHO -> COOKIE-ACK 진행 확인
- DATA/SACK 교환 확인

3. 상태
- conntrack에서 `UNREPLIED` 잔존하지 않음
- 역방향 응답이 동일 association으로 복원됨

4. 회귀
- 기존 direct 경로(`loxilb -> server`) 동작 유지
- TCP/UDP LB 동작에 부작용 없음

## 8. 추천 디버깅 순서

1. SCTP NAT checksum/state 처리 코드 위치 식별
2. VIP 경유 재현 테스트 자동화 스크립트화
3. 패킷/conntrack 스냅샷을 수정 전/후 diff 비교
4. 가장 작은 패치로 1차 fix 적용
5. Acceptance 기준 전부 통과 확인

## 9. 참고 파일

- 원본 분석 문서: `checks/sctp-nat-analysis-report-20260402.md`
- 최신 점검 로그: `checks/multus-loxilb-check-20260402-054631.log`
- 최신 진단 요약: `checks/latest-diagnosis.txt`

## 10. 참고: 실행 중 확인된 대표 출력

- client->VIP 실패 시 conntrack 예시:
  - `sctp 132 1 CLOSED src=172.16.96.198 dst=172.16.96.196 sport=36412 dport=36412 [UNREPLIED] ...`

- loxilb net1 캡처 예시:
  - `192.168.100.50.36412 > 192.168.100.110.36412: sctp [INIT] ...` (재전송)

- loxicmd rule 예시:
  - `... -do-fullnat:onearm:eip-192.168.100.110 ...`

---

이 문서는 "코드 수정 담당 AI 에이전트"가 바로 재현/수정/검증 루프에 들어갈 수 있도록 작성되었다.
수정 시에는 반드시 SCTP handshake 단계별 패킷 증거와 conntrack 상태를 함께 수집해 변경 효과를 입증할 것.
