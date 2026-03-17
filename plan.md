# 충전 명령 커스텀 구현 계획

> **구현 상태 범례**: [x] 구현 완료 / [~] 폐기 완료 / [ ] 미구현

---

## 1. 배경 및 목적

### 현재 문제

RMF의 충전 task는 내부적으로 다음 2단계로 실행된다:

```
Phase 1: GoToPlace (charger waypoint로 이동)  → navigate() 콜백
Phase 2: WaitForCharge (SOC 모니터링)          → 콜백 없음 (내부 처리)
```

Fleet adapter는 `navigate()` 콜백에서 `destination.dock`을 감지하여 VDA5050 `startCharging` action을
자체적으로 생성하고 있다. 즉 **RMF core가 명시적으로 충전 action을 adapter에 내려주지 않으며**,
adapter가 dock 여부를 추론해서 처리하는 구조이다.

또한 충전 중 새 task가 할당되면, adapter가 `_was_charging` 플래그로 자체 추적하여
다음 order의 첫 노드에 `stopCharging` nodeAction을 삽입하고 있다.
이 역시 RMF core가 명시적으로 내려주는 것이 아니라 adapter의 추론에 의존한다.

### 원하는 구조

**모든 충전 경로**(idle 충전, 저배터리 자동 충전 모두)에서 RMF core가 명시적으로
startCharging/stopCharging을 adapter에 내려주는 구조:

```
Phase 1: GoToPlace (charger waypoint로 이동)    → navigate() 콜백
Phase 2: PerformAction("startCharging")          → execute_action() 콜백
         (adapter가 execution.finished() 호출하지 않음 → 무기한 충전 대기)
         새 task 할당 시 → task cancel → on_cancel 자동 실행:
           └─ PerformAction("stopCharging")      → execute_action() 콜백
              (AGV 언도킹 완료 후 execution.finished() 호출)
새 task 시작
```

- `startCharging`: RMF가 PerformAction으로 명시적 전달
- `stopCharging`: task의 **on_cancel** 시퀀스로 자동 실행
- adapter에서 dock 추론, `_was_charging` 플래그 관리 불필요

---

## 2. 방향 변경 이력

### Phase 1: ComposeCharging factory 방식 (폐기 완료)

처음에는 별도 `ComposeCharging` RequestFactory를 만들어 `finishing_request: "compose_charge"`로
idle 충전만 커스텀하는 방식으로 구현했다. 하지만 이 방식은:

- `recharge_threshold`에 의한 저배터리 자동 충전은 여전히 기존 `ChargeBatteryFactory` 사용
- 두 충전 경로가 다른 코드를 타서 adapter에서 dock 기반/execute_action 기반 로직 공존 필요
- 불필요한 복잡성 발생

### Phase 2: ChargeBattery.cpp 수정 방식 (현재 방향)

**ComposeCharging factory를 폐기**하고, **ChargeBattery.cpp만 수정**하여 모든 충전 경로를 통일한다.

장점:
- 기존 `finishing_request: "charge"` 그대로 사용 (config 변경 불필요)
- `recharge_threshold` 자동 충전도 동일하게 startCharging/stopCharging 사용
- adapter에서 dock 기반 충전 로직 완전 제거 가능
- 수정 포인트가 ChargeBattery.cpp 1개 파일로 집중

---

## 3. 아키텍처 개요 (Phase 2: ChargeBattery.cpp 수정 방식)

### 충전 코드 경로 (현재)

```
모든 충전 경로 (idle + recharge_threshold)
  → ChargeBattery::Description
  → charge_battery_task_unfolder (ChargeBattery.cpp:710-722)
  → ChargeBatteryEvent::Description(indefinite=true/false)
  → ChargeBatteryEvent::Active::_consider_restart() (ChargeBattery.cpp:378-530)
  → standbys = [GoToPlace, WaitForCharge]   ← 여기를 수정
```

### 수정 후 구조

