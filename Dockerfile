ARG ROS_DISTRO=jazzy

# ==============================================================================
# Stage 1: Build (rmf_fleet_adapter 제외한 나머지 — 캐시 레이어)
# ==============================================================================
FROM ros:${ROS_DISTRO}-ros-base AS builder-base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /rmf_ws

# rmf_fleet_adapter, rmf_fleet_adapter_python 제외한 소스 복사
# → 이 레이어는 패치 파일 변경 시에도 캐시 유지
COPY src/rmf/ament_cmake_catch2 src/rmf/ament_cmake_catch2
COPY src/rmf/rmf_api_msgs src/rmf/rmf_api_msgs
COPY src/rmf/rmf_battery src/rmf/rmf_battery
COPY src/rmf/rmf_building_map_msgs src/rmf/rmf_building_map_msgs
COPY src/rmf/rmf_internal_msgs src/rmf/rmf_internal_msgs
COPY src/rmf/rmf_simulation src/rmf/rmf_simulation
COPY src/rmf/rmf_task src/rmf/rmf_task
COPY src/rmf/rmf_traffic src/rmf/rmf_traffic
COPY src/rmf/rmf_traffic_editor src/rmf/rmf_traffic_editor
COPY src/rmf/rmf_utils src/rmf/rmf_utils
COPY src/rmf/rmf_visualization src/rmf/rmf_visualization
COPY src/rmf/rmf_visualization_msgs src/rmf/rmf_visualization_msgs
# rmf_ros2 내부에서 fleet_adapter 제외
COPY src/rmf/rmf_ros2/rmf_charging_schedule src/rmf/rmf_ros2/rmf_charging_schedule
COPY src/rmf/rmf_ros2/rmf_reservation_node src/rmf/rmf_ros2/rmf_reservation_node
COPY src/rmf/rmf_ros2/rmf_task_ros2 src/rmf/rmf_ros2/rmf_task_ros2
COPY src/rmf/rmf_ros2/rmf_traffic_ros2 src/rmf/rmf_ros2/rmf_traffic_ros2
COPY src/rmf/rmf_ros2/rmf_websocket src/rmf/rmf_ros2/rmf_websocket
COPY src/thirdparty src/thirdparty

# Install dependencies via rosdep
ARG ROS_DISTRO=jazzy
RUN apt-get update \
    && rosdep update --rosdistro ${ROS_DISTRO} \
    && rosdep install --from-paths src --ignore-src --rosdistro ${ROS_DISTRO} -yr \
    && rm -rf /var/lib/apt/lists/*

# Build (fleet_adapter 제외) — 변경 없으면 캐시됨
RUN . /opt/ros/${ROS_DISTRO}/setup.sh \
    && colcon build \
        --cmake-args -DCMAKE_BUILD_TYPE=Release \
        --event-handlers console_direct+

# ==============================================================================
# Stage 2: Build rmf_fleet_adapter + python bindings (패치 변경 시 여기만 재빌드)
# ==============================================================================
FROM builder-base AS builder

# 자주 수정되는 패키지만 복사 — 캐시 무효화 범위 최소화
COPY src/rmf/rmf_ros2/rmf_fleet_adapter src/rmf/rmf_ros2/rmf_fleet_adapter
COPY src/rmf/rmf_ros2/rmf_fleet_adapter_python src/rmf/rmf_ros2/rmf_fleet_adapter_python

ARG ROS_DISTRO=jazzy
RUN . /opt/ros/${ROS_DISTRO}/setup.sh \
    && . install/setup.sh \
    && colcon build \
        --packages-select rmf_fleet_adapter rmf_fleet_adapter_python \
        --cmake-args -DCMAKE_BUILD_TYPE=Release \
        --event-handlers console_direct+

# ==============================================================================
# Stage 3: Runtime
# ==============================================================================
FROM ros:${ROS_DISTRO}-ros-base AS runtime

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /rmf_ws

# Copy source for rosdep to resolve runtime deps
COPY --from=builder /rmf_ws/src src

ARG ROS_DISTRO=jazzy
RUN apt-get update \
    && rosdep update --rosdistro ${ROS_DISTRO} \
    && rosdep install --from-paths src --ignore-src --rosdistro ${ROS_DISTRO} -yr \
        --dependency-types exec \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf src

# Copy built install space
COPY --from=builder /rmf_ws/install install

# CycloneDDS + vda5050_fleet_adapter Python 의존성
ARG ROS_DISTRO=jazzy
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
        python3-pip \
    && pip3 install --no-cache-dir --break-system-packages \
        "paho-mqtt>=2.0" pyyaml networkx nudged \
        fastapi "uvicorn[standard]" \
    && apt-get purge -y python3-pip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# rmf_visualization 런타임 의존성: rviz2, launch_xml, X11 디스플레이
ARG ROS_DISTRO=jazzy
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-rviz2 \
        ros-${ROS_DISTRO}-launch-xml \
        libx11-6 libxext6 libxrender1 libgl1 libglu1-mesa \
    && rm -rf /var/lib/apt/lists/*

# Source the workspace on entry
RUN sed -i '$isource "/rmf_ws/install/setup.bash"' /ros_entrypoint.sh

ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]
