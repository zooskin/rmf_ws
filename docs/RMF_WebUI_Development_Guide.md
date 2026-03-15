# RMF Web UI 개발 가이드

## 1. 시스템 아키텍처 개요

```
                    ┌─────────────────────────────────────┐
                    │         Web UI (Browser)            │
                    │    http://localhost:3000             │
                    └───────────┬──────────┬──────────────┘
                       REST API │          │ Socket.IO (실시간)
                                │          │
                    ┌───────────▼──────────▼──────────────┐
                    │     RMF API Server (Python)         │
                    │    http://localhost:8100             │
                    │    - FastAPI + Socket.IO             │
                    │    - JWT 인증                        │
                    │    - SQLite DB                       │
                    │    - Swagger: /docs                  │
                    └───────────┬──────────┬──────────────┘
                  ROS2 토픽 구독 │          │ /_internal WebSocket
                                │          │
             ┌──────────────────┤          │
             │                  │          │
    ┌────────▼────────┐  ┌─────▼──────┐  ┌▼────────────────────┐
    │  RMF Core       │  │ Building   │  │ VDA5050 Fleet       │
    │  - Schedule     │  │ Map Server │  │ Adapter             │
    │  - Dispatcher   │  │            │  │ (fleet/task 상태 전송)│
    │  - Blockade     │  └────────────┘  └─────────┬───────────┘
    └─────────────────┘                            │ MQTT
                                          ┌────────▼────────┐
                                          │  AGV_001/002    │
                                          │  (VDA5050 로봇)  │
                                          └─────────────────┘
```

### 데이터 흐름

| 데이터 | 경로 | 설명 |
|--------|------|------|
| Robot/Fleet 상태 | Fleet Adapter → `/_internal` WebSocket → API Server → Socket.IO → Web UI | fleet adapter가 C++ 라이브러리 내부에서 자동 전송 |
| Door/Lift 상태 | ROS2 토픽 (`/door_states`, `/lift_states`) → API Server → Socket.IO → Web UI | gateway.py가 ROS2 토픽 직접 구독 |
| Building Map | `building_map_server` → ROS2 `/map` 토픽 → API Server → REST/Socket.IO → Web UI | 맵 이미지 포함 |
| Task 명령 | Web UI → REST API → API Server → ROS2 `/task_api_requests` → Dispatcher/Fleet Adapter | 양방향 |

---

## 2. API Server 연결 정보

| 항목 | 값 |
|------|-----|
| Base URL | `http://localhost:8100` |
| Swagger UI | `http://localhost:8100/docs` |
| Socket.IO | `http://localhost:8100` (socket.io 클라이언트로 연결) |
| 인증 방식 | JWT (HS256) |
| JWT Secret | `rmfisawesome` |
| JWT Issuer (iss) | `stub` |
| JWT Audience (aud) | `rmf_api_server` |

### 인증 토큰 생성 예시

```javascript
// StubAuthenticator 방식 (개발용)
import jwt from 'jsonwebtoken';

const token = jwt.sign(
  {
    aud: 'rmf_api_server',
    iss: 'stub',
    preferred_username: 'admin',
  },
  'rmfisawesome'
);

// HTTP 요청 시
headers: { 'Authorization': `Bearer ${token}` }

// Socket.IO 연결 시
socket.emit('connect', { token: token });
```

---

## 3. REST API 엔드포인트

### 3.1 Fleet / Robot

| Method | Path | 설명 | 응답 모델 |
|--------|------|------|-----------|
| GET | `/fleets` | 전체 fleet 목록 (로봇 포함) | `FleetState[]` |
| GET | `/fleets/{name}/state` | 특정 fleet 상태 | `FleetState` |
| GET | `/fleets/{name}/log` | Fleet 로그 (query: `between`) | `FleetLog` |
| POST | `/fleets/{name}/decommission` | 로봇 비활성화 (query: `robot_name`, `reassign_tasks`) | `RobotCommissionResponse` |
| POST | `/fleets/{name}/recommission` | 로봇 재활성화 (query: `robot_name`) | `RobotCommissionResponse` |
| POST | `/fleets/{name}/unlock_mutex_group` | Mutex 그룹 수동 해제 | - |

### 3.2 Task