```
_consider_restart() 수정 후:
  standbys = [
    GoToPlace,                          ← 기존 유지
    PerformAction("startCharging"),     ← 새로 삽입
    WaitForCharge (또는 WaitForCancel)  ← 기존 유지
  ]

charge_battery_task_unfolder 수정 후:
  Task::Builder
    .add_phase(ChargeBatteryEvent, {stopCharging})  ← on_cancel 추가
    .build()
```

### 충전 시나리오별 동작

| 시나리오 | indefinite | 시퀀스 | cancel 시 |
|---------|-----------|--------|----------|
| idle → 가까운 곳이 charger | true | GoToPlace → startCharging → WaitForCharge(무기한) | on_cancel: stopCharging |
| idle → 가까운 곳이 parking | true | GoToPlace → WaitForCancel | on_cancel: stopCharging (adapter가 즉시 finished) |
| 저배터리 충전 (`recharge_threshold`) | false | GoToPlace → startCharging → WaitForCharge(recharge_soc까지) | on_cancel: stopCharging |
| 주차 (`finishing_request: "park"`) | N/A | GoToPlace → WaitForCancel | 변경 없음 |

> **Phase 3 예정**: idle 시 `is_parking_spot` + `is_charger` 통합 검색 → target 속성에 따라 동적 분기. 섹션 10 참조.

### 전체 충전 흐름 (타임라인)

```
T0: 충전 task 생성 (idle 감지 또는 저배터리 감지)
    └─ ChargeBatteryFactory::make_request()
    └─ charge_battery_task_unfolder → ChargeBatteryEvent

T1: Phase 1 — GoToPlace (charger waypoint)
    └─ adapter.navigate(dest=charger_wp) 콜백 호출
    └─ 로봇이 charger waypoint까지 이동

T2: Phase 2 — PerformAction("startCharging")
    └─ adapter.execute_action("startCharging", {charging_waypoint: N}, execution) 콜백
    └─ adapter → AGV: VDA5050 startCharging action 전송
    └─ AGV: charger로 자율 도킹 → 충전 시작 → action FINISHED 보고
    └─ adapter: AGV FINISHED 수신하지만 execution.finished()는 호출하지 않음!
       (Phase가 active 상태로 유지 = 충전 대기)

T3: Phase 3 — WaitForCharge
    └─ indefinite=true: 무기한 대기 (idle 충전)
    └─ indefinite=false: battery_soc >= recharge_soc까지 대기 (저배터리 충전)

T4: 새 task 할당 → task cancel
    └─ on_cancel 시퀀스 자동 시작

T5: on_cancel — PerformAction("stopCharging")
    └─ adapter.execute_action("stopCharging", {}, execution2) 콜백
    └─ adapter → AGV: VDA5050 stopCharging action 전송
    └─ AGV: 충전 중지 → 언도킹 → action FINISHED 보고
    └─ adapter: execution2.finished() 호출
    └─ on_cancel 완료 → 새 task 시작
```

---

## 4. 핵심 설계 결정

### 4.1 AGV action FINISHED vs RMF execution.finished() 분리

```
AGV의 startCharging action FINISHED  = "도킹 완료, 충전 시작됨" (VDA5050 레벨)
RMF의 execution.finished()           = "이 phase를 끝내줘" (RMF 레벨)
```

- adapter가 `execution.finished()` 호출 시점을 제어한다
- startCharging: AGV FINISHED를 받아도 `execution.finished()`를 호출하지 않음 → 충전 대기
- stopCharging: AGV FINISHED를 받으면 `execution.finished()` 호출 → on_cancel 완료

### 4.2 on_cancel의 동작 보장

`Task::Builder::add_phase()` 두 번째 파라미터 `cancellation_sequence`:
- Task cancel 시 해당 phase의 cancellation_sequence가 **자동 실행**됨
- on_cancel phase는 **cancel 불가** (skip만 가능) → 반드시 완료됨
- on_cancel이 끝나야 새 task가 시작됨 → 순서 보장

