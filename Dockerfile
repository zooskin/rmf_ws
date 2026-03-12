ARG ROS_DISTRO=jazzy

# ==============================================================================
# Stage 1: Build
# ==============================================================================
FROM ros:${ROS_DISTRO}-ros-base AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /rmf_ws

# Copy source packages
COPY src/rmf src/rmf
COPY src/thirdparty src/thirdparty

# Install dependencies via rosdep
ARG ROS_DISTRO=jazzy
RUN apt-get update \
    && rosdep update --rosdistro ${ROS_DISTRO} \
    && rosdep install --from-paths src --ignore-src --rosdistro ${ROS_DISTRO} -yr \
    && rm -rf /var/lib/apt/lists/*

# Build
RUN . /opt/ros/${ROS_DISTRO}/setup.sh \
    && colcon build \
        --cmake-args -DCMAKE_BUILD_TYPE=Release \
        --event-handlers console_direct+

# ==============================================================================
# Stage 2: Runtime
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