| Method | Path | 설명 | 응답 모델 |
|--------|------|------|-----------|
| GET | `/tasks` | 태스크 목록 조회 (필터/페이지네이션 지원) | `TaskState[]` |
| GET | `/tasks/{task_id}/state` | 태스크 상태 | `TaskState` |
| GET | `/tasks/{task_id}/request` | 태스크 원본 요청 | `TaskRequest` |
| GET | `/tasks/{task_id}/log` | 태스크 이벤트 로그 | `TaskEventLog` |
| POST | `/tasks/dispatch_task` | **태스크 디스패치 (핵심)** | `TaskDispatchResponse` |
| POST | `/tasks/robot_task` | 특정 로봇에 직접 태스크 할당 | `RobotTaskResponse` |
| POST | `/tasks/cancel_task` | 태스크 취소 | `TaskCancelResponse` |
| POST | `/tasks/interrupt_task` | 태스크 중단 | `TaskInterruptionResponse` |
| POST | `/tasks/kill_task` | 태스크 강제 종료 | `TaskKillResponse` |
| POST | `/tasks/resume_task` | 태스크 재개 | `TaskResumeResponse` |

#### 태스크 조회 필터 파라미터 (`GET /tasks`)

| 파라미터 | 타입 | 설명 |
|----------|------|------|
| `task_id` | string | 태스크 ID 필터 |
| `category` | string | 태스크 카테고리 (patrol, compose 등) |
| `status` | string | 상태 (queued, underway, completed, failed 등) |
| `assigned_to` | string | 할당된 로봇/fleet |
| `requester` | string | 요청자 |
| `request_time_between` | string | 요청 시간 범위 |
| `start_time_between` | string | 시작 시간 범위 |
| `finish_time_between` | string | 완료 시간 범위 |
| `label` | string | 라벨 필터 |
| `limit` | int | 페이지 크기 |
| `offset` | int | 오프셋 |
| `order_by` | string | 정렬 기준 (예: `-unix_millis_start_time`) |

### 3.3 Building Map

| Method | Path | 설명 | 응답 모델 |
|--------|------|------|-----------|
| GET | `/building_map` | 건물 맵 (층, waypoint, door, lift 포함) | `BuildingMap` |
| GET | `/building_map/previous_fire_alarm_trigger` | 이전 화재 알람 상태 | `FireAlarmTriggerState` |
| POST | `/building_map/reset_fire_alarm_trigger` | 화재 알람 리셋 | `FireAlarmTriggerState` |

### 3.4 Door / Lift

| Method | Path | 설명 | 응답 모델 |
|--------|------|------|-----------|
| GET | `/doors` | 전체 door 목록 | `Door[]` |
| GET | `/doors/{door_name}/state` | Door 상태 | `DoorState` |
| POST | `/doors/{door_name}/request` | Door 제어 요청 | - |
| GET | `/lifts` | 전체 lift 목록 | `Lift[]` |
| GET | `/lifts/{lift_name}/state` | Lift 상태 | `LiftState` |
| POST | `/lifts/{lift_name}/request` | Lift 제어 요청 | - |

### 3.5 Alert

| Method | Path | 설명 | 응답 모델 |
|--------|------|------|-----------|
| GET | `/alerts/unresponded_requests` | 미응답 알림 목록 | `AlertRequest[]` |
| GET | `/alerts/request/{alert_id}` | 특정 알림 | `AlertRequest` |
| GET | `/alerts/requests/task/{task_id}` | 태스크별 알림 | `AlertRequest[]` |
| POST | `/alerts/request` | 알림 생성 | `AlertRequest` |
| POST | `/alerts/request/{alert_id}/respond` | 알림 응답 | `AlertResponse` |

### 3.6 Scheduled / Favorite Task

| Method | Path | 설명 |
|--------|------|------|
| GET | `/scheduled_tasks` | 예약 태스크 목록 |
| POST | `/scheduled_tasks` | 예약 태스크 생성 |
| POST | `/scheduled_tasks/{task_id}/update` | 예약 태스크 수정 |
| DELETE | `/scheduled_tasks/{task_id}` | 예약 태스크 삭제 |
| GET | `/favorite_tasks` | 즐겨찾기 태스크 목록 |
| POST | `/favorite_tasks` | 즐겨찾기 저장 |
| DELETE | `/favorite_tasks/{id}` | 즐겨찾기 삭제 |