참조: `rmf_task_sequence/Task.cpp:564-584`, `Task.cpp:1126-1145`

### 4.3 startCharging FAILED 처리

AGV가 startCharging을 FAILED로 보고하면:
- adapter가 `execution.finished()` 호출 → startCharging phase 완료
- WaitForCharge phase로 진행 (SOC 도달 시 자연 완료 또는 무기한 대기)
- 또는 task 자체를 fail 처리 → TaskPlanner가 재시도

### 4.4 PerformAction 삽입 위치: `_consider_restart()` vs `charge_battery_task_unfolder`

| 삽입 위치 | startCharging 삽입 | stopCharging on_cancel |
|-----------|-------------------|----------------------|
| `_consider_restart()` (line 469-529) | O — standbys에 PerformAction 추가 | X — Bundle에는 cancellation_sequence 없음 |
| `charge_battery_task_unfolder` (line 710-722) | X — ChargeBatteryEvent 내부를 직접 건드리지 않음 | O — Task::Builder.add_phase()에 on_cancel 추가 |

**→ 둘 다 수정한다:**
- `_consider_restart()`: startCharging PerformAction을 standbys에 삽입
- `charge_battery_task_unfolder`: Task::Builder에 on_cancel(stopCharging) 추가

---

## 5. 수정 대상 파일

### Phase 1 (ComposeCharging factory) — 폐기 완료

| 상태 | 파일 | 패키지 | 설명 |
|------|------|--------|------|
| [~] | `include/rmf_fleet_adapter/tasks/ComposeCharging.hpp` | rmf_fleet_adapter | 삭제됨 |
| [~] | `src/rmf_fleet_adapter/tasks/ComposeCharging.cpp` | rmf_fleet_adapter | 삭제됨 |
| [~] | `src/rmf_fleet_adapter/agv/EasyFullControl.cpp` | rmf_fleet_adapter | `"compose_charge"` 분기 제거됨 |
| [~] | `rmf_fleet_adapter_python/src/adapter.cpp` | rmf_fleet_adapter_python | `"compose_charge"` 바인딩 제거됨 |

### Phase 2 (ChargeBattery.cpp 수정) — 미구현

| 상태 | 파일 | 패키지 | 수정 내용 |
|------|------|--------|----------|
| [x] | `src/rmf_fleet_adapter/tasks/ChargeBattery.cpp` | rmf_fleet_adapter | `_consider_restart()`에 startCharging 삽입 + unfolder에 on_cancel:stopCharging 추가 |

---

## 6. 구현 상세 (Phase 2: ChargeBattery.cpp 수정)

### 6.1 [x] `_consider_restart()`에 PerformAction("startCharging") 삽입

**파일**: `rmf_fleet_adapter/src/rmf_fleet_adapter/tasks/ChargeBattery.cpp`
**위치**: `ChargeBatteryEvent::Active::_consider_restart()` (line 469-529)

include 추가 (ChargeBattery.cpp 상단):
```cpp
#include <rmf_task_sequence/events/PerformAction.hpp>
#include "../events/PerformAction.hpp"   // fleet adapter의 PerformAction standby
```

현재 코드 (line 469-529):
```cpp
// standbys 조립
std::vector<MakeStandby> standbys;

// 1. GoToPlace
standbys.push_back([...] { return GoToPlace::Standby::make(...); });

// 2. WaitForCharge 또는 WaitForCancel
if (_desc.park) {
  standbys.push_back([...] { return WaitForCancel::Standby::make(...); });
} else {
  standbys.push_back([...] { return WaitForCharge(...); });
}
```

