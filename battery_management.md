# 배터리 관리 매니지먼트 구현 계획

## 1. 배경 및 문제 정의

### 현재 상황
- **충전기 수 < 로봇 수** (예: 충전기 2대, 로봇 4대)
- RMF의 `recharge_threshold: 0.40` (40%) 이하일 때 자동 충전 task 생성
- `recharge_soc: 0.80` (80%)까지 충전 후 완료
- 현재 config에서 로봇별 전용 충전기 할당 (AGV_001 → tinyRobot1_charger)
- 저배터리 충전 시 `dedicated_charging_wp()`로 전용 충전기만 사용 (ChargeBattery.cpp:517)

### 문제
1. 로봇 A가 충전이 필요한데(SOC < 40%) 모든 충전기가 사용 중인 경우,
   RMF는 충전기가 비어있지 않으면 `waiting_for_charger` 상태로 대기하게 된다.
2. RMF는 `dedicated_charging_wp`만 사용하므로 **다른 로봇의 빈 충전기를 활용하지 못한다**.
3. idle 충전으로 충전기에 간 로봇이 reservation 시스템에 **점유로 등록되지 않아**
   Battery Manager가 충전기 상태를 정확히 파악할 수 없다.

### 목표
충전기가 부족할 때 **지능적으로 충전기를 재배분**하는 자동 배터리 관리 시스템 구현.

---

## 2. 선결 과제: RMF Core 패치 (패치 3)

### 문제 발견

RMF의 `ReservationNodeNegotiator`에서 로봇이 이미 reserved location과 같은 목적지로
이동할 때 reservation 프로토콜을 **전체 skip**하는 로직이 있다:

```cpp
// internal_ReservationNodeNegotiator.hpp (기존)
if (wp_name == context->_get_reserved_location())
{
    // Already have a goal → 바로 cb 호출하고 return
    // → reservation node에 claim이 안 됨
    // → free_parking_spot에 충전기가 계속 free로 남음
}
```

이로 인해 `finishing_request: "charge"`로 idle 충전기에 간 로봇의 점유가
`/rmf/reservations/free_parking_spot`에 반영되지 않는다.

### 해결: 패치 3 적용

**수정 파일**: `internal_ReservationNodeNegotiator.hpp`
**내용**: "Already have a goal" 조건에서 `return`(skip) → `break`(reservation 진행)

```cpp
// [PATCH] 변경 후: skip하지 않고 reservation request를 보내도록
if (wp_name == context->_get_reserved_location())
{
    break;  // return 대신 break → 아래 make_request()로 진행
}
```

상세 내용은 `rmf_core_patch.md` 패치 3 참조.

---

## 3. 충전기 점유 판별 방식

### `/rmf/reservations/free_parking_spot` 토픽 (패치 3 적용 후)

reservation node가 500ms마다 publish하는 빈 parking spot 목록.
충전기는 nav graph에서 `is_parking_spot: true`이므로 reservation 시스템이 관리.

- 충전기가 점유 중 → `free_parking_spot`에 **없음**
- 충전기가 비어있음 → `free_parking_spot`에 **있음**

### `/rmf/reservations/allocation` 토픽

reservation이 할당될 때 발행. **어떤 로봇이 어떤 spot을 예약했는지** 매핑 추적.

```
ReservationAllocation:
  ticket.header.robot_name: "AGV_001"
  resource: "tinyRobot1_charger"
```

### Battery Manager 구독 토픽

| 토픽 | 메시지 타입 | 용도 |
|---|---|---|
| `fleet_state_update` | `std_msgs/String` (JSON) | 로봇 SOC, 위치, task 상태 |
| `/rmf/reservations/free_parking_spot` | `FreeParkingSpots` | 충전기 점유/비어있음 판별 |
| `/rmf/reservations/allocation` | `ReservationAllocation` | 로봇→충전기 매핑 추적 |
| `task_api_responses` | `ApiResponse` | task dispatch/cancel 응답 |