### 3.7 기타

| Method | Path | 설명 |
|--------|------|------|
| GET | `/user` | 현재 로그인 사용자 |
| GET | `/permissions` | 현재 사용자 권한 |
| GET | `/time` | RMF 시스템 시간 (unix ms) |
| GET | `/dispensers` | Dispenser 목록 |
| GET | `/ingestors` | Ingestor 목록 |
| GET | `/beacons` | Beacon 목록 |

---

## 4. Socket.IO 실시간 이벤트

Web UI에서 실시간 데이터를 받으려면 Socket.IO 클라이언트로 연결 후 room을 subscribe합니다.

### 연결 방법

```javascript
import { io } from 'socket.io-client';

const socket = io('http://localhost:8100', {
  auth: { token: jwtToken },
});

// room 구독
socket.emit('subscribe', { room: '/fleets/vda5050_fleet/state' });

// 데이터 수신
socket.on('/fleets/vda5050_fleet/state', (data) => {
  console.log('Fleet state update:', data);
});
```

### 구독 가능한 Room 목록

| Room | 데이터 | 설명 |
|------|--------|------|
| `/fleets/{name}/state` | `FleetState` | 로봇 상태 (위치, 배터리, 태스크 등) |
| `/fleets/{name}/log` | `FleetLog` | Fleet 로그 |
| `/tasks/{task_id}/state` | `TaskState` | 태스크 진행 상태 |
| `/tasks/{task_id}/log` | `TaskEventLog` | 태스크 이벤트 로그 |
| `/doors/{door_name}/state` | `DoorState` | Door 상태 |
| `/lifts/{lift_name}/state` | `LiftState` | Lift 상태 |
| `/building_map` | `BuildingMap` | 건물 맵 변경 |
| `/alerts/requests` | `AlertRequest` | 새 알림 |
| `/alerts/responses` | `AlertResponse` | 알림 응답 |
| `/beacons` | `BeaconState` | Beacon 상태 |
| `/dispensers/{guid}/state` | `DispenserState` | Dispenser 상태 |
| `/ingestors/{guid}/state` | `IngestorState` | Ingestor 상태 |

---

## 5. 주요 데이터 모델

### 5.1 FleetState

```json
{
  "name": "vda5050_fleet",
  "robots": {
    "AGV_001": {
      "name": "AGV_001",
      "status": "idle",          // uninitialized, offline, shutdown, idle, charging, working, error
      "task_id": "task-abc123",
      "unix_millis_time": 1773561373000,
      "location": {
        "map": "L1",
        "x": 10.43,
        "y": -5.58,
        "yaw": -1.81
      },
      "battery": 0.95,           // 0.0 ~ 1.0
      "issues": [],
      "commission": {
        "dispatch_tasks": true,
        "direct_tasks": true,
        "idle_behavior": true
      },
      "mutex_groups": {
        "locked": [],
        "requesting": []
      }
    },
    "AGV_002": { ... }
  }
}
```

### 5.2 TaskState

```json
{
  "booking": {
    "id": "delivery_xxxx-xxxx",
    "unix_millis_earliest_start_time": 0,
    "unix_millis_request_time": 1773561373000,
    "priority": { "type": "binary", "value": 0 },
    "labels": ["task_definition_id=cart_delivery", "pickup=pantry", "destination=coe"],
    "requester": "admin"
  },
  "category": "compose",
  "unix_millis_start_time": 1773561375000,
  "unix_millis_finish_time": null,
  "estimate_millis": 30000,
  "assigned_to": {
    "group": "vda5050_fleet",
    "name": "AGV_001"
  },
  "status": "underway",          // queued, standby, underway, delayed, completed, failed, canceled, killed
  "dispatch": {
    "status": "dispatched",      // queued, selected, dispatched, failed_to_assign, canceled_in_flight
    "assignment": {
      "fleet_name": "vda5050_fleet",
      "expected_robot_name": "AGV_001"
    }
  },
  "phases": {
    "1": {
      "id": 1,
      "category": "Go to pickup",
      "unix_millis_start_time": 1773561375000,
      "estimate_millis": 15000,
      "events": { ... }
    }
  },
  "completed": [1],
  "active": 2,
  "pending": []
}
```

### 5.3 BuildingMap