수정 후:
```cpp
std::vector<MakeStandby> standbys;

// 1. GoToPlace (기존 유지)
standbys.push_back([...] { return GoToPlace::Standby::make(...); });

// ==================================================================
// [PATCH] PerformAction("startCharging") 삽입 (park 모드가 아닌 경우)
// adapter의 execute_action("startCharging", ...) 콜백이 호출됨.
// adapter는 execution.finished()를 호출하지 않아 무기한 대기.
// ==================================================================
if (!_desc.park)
{
  nlohmann::json start_charging_desc;
  start_charging_desc["charging_waypoint"] = target_wp;

  auto perform_action_desc =
    rmf_task_sequence::events::PerformAction::Description::make(
      "startCharging",
      start_charging_desc,
      std::chrono::seconds(60),
      false,
      std::nullopt);

  standbys.push_back(
    [
      assign_id = _assign_id,
      context = _context,
      perform_action_desc
    ](UpdateFn update) -> StandbyPtr
    {
      return events::PerformAction::Standby::make(
        assign_id,
        context->make_get_state(),
        context->task_parameters(),
        *perform_action_desc,
        std::move(update));
    });
}
// ==================================================================

// 3. WaitForCharge 또는 WaitForCancel (기존 유지)
if (_desc.park) {
  standbys.push_back([...] { return WaitForCancel::Standby::make(...); });
} else {
  standbys.push_back([...] { return WaitForCharge(...); });
}
```

**주의**: `events::PerformAction::Standby::make()`는 fleet adapter 내부의 PerformAction
구현체(`src/rmf_fleet_adapter/events/PerformAction.hpp`)를 사용한다.
이 함수의 시그니처를 확인하여 정확한 호출 방법을 맞춰야 한다.

### 6.2 [x] `charge_battery_task_unfolder`에 on_cancel(stopCharging) 추가

**파일**: `rmf_fleet_adapter/src/rmf_fleet_adapter/tasks/ChargeBattery.cpp`
**위치**: `charge_battery_task_unfolder` (line 710-722)

현재 코드:
```cpp
auto charge_battery_task_unfolder =
  [](const rmf_task::requests::ChargeBattery::Description& desc)
  {
    rmf_task_sequence::Task::Builder builder;
    builder
    .add_phase(
      Phase::Description::make(
        std::make_shared<ChargeBatteryEvent::Description>(
          std::nullopt, desc.indefinite(), false),
        "Charge Battery", ""), {});

    return *builder.build("Charge Battery", "");
  };
```

수정 후:
```cpp
auto charge_battery_task_unfolder =
  [](const rmf_task::requests::ChargeBattery::Description& desc)
  {
    using PerformActionDesc = rmf_task_sequence::events::PerformAction::Description;

    // ==================================================================
    // [PATCH] on_cancel: stopCharging — task cancel 시 자동 실행
    // ==================================================================
    auto stop_charging_phase = Phase::Description::make(
      PerformActionDesc::make(
        "stopCharging",
        nlohmann::json{},
        std::chrono::seconds(30),
        false,
        std::nullopt),
      "Stop charging", "");

    rmf_task_sequence::Task::Builder builder;
    builder
    .add_phase(
      Phase::Description::make(
        std::make_shared<ChargeBatteryEvent::Description>(
          std::nullopt, desc.indefinite(), false),
        "Charge Battery", ""),
      {stop_charging_phase});   // ← on_cancel: stopCharging
    // ==================================================================

    return *builder.build("Charge Battery", "");
  };
```

include 추가 (이미 있는지 확인 필요):
```cpp
#include <rmf_task_sequence/events/PerformAction.hpp>
#include <nlohmann/json.hpp>
```

---

## 7. VDA5050 Fleet Adapter 측 변경

### 7.1 [x] config.yaml 변경

```yaml
# config.yaml
finishing_request: "charge"    # 기존 "charge" 그대로 사용 (compose_charge 불필요)
```

### 7.2 [x] `startCharging` / `stopCharging` action 등록

`presentation/main.py`에서:

```python
fleet_handle.add_performable_action("startCharging", consider_callback)
fleet_handle.add_performable_action("stopCharging", consider_callback)
```

### 7.3 [x] RobotAdapter에서 execute_action 처리