---

## 4. 핵심 동작 메커니즘

### 전체 흐름도

```
[Battery Manager 주기적 체크 (10초)]
  │
  ├─ 1. 대기 큐 처리 (parking에서 기다리는 로봇 먼저)
  │     빈 충전기 발생 시 → 대기 큐 1순위 로봇을 충전기로 dispatch
  │
  └─ 2. 새로운 충전 필요 로봇 감지 (SOC < 40%)
        │
        ├─ 빈 충전기 있음 (free_parking_spot 기반)
        │   → Battery Manager가 직접 go_to_place(charger) dispatch
        │     (RMF는 dedicated_charging_wp만 사용하므로 직접 보내야 함)
        │
        ├─ 빈 충전기 없음 + 퇴거 가능 로봇 있음
        │   (점유 충전기의 로봇 SOC >= 70%, allocation으로 로봇 식별)
        │   → 퇴거 로봇 task cancel → parking 이동
        │   → 빈 충전기 확인 후 → 충전 필요 로봇을 charger로 dispatch
        │
        └─ 빈 충전기 없음 + 퇴거 불가
            → 충전 필요 로봇을 parking으로 보내고 대기 큐에 등록
```

### 시나리오 1: 퇴거 가능 로봇이 있는 경우

```
상황:
  로봇 A: SOC 35%, 충전 필요
  충전기 1: 로봇 B 점유 중 (SOC 75%, allocation으로 확인) ← 퇴거 가능
  충전기 2: 로봇 C 점유 중 (SOC 45%, allocation으로 확인) ← 퇴거 불가

실행:
  1. 로봇 B의 충전 task cancel → on_cancel(stopCharging) → 언도킹
  2. 로봇 B → parking 이동
  3. 충전기 1이 free_parking_spot에 나타남 → 확인
  4. 로봇 A → 충전기 1로 dispatch
```

### 시나리오 2: 퇴거 가능 로봇이 없는 경우

```
상황:
  로봇 A: SOC 35%, 충전 필요
  충전기 1: 로봇 B 점유 (SOC 45%) ← 아직 부족
  충전기 2: 로봇 C 점유 (SOC 50%) ← 아직 부족

실행:
  1. 로봇 A → parking 이동, 대기 큐 등록
  2. [이후] 로봇 B가 SOC 70% 도달 시 → 시나리오 1로 전환
```

---

## 5. 구현 구조

### 프로젝트 위치: `src/battery_management/`

```
battery_management/
├── battery_management/
│   ├── __init__.py
│   ├── manager.py              # BatteryManager ROS 2 노드
│   ├── state.py                # 로봇 충전 상태 머신
│   ├── charger_pool.py         # 충전기 풀 관리 (reservation 기반)
│   └── nav_graph_parser.py     # nav graph에서 charger/parking 자동 파싱
├── config/
│   └── battery_management.yaml
├── launch/
│   └── battery_management.launch.py
├── test/
│   ├── test_state.py
│   └── test_nav_graph_parser.py
├── package.xml
├── setup.py
└── setup.cfg
```

### 충전기/대기장소 자동 파싱

nav graph YAML에서 자동 추출 (하드코딩 불필요):
- `is_charger: true` → `charger_pool`
- `is_parking_spot: true` (charger 제외) → `parking_spots`

### 설정 파라미터 (`battery_management.yaml`)

```yaml
battery_management:
  enabled: true
  check_interval: 10.0              # 체크 주기 (초)
  fleet_name: "vda5050_fleet"
  nav_graph_file: "/bm_ws/nav_graph.yaml"

  recharge_threshold: 0.40          # 충전 필요 SOC
  eviction_threshold: 0.70          # 퇴거 기준 SOC
  critical_threshold: 0.20          # 긴급 충전 SOC

  min_charge_time: 300              # 최소 충전 시간 (초)
  cooldown_time: 600                # 퇴거 쿨다운 (초)
  eviction_timeout: 30.0            # 퇴거 완료 대기 timeout (초)
```

