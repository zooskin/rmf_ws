#!/bin/bash
# =============================================================================
# RMF Web UI 로컬 빌드 스크립트
#
# 사용법:
#   ./scripts/build-web.sh              # Dashboard + API Server 모두 빌드
#   ./scripts/build-web.sh dashboard    # Dashboard만 빌드
#   ./scripts/build-web.sh api-server   # API Server만 빌드
#
# 빌드 결과물:
#   Dashboard: src/rmf_web_custom/packages/rmf-dashboard-framework/examples/demo/dist/
#   API Server: src/rmf_web_custom/packages/api-server/dist/api_server-*.whl
#
# 빌드 후 docker compose up -d 만 하면 됨 (이미지 리빌드 불필요)
# =============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEB_DIR="$SCRIPT_DIR/../src/rmf_web_custom"
TARGET="${1:-all}"

build_dashboard() {
    echo "=== Dashboard 빌드 시작 ==="
    cd "$WEB_DIR"

    # 의존성 설치 (node_modules 없을 때만)
    if [ ! -d "node_modules" ]; then
        echo "--- pnpm install (최초 1회) ---"
        pnpm install --filter rmf-dashboard-framework...
    fi

    echo "--- vite build ---"
    cd packages/rmf-dashboard-framework
    pnpm build:example examples/demo

    echo "=== Dashboard 빌드 완료 ==="
    echo "결과물: packages/rmf-dashboard-framework/examples/demo/dist/"
}

build_api_server() {
    echo "=== API Server 빌드 시작 ==="
    cd "$WEB_DIR"

    # 의존성 설치 (node_modules 없을 때만)
    if [ ! -d "node_modules" ]; then
        echo "--- pnpm install (최초 1회) ---"
        pnpm install --filter api-server...
    fi

    echo "--- prepack (wheel 빌드) ---"
    cd packages/api-server
    pnpm run prepack

    echo "=== API Server 빌드 완료 ==="
    echo "결과물: packages/api-server/dist/api_server-*.whl"
}

case "$TARGET" in
    dashboard)
        build_dashboard
        ;;
    api-server)
        build_api_server
        ;;
    all)
        build_dashboard
        build_api_server
        ;;
    *)
        echo "사용법: $0 [dashboard|api-server|all]"
        exit 1
        ;;
esac

echo ""
echo "docker compose up -d 로 반영하세요 (이미지 리빌드 불필요)"