```python
def execute_action(self, category: str, description: dict, execution):
    if category == "startCharging":
        # 1. description에서 charging_waypoint index 추출
        # 2. nav_graph에서 charger 이름 resolve
        # 3. VDA5050 startCharging action 전송
        #    actionParameters: [{key: "stationName", value: charger_name}]
        # 4. self._charging_execution = execution (보관만 함)
        #
        # [중요] execution.finished()를 호출하지 않음!
        # → Phase가 active 상태로 유지 = 무기한 충전 대기
        pass

    elif category == "stopCharging":
        # 1. VDA5050 stopCharging action 전송
        # 2. AGV FINISHED 감지 시 → execution.finished() 호출
        pass
```

### 7.4 [x] AGV action FINISHED 처리

```python
def _on_agv_state_update(self, state):
    for action_state in state.action_states:
        if action_state.action_type == "startCharging":
            if action_state.status == "FINISHED":
                # 도킹 완료 + 충전 시작됨 → 로그만 남김
                # execution.finished()는 호출하지 않음!
                pass
            elif action_state.status == "FAILED":
                # 도킹 실패 → execution.finished() 호출
                self._charging_execution.finished()

        elif action_state.action_type == "stopCharging":
            if action_state.status == "FINISHED":
                # 언도킹 완료 → execution.finished() 호출
                self._stop_charging_execution.finished()
            elif action_state.status == "FAILED":
                # 실패해도 finished() 호출
                self._stop_charging_execution.finished()
```

### 7.5 [x] 기존 dock 기반 충전 로직 제거

Phase 2 구현 완료 후, adapter에서 다음 로직을 제거/비활성화:
- `destination.dock` 감지 → startCharging 자동 생성
- `_was_charging` 플래그 관리
- `_is_charging`, `_is_charging_pending` 상태 머신
- 다음 order 첫 노드에 stopCharging nodeAction 자동 삽입

---

## 8. 빌드 및 테스트

### 빌드 명령

```bash
cd ~/rmf_ws

# ChargeBattery.cpp 수정 후
colcon build --packages-select rmf_fleet_adapter

# Python 바인딩 변경 없음 (Phase 2에서는 adapter.cpp 수정 불필요)

# vda5050_fleet_adapter 빌드 (adapter 측 변경 시)
colcon build --packages-select vda5050_fleet_adapter
```

### 검증 포인트

1. `finishing_request: "charge"` 설정 후 fleet adapter 시작 시 에러 없이 동작하는지
2. 로봇이 idle → 충전 task 생성 시:
   - `navigate()` 콜백이 charger waypoint로 호출되는지
   - navigate 완료 후 `execute_action("startCharging", ...)` 콜백이 호출되는지
   - AGV startCharging FINISHED 후에도 Phase가 active 유지되는지
3. `recharge_threshold` 저배터리 자동 충전 시에도 동일하게 startCharging 콜백이 오는지
4. 충전 중 새 task 할당 시:
   - `execute_action("stopCharging", ...)` 콜백이 호출되는지
   - stopCharging 완료 후 새 task가 시작되는지
5. `finishing_request: "park"` 설정 시 기존대로 동작하는지 (startCharging 삽입 안 됨)

---

## 9. 참조 파일 및 코드 위치

### ChargeBattery.cpp 핵심 수정 지점

| 위치 | 함수 | 핵심 라인 | 수정 내용 |
|------|------|----------|----------|
| `_consider_restart()` | `ChargeBatteryEvent::Active` | 469-529 | GoToPlace와 WaitForCharge 사이에 PerformAction("startCharging") 삽입 |
| `charge_battery_task_unfolder` | `add_charge_battery()` | 710-722 | `add_phase()`의 cancellation_sequence에 stopCharging 추가 |

### PerformAction Standby 참조

`_consider_restart()`에서 PerformAction standby를 만들려면 fleet adapter 내부의
PerformAction 구현체를 사용해야 한다:

| 파일 | 용도 |
|------|------|
| `rmf_fleet_adapter/src/rmf_fleet_adapter/events/PerformAction.hpp` | `PerformAction::Standby::make()` — standby 생성 |
| `rmf_fleet_adapter/src/rmf_fleet_adapter/events/PerformAction.cpp:262-294` | `_execute_action()` — action_executor 호출 |
| `rmf_task_sequence/events/PerformAction.hpp` | `PerformAction::Description::make()` — description 생성 |

### on_cancel (cancellation_sequence) 관련 참조

| 파일 | 내용 | 핵심 라인 |
|------|------|----------|
| `rmf_task_sequence/Task.hpp` | `Builder::add_phase(desc, cancellation_sequence)` API | 133-135 |
| `rmf_task_sequence/Task.cpp` | `cancel()` → `_prepare_cancellation_sequence()` | 564-584, 1126-1145 |
| `rmf_task_sequence/phases/CancellationPhase.cpp` | CancellationPhase 래퍼 (cancel 불가) | 24-46 |

### TaskManager idle task 취소 흐름

```
새 task 할당
  → TaskManager::_begin_next_task() (TaskManager.cpp:1616-1749)
  → _waiting.cancel({"New task ready"}, ...) (line 1671)
  → Task::Active::cancel() (Task.cpp:564-584)
  → _prepare_cancellation_sequence([stopCharging phase]) (Task.cpp:1126-1145)
  → CancellationPhase로 래핑하여 실행 (cancel 불가)
  → stopCharging 완료 → 새 task 시작
```

---

## 10. Phase 3: idle spot 통합 검색 (parking + charger)

### 배경

현재 `finishing_request: "charge"`는 charger만, `"park"`는 parking spot만 검색한다.
로봇이 idle일 때 parking과 charger를 **통합 검색**하여 가장 가까운 곳으로 보내되,
도착지 속성에 따라 동적으로 충전/대기를 결정하는 방식으로 변경한다.

### 현재 동작 (`_consider_restart()`)

```
_desc.park == true (finishing_request: "park")
  → _find_and_sort_parking_spots()  ← is_parking_spot만 검색
  → standbys = [GoToPlace, WaitForCancel]

_desc.park == false (finishing_request: "charge")
  → dedicated_charging_wp()  ← charger만 검색
  → standbys = [GoToPlace, startCharging, WaitForCharge]
```

### 변경 후 동작

```
finishing_request: "charge" (idle 시)
  → is_parking_spot + is_charger 통합 검색 → 가장 가까운 spot 선택
  → target이 is_charger?
    ├─ YES → [GoToPlace, startCharging, WaitForCharge]  (충전)
    └─ NO  → [GoToPlace, WaitForCancel]                 (대기)

recharge_threshold 발동 (저배터리)
  → 기존대로 dedicated_charging_wp() 사용 (반드시 charger)
  → [GoToPlace, startCharging, WaitForCharge]
```

### 시나리오별 동작

| 시나리오 | 검색 대상 | 분기 기준 | 시퀀스 |
|---------|----------|----------|--------|
| idle + 가까운 곳이 charger | parking + charger | `is_charger()` | GoToPlace → startCharging → WaitForCharge |
| idle + 가까운 곳이 parking | parking + charger | `is_parking_spot()` | GoToPlace → WaitForCancel |
| 저배터리 자동 충전 | charger만 | - | GoToPlace → startCharging → WaitForCharge (변경 없음) |
| `finishing_request: "park"` | parking만 | - | GoToPlace → WaitForCancel (기존 동작 유지) |

### 5대 로봇, 3 parking + 2 charger 예시