### Task 제어 방식

ROS 2 `task_api_requests` / `task_api_responses` 토픽 사용:

```python
# Task Cancel
payload = {'type': 'cancel_task_request', 'task_id': task_id}

# go_to_place Dispatch (특정 로봇 지정)
payload = {
    'type': 'robot_task_request',
    'robot': robot_name, 'fleet': fleet_name,
    'request': {
        'category': 'compose',
        'description': {
            'category': 'go_to_place',
            'phases': [{'activity': {
                'category': 'go_to_place',
                'description': {'one_of': [{'waypoint': charger_name}]}
            }}]
        }
    }
}
```

---

## 6. 안전 장치

| 장치 | 설명 |
|---|---|
| `min_charge_time` (300초) | 충전 시작 후 5분간 퇴거 불가 |
| `cooldown_time` (600초) | 퇴거된 로봇 10분간 재퇴거 방지 |
| `eviction_timeout` (30초) | 퇴거 task cancel 후 완료 미확인 시 상태 리셋 |
| `critical_threshold` (20%) | SOC 20% 이하 → eviction_threshold 무시, 강제 퇴거 |
| SOC 기반 우선순위 큐 | 대기 큐에서 SOC 가장 낮은 로봇 우선 충전 |

---

## 7. 구현 단계

### Phase 0: RMF Core 패치 [완료]
- [x] 패치 3: ReservationNodeNegotiator "Already have a goal" skip 제거
- [ ] 패치 3 검증: docker compose up 후 free_parking_spot에 charger 점유 반영 확인

### Phase 1: 기본 구조 [완료]
- [x] ROS 2 노드 기본 구조 생성 (`src/battery_management/`)
- [x] `fleet_state_update` 토픽 구독 (로봇 SOC, task 상태)
- [x] `free_parking_spot` 토픽 구독 (충전기 점유 상태)
- [x] `reservation/allocation` 토픽 구독 (로봇→충전기 매핑)
- [x] nav graph 자동 파싱 (charger_pool, parking_spots)
- [x] docker-compose 서비스 추가

### Phase 2: 퇴거 로직
- [x] 빈 충전기 있으면 직접 dispatch
- [x] 점유 충전기의 로봇 식별 (allocation 기반)
- [x] SOC >= eviction_threshold 로봇 퇴거 → parking 이동
- [x] 퇴거 후 충전기 비워짐 → 충전 필요 로봇 dispatch
- [ ] 패치 3 검증 후 실제 동작 테스트

### Phase 3: Parking 대기 큐
- [x] SOC 기반 우선순위 대기 큐
- [x] 충전기 가용 시 큐에서 자동 할당
- [ ] 실환경 테스트

### Phase 4: 안정화
- [x] 무한 루프 방지 (min_charge_time, cooldown)
- [x] 퇴거 실패 처리 / timeout
- [x] critical_threshold 긴급 충전
- [ ] 통합 테스트 시나리오 검증

---

## 8. 관련 파일

| 파일 | 역할 |
|---|---|
| `src/rmf/.../events/internal_ReservationNodeNegotiator.hpp` | **[패치 3]** reservation skip 제거 |
| `src/rmf/.../tasks/ChargeBattery.cpp` | 충전 task 구현 (on_cancel, dedicated_charging_wp) |
| `src/battery_management/` | Battery Management 노드 패키지 |
| `src/vda5050_fleet_adapter/.../config/config.yaml` | 배터리 및 충전 설정 |
| `src/vda5050_fleet_adapter/map/0.yaml` | Nav graph (충전기/대기장소 정의) |
| `docker-compose.yml` | RMF 서비스 구성 (battery_management 포함) |
| `rmf_core_patch.md` | RMF core 패치 목록 (패치 3 포함) |