```json
{
  "name": "building",
  "levels": [
    {
      "name": "L1",
      "elevation": 0.0,
      "images": [
        {
          "name": "office",
          "x_offset": -1.6,
          "y_offset": -12.38,
          "yaw": 0.0,
          "scale": 0.047,
          "encoding": "png",
          "data": "/cache/office.png"  // API 서버에서 제공하는 이미지 URL
        }
      ],
      "places": [
        { "name": "pantry", "x": 16.85, "y": -5.40, "yaw": 0.0 },
        { "name": "coe", "x": 5.35, "y": -4.98, "yaw": 0.0 },
        { "name": "tinyRobot1_charger", "x": 10.43, "y": -5.58, "yaw": 0.0 }
      ],
      "doors": [
        {
          "name": "main_door",
          "v1_x": 12.18, "v1_y": -2.60,
          "v2_x": 14.08, "v2_y": -2.56,
          "door_type": "double_hinged"
        }
      ],
      "nav_graphs": [
        {
          "name": "0",
          "vertices": [ ... ],
          "edges": [ ... ]
        }
      ]
    }
  ],
  "lifts": []
}
```

---

## 6. 태스크 디스패치 (POST /tasks/dispatch_task)

### 6.1 Patrol Task

```json
{
  "type": "dispatch_task_request",
  "request": {
    "category": "patrol",
    "description": {
      "places": ["pantry", "coe", "lounge"],
      "rounds": 2
    },
    "unix_millis_earliest_start_time": 0,
    "unix_millis_request_time": 1773561373000,
    "priority": { "type": "binary", "value": 0 },
    "requester": "admin",
    "labels": ["task_definition_id=patrol"]
  }
}
```

### 6.2 Cart Delivery Task (커스텀)

pickup 장소에서 물건을 pick하고, dropoff 장소로 이동해서 drop하는 2-phase compose 태스크입니다.

```json
{
  "type": "dispatch_task_request",
  "request": {
    "category": "compose",
    "description": {
      "category": "delivery",
      "phases": [
        {
          "activity": {
            "category": "sequence",
            "description": {
              "activities": [
                {
                  "category": "go_to_place",
                  "description": "pantry"
                },
                {
                  "category": "perform_action",
                  "description": {
                    "unix_millis_action_duration_estimate": 10000,
                    "category": "pick",
                    "description": {
                      "loadType": "Tool",
                      "loadID": "SP4ECTR002"
                    },
                    "use_tool_sink": false
                  }
                }
              ]
            }
          }
        },
        {
          "activity": {
            "category": "sequence",
            "description": {
              "activities": [
                {
                  "category": "go_to_place",
                  "description": "coe"
                },
                {
                  "category": "perform_action",
                  "description": {
                    "unix_millis_action_duration_estimate": 10000,
                    "category": "drop",
                    "description": {
                      "stationName": "1004"
                    },
                    "use_tool_sink": false
                  }
                }
              ]
            }
          }
        }
      ]
    },
    "unix_millis_earliest_start_time": 0,
    "unix_millis_request_time": 1773561373000,
    "priority": { "type": "binary", "value": 0 },
    "requester": "admin",
    "labels": ["task_definition_id=cart_delivery", "pickup=pantry", "destination=coe"]
  }
}
```

### Cart Delivery 필드 설명

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| pickup (Phase 1 - go_to_place) | string | O | 픽업 waypoint 이름 |
| loadType | string | O | 적재물 유형 (예: "Tool", "Pallet") |
| loadID | string | O | 적재물/카트 고유 ID (예: "SP4ECTR002") |
| dropoff (Phase 2 - go_to_place) | string | O | 드롭오프 waypoint 이름 |
| stationName | string | O | 드롭오프 스테이션 이름 (예: "1004") |

---

## 7. 현재 시스템의 Waypoint 목록

맵(`L1`)에 정의된 사용 가능한 waypoint:

| Waypoint | 좌표 (x, y) | 용도 |
|----------|-------------|------|
| `tinyRobot1_charger` | (10.43, -5.58) | AGV_001 충전소 |
| `tinyRobot2_charger` | (20.42, -5.31) | AGV_002 충전소 |
| `pantry` | (16.85, -5.40) | 배달 거점 (dispenser) |
| `coe` | (5.35, -4.98) | 배달 거점 (ingestor) |
| `hardware_2` | (20.95, -7.50) | 배달 거점 (ingestor) |
| `lounge` | (20.64, -3.99) | 대기 지점 |
| `supplies` | (6.53, -3.25) | 공급 지점 (주차) |
| `patrol_A1` | - | 순찰 경로 |
| `patrol_A2` | - | 순찰 경로 |
| `patrol_B` | - | 순찰 경로 |
| `patrol_C` | - | 순찰 경로 |
| `patrol_D1` | - | 순찰 경로 |
| `patrol_D2` | - | 순찰 경로 |

Door 목록:
| Door | 타입 |
|------|------|
| `main_door` | double_hinged |
| `coe_door` | hinged |
| `hardware_door` | hinged |

---

## 8. 현재 로봇 정보

| 로봇 | Fleet | 충전소 | 프로토콜 |
|------|-------|--------|----------|
| AGV_001 | vda5050_fleet | tinyRobot1_charger | VDA5050 via MQTT |
| AGV_002 | vda5050_fleet | tinyRobot2_charger | VDA5050 via MQTT |

### 로봇 물리 스펙

| 항목 | 값 |
|------|-----|
| 최대 속도 (선형) | 0.5 m/s |
| 최대 가속 (선형) | 0.75 m/s^2 |
| 최대 속도 (회전) | 0.6 rad/s |
| Footprint | 0.3 m |
| Vicinity | 0.5 m |
| 배터리 | 12V / 24Ah |
| 자동충전 임계값 | 40% 이하 |
| 충전 목표 | 80% |

### 지원 액션

| 액션 | 설명 |
|------|------|
| `pick` | 물건 픽업 (loadType, loadID 필요) |
| `drop` | 물건 드롭 (stationName 필요) |
| `teleop` | 원격 조종 |

---

## 9. 개발 시 참고 사항

### 9.1 기술 스택 권장

- **프론트엔드**: React 18 + TypeScript
- **HTTP 클라이언트**: Axios
- **실시간 통신**: socket.io-client
- **맵 렌더링**: Three.js / React Three Fiber (현재 레퍼런스), 또는 Leaflet/Canvas 등 자유
- **UI 프레임워크**: 자유 (현재 레퍼런스는 MUI)

### 9.2 API 문서 자동 생성

API Server가 실행 중이면 `http://localhost:8100/docs`에서 Swagger UI로 전체 API를 확인/테스트할 수 있습니다.

### 9.3 개발 환경 설정

```bash
# 전체 RMF 시스템 실행
cd /home/hansoo/rmf_ws
docker compose up -d

# Web UI만 로컬 개발 서버로 실행 (API Server는 Docker로 유지)
# API Server: http://localhost:8100
# Web UI 개발 서버에서 위 주소로 API 호출
```

### 9.4 CORS

API Server는 기본적으로 모든 origin을 허용합니다. 별도 CORS 설정 불필요.

### 9.5 주의 사항

- 태스크 디스패치 시 `labels` 배열에 `task_definition_id` 를 반드시 포함해야 태스크 유형 식별이 가능합니다.
- Socket.IO 연결 시 인증 토큰이 필요합니다.
- `/_internal` WebSocket은 인증 없이 접근 가능하나, 이는 fleet adapter 전용이므로 Web UI에서는 사용하지 않습니다.
- Door/Lift 상태는 실제 시뮬레이션 또는 하드웨어에서 상태를 발행해야만 데이터가 표시됩니다.
- 맵 이미지는 API Server가 캐시하여 제공합니다 (`/cache/` 경로).

### 9.6 레퍼런스 소스 코드

| 항목 | 경로 |
|------|------|
| API Server 소스 | `packages/api-server/api_server/` |
| API 라우트 정의 | `packages/api-server/api_server/routes/` |
| 데이터 모델 | `packages/api-server/api_server/models/` |
| 현재 대시보드 소스 | `packages/rmf-dashboard-framework/` |
| 대시보드 데모 앱 | `packages/rmf-dashboard-framework/examples/demo/main.tsx` |
| Cart Delivery 태스크 폼 | `packages/rmf-dashboard-framework/src/components/tasks/types/cart-delivery.tsx` |
| Cart Delivery CLI 스크립트 | `src/vda5050_fleet_adapter/vda5050_fleet_adapter/scripts/dispatch_delivery.py` |