```
nav_graph:
  parking_1 (is_parking_spot=true)
  parking_2 (is_parking_spot=true)
  parking_3 (is_parking_spot=true)
  charger_1 (is_charger=true)
  charger_2 (is_charger=true)

finishing_request: "charge"

idle 시:
  AGV_001 → parking_1 (가장 가까움) → WaitForCancel
  AGV_002 → charger_1 (가장 가까움) → startCharging → WaitForCharge
  AGV_003 → parking_2 (가장 가까움) → WaitForCancel
  AGV_004 → charger_2 (가장 가까움) → startCharging → WaitForCharge
  AGV_005 → parking_3 (가장 가까움) → WaitForCancel

저배터리 발동 시:
  어떤 로봇이든 → dedicated_charging_wp (charger) → startCharging → WaitForCharge
```

### 수정 대상 파일

| 상태 | 파일 | 수정 내용 |
|------|------|----------|
| [x] | `ChargeBattery.cpp` | `_consider_restart()` — charge 모드에서 통합 검색 + 동적 분기 |

### 구현 상세

#### 10.1 [x] `_consider_restart()` — charge 모드 통합 검색

**현재 코드** (line 435-438):
```cpp
else
{
  // Charge mode: use dedicated charging waypoint
  target_wp = _context->dedicated_charging_wp();
}
```

**수정 후**:
```cpp
else
{
  // Charge mode (idle): parking + charger 통합 검색
  if (_desc.indefinite)
  {
    // idle 충전 (indefinite=true): 통합 검색
    auto parking_spots = _context->_find_and_sort_parking_spots(true);
    std::size_t nearest_parking_wp = parking_spots.empty()
      ? std::numeric_limits<std::size_t>::max()
      : parking_spots.front().waypoint();
    double parking_cost = parking_spots.empty()
      ? std::numeric_limits<double>::max()
      : /* parking_spots.front()의 경로 비용 */;

    std::size_t charger_wp = _context->dedicated_charging_wp();
    double charger_cost = /* charger_wp까지의 경로 비용 */;

    if (parking_cost < charger_cost && !parking_spots.empty())
    {
      target_wp = nearest_parking_wp;
      // _target_is_charger = false → 나중에 standby 분기에 사용
    }
    else
    {
      target_wp = charger_wp;
      // _target_is_charger = true
    }
  }
  else
  {
    // 저배터리 충전 (indefinite=false): 반드시 charger
    target_wp = _context->dedicated_charging_wp();
  }
}
```

**경로 비용 계산**: `_find_and_sort_parking_spots()`는 이미 비용 기반으로 정렬된 결과를 반환한다.
charger까지의 비용은 `_context`의 planner를 통해 계산해야 한다.
또는 `_find_and_sort_parking_spots()`를 확장하여 charger waypoint도 포함시키는 방법도 가능하다.

#### 10.2 [x] standby 조립 — 동적 분기

**현재**: `_desc.park` 플래그로 분기 (task 생성 시 결정)
**수정**: `target_wp`의 graph 속성으로 분기 (runtime 결정)

```cpp
// target waypoint의 속성 확인
const auto& graph = _context->navigation_graph();
bool target_is_charger = graph.get_waypoint(target_wp).is_charger();

// GoToPlace (공통)
standbys.push_back(GoToPlace(target_wp));

// charger인 경우만 startCharging 삽입
if (target_is_charger && !_desc.park)
{
  standbys.push_back(PerformAction("startCharging"));
}

// charger → WaitForCharge, parking → WaitForCancel
if (target_is_charger && !_desc.park)
{
  standbys.push_back(WaitForCharge(...));
}
else
{
  standbys.push_back(WaitForCancel());
}
```

#### 10.3 [x] on_cancel 동적 처리

**문제**: `charge_battery_task_unfolder`에서 on_cancel(stopCharging)을 정적으로 추가하는데,
parking spot으로 간 경우에는 stopCharging이 불필요하다.

**해결 방안**:
- on_cancel에 stopCharging이 포함되어 있어도, parking spot에서는 RMF가 task cancel 시
  adapter에 `execute_action("stopCharging")` 콜백이 호출됨
