# RMF Core 패치 목록

이 문서는 `src/rmf/` 하위의 Open-RMF 원본 소스에 적용된 모든 `[PATCH]` 수정 사항을 기록한다.
모든 패치는 소스 코드에서 `// [PATCH]` 키워드로 검색하여 찾을 수 있다.

---

## 패치 1: Destination에 final_name / waypoint_names 추가

**목적**: RMF가 `navigate()` 콜백으로 전달하는 `Destination` 객체에 plan의 최종 목적지 이름과
전체 경로 waypoint 이름 목록을 포함시킨다. 기존에는 ROS topic(`planned_path`)으로 경로 정보를
받았으나, DDS 타이밍 이슈로 인해 Destination 객체에 직접 담아 전달하는 방식으로 변경.

**VDA5050 용도**: Base/Horizon 분리, 최종 목적지 기반 Tier 2 경로 확장에 사용.

### 수정 파일

#### 1-1. `rmf_fleet_adapter/include/rmf_fleet_adapter/agv/EasyFullControl.hpp`

| 라인 | 패치 설명 |
|------|----------|
| 470-477 | `[PATCH] final_name()` 접근자 선언 — plan의 최종 목적지 waypoint 이름 |
| 478-482 | `[PATCH] waypoint_names()` 접근자 선언 — planned_path 전체 waypoint 이름 목록 |

```cpp
// ==================================================================
// [PATCH] The name of the final waypoint in the full planned path.
// This is the ultimate destination for the current plan, not just
// the immediate next waypoint. Useful for VDA5050 Base/Horizon
// separation where you need to know the end goal of the entire plan.
// ==================================================================
std::string final_name() const;
// ==================================================================
// [PATCH] waypoint_names: planned_path의 전체 waypoint 이름 목록
// ROS topic 대신 Destination 객체로 직접 전달하여 DDS 타이밍 이슈 제거
// ==================================================================
std::vector<std::string> waypoint_names() const;
```

#### 1-2. `rmf_fleet_adapter/src/rmf_fleet_adapter/agv/internal_EasyFullControl.hpp`

| 라인 | 패치 설명 |
|------|----------|
| 88-92 | `[PATCH] final_name` 멤버 변수 추가 |
| 93-97 | `[PATCH] waypoint_names` 멤버 변수 추가 |

```cpp
// ==================================================================
// [PATCH] final_name: waypoints.back()의 이름 (plan의 최종 목적지)
// ParkRobot, ChargeBattery 등 auto-generated task 대응용
// ==================================================================
std::string final_name;
// ==================================================================
// [PATCH] waypoint_names: planned_path의 전체 waypoint 이름 목록
// ROS topic 대신 Destination 객체로 직접 전달하여 DDS 타이밍 이슈 제거
// ==================================================================
std::vector<std::string> waypoint_names;
```

#### 1-3. `rmf_fleet_adapter/src/rmf_fleet_adapter/agv/EasyFullControl.cpp`

| 라인 | 패치 설명 |
|------|----------|
| 807-813 | `[PATCH] final_name()` 접근자 구현 |
| 814-820 | `[PATCH] waypoint_names()` 접근자 구현 |
| 1067-1075 | `[PATCH] plan_final_name` — RobotContext에서 최종 목적지 이름 가져오기 |
| 1127-1150 | `[PATCH] plan_waypoint_names` 빌드 — waypoints에서 이름 목록 생성 |
| 1394-1408 | `[PATCH] Destination::make()` 호출에 final_name + waypoint_names 전달 (일반 이동) |
| 1525-1538 | `[PATCH] Destination::make()` 호출에 전달 (rotation command) |
| 1586-1600 | `[PATCH] Destination::make()` 호출에 전달 (relocalize) |
| 1885-1898 | `[PATCH] Destination::make()` 호출에 전달 (dock rotation, 빈 값) |
| 1955-1970 | `[PATCH] Destination::make()` 호출에 전달 (dock command, 빈 값) |

#### 1-4. `rmf_fleet_adapter/src/rmf_fleet_adapter/events/ExecutePlan.cpp`

| 라인 | 패치 설명 |
|------|----------|
| 885-896 | `[PATCH] set_plan_final_name()` — Goal에서 최종 목적지 이름을 계산하여 RobotContext에 저장 |

```cpp
// [PATCH] Store the actual final destination name in context so that
// follow_new_path() can read it even when it only receives a partial segment.
if (const auto nav = context->nav_params())
{
  context->set_plan_final_name(
    nav->get_vertex_name(graph, std::optional<std::size_t>(goal.waypoint())));
}
```

#### 1-5. `rmf_fleet_adapter_python/src/adapter.cpp`

| 라인 | 패치 설명 |
|------|----------|
| 1083-1086 | `[PATCH] final_name` Python 바인딩 (Destination.final_name property) |
| 1087-1091 | `[PATCH] waypoint_names` Python 바인딩 (Destination.waypoint_names property) |

```cpp
// ==================================================================
// [PATCH] plan의 최종 목적지 waypoint 이름 (VDA5050 Base/Horizon용)
// ==================================================================
.def_property_readonly("final_name", &agv::EasyFullControl::Destination::final_name)
// ==================================================================
// [PATCH] waypoint_names: planned_path 전체 경로를 Destination으로 전달
// ROS topic 대신 직접 전달하여 DDS 타이밍 이슈 제거
// ==================================================================
.def_property_readonly("waypoint_names",
    &agv::EasyFullControl::Destination::waypoint_names)
```

---

## 패치 2: ChargeBattery에 startCharging/stopCharging PerformAction 삽입

**목적**: 모든 충전 경로(idle 충전, 저배터리 자동 충전)에서 RMF core가 명시적으로
`startCharging`/`stopCharging`을 adapter에 `execute_action()` 콜백으로 전달한다.
기존 adapter의 dock 추론 방식을 대체.

**동작 구조**:
- Phase 1: `GoToPlace` (charger waypoint로 이동) → `navigate()` 콜백
- Phase 2: `PerformAction("startCharging")` → `execute_action()` 콜백 (park 모드 제외)
- Phase 3: `WaitForCharge` (SOC 대기)
- on_cancel: `PerformAction("stopCharging")` → task cancel 시 자동 실행

### 수정 파일

#### 2-1. `rmf_fleet_adapter/src/rmf_fleet_adapter/tasks/ChargeBattery.cpp`

| 위치 | 패치 설명 |
|------|----------|
| 21-24 | `[PATCH]` include 추가: `PerformAction.hpp` (fleet adapter 내부) |
| 30-33 | `[PATCH]` include 추가: `rmf_task_sequence/events/PerformAction.hpp` |
| 489-525 | `[PATCH] _consider_restart()`에 PerformAction("startCharging") standby 삽입 |
| 744-771 | `[PATCH] charge_battery_task_unfolder`에 on_cancel: stopCharging phase 추가 |

---

## 패치 검색 방법

모든 패치는 아래 명령으로 찾을 수 있다:

```bash
grep -rn "\[PATCH\]" src/rmf/
```

---

## 빌드 영향 패키지

| 패키지 | 패치 | 빌드 명령 |
|--------|------|----------|
| `rmf_fleet_adapter` | 패치 1, 2 | `colcon build --packages-select rmf_fleet_adapter` |
| `rmf_fleet_adapter_python` | 패치 1 | `colcon build --packages-select rmf_fleet_adapter_python` |

`CMakeLists.txt`는 `GLOB_RECURSE`를 사용하므로 신규 `.cpp` 파일 추가 시 별도 수정 불필요.