- adapter 측에서 charger에 있지 않으면 즉시 `execution.finished()` 호출하여 skip 처리
- 또는 `_desc.park` 대신 runtime 분기로 on_cancel 포함 여부를 결정
  (단, unfolder 시점에는 target을 모르므로 항상 포함하고 adapter에서 처리하는 것이 현실적)

**adapter 측 stopCharging 처리 (robot_adapter.py)**:
```python
def _handle_stop_charging(self, description, execution):
    if self._charger_name is None:
        # parking spot에서 호출됨 → charger가 아니므로 즉시 완료
        execution.finished()
        return
    # charger에서 호출됨 → VDA5050 stopCharging 전송
    ...
```

#### 10.4 [x] 통합 검색 구현 (기존 API 활용)

**방안 A**: 기존 `_find_and_sort_parking_spots()`에 charger 포함 옵션 추가
```cpp
// RobotContext.cpp
std::vector<Plan::Goal> _find_and_sort_available_spots(
  bool same_floor, bool include_chargers = false) const
{
  for (std::size_t wp_idx = 0; wp_idx < graph.num_waypoints(); ++wp_idx)
  {
    const auto& wp = graph.get_waypoint(wp_idx);
    if (wp.is_parking_spot() || (include_chargers && wp.is_charger()))
    {
      // 경로 비용 계산 + 정렬
    }
  }
}
```

**방안 B**: `_consider_restart()` 내에서 parking_spots와 charger를 각각 검색 후 비용 비교
- 추가 함수 없이 기존 API만 활용
- 단, charger까지의 비용 계산을 위해 planner 접근 필요

### 주의사항

#### `_desc.park`과 `_desc.indefinite`의 역할 변경

| 플래그 | 현재 의미 | 변경 후 의미 |
|--------|----------|-------------|
| `_desc.park` | `finishing_request: "park"` | 기존 유지 (parking spot만 검색) |
| `_desc.indefinite` | idle 충전 (무기한) vs 저배터리 충전 (SOC 목표) | idle이면 통합 검색, 저배터리면 charger만 |
| (신규) `target_is_charger` | - | runtime에 target wp 속성으로 결정 |

#### `charge_battery_task_unfolder`의 on_cancel

- on_cancel(stopCharging)은 **항상 포함** (unfolder 시점에 target을 모름)
- parking spot에서 cancel 시 adapter가 즉시 `execution.finished()` → 실질적으로 no-op

#### 저배터리 자동 충전은 변경 없음

`_desc.indefinite == false` (recharge_threshold 발동)인 경우:
- 반드시 charger로 이동하여 충전해야 함
- 통합 검색 대상이 아님
- 기존 `dedicated_charging_wp()` 그대로 사용

---

## 11. 주의사항

### add_performable_action 등록 필수

fleet adapter가 두 action 모두 등록해야 한다:

```python
fleet_handle.add_performable_action("startCharging", consider_callback)
fleet_handle.add_performable_action("stopCharging", consider_callback)
```

### park 모드 영향 없음

`_desc.park == true`인 경우 (ParkRobotIndefinitely) startCharging을 삽입하지 않는다.
park 모드는 기존대로 GoToPlace + WaitForCancel만 실행.

### Phase 1 폐기 완료

아래 항목 모두 처리됨:
1. ~~`ComposeCharging.hpp`, `ComposeCharging.cpp` 파일 삭제~~
2. ~~`EasyFullControl.cpp`의 `[PATCH] ComposeCharging` 코드 제거~~
3. ~~`adapter.cpp`의 `[PATCH] ComposeCharging` 코드 제거~~
4. ~~`rmf_core_patch.md`에서 패치 2 항목 제거~~

### PerformAction::Standby::make() 시그니처 확인 필요

`_consider_restart()`에서 사용하는 `events::PerformAction::Standby::make()`의 정확한 시그니처를
`src/rmf_fleet_adapter/events/PerformAction.hpp`에서 확인해야 한다.
GoToPlace::Standby::make()와 유사한 패턴이지만, PerformAction 전용 파라미터가 다를 수 있다.
