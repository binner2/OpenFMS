#!/bin/bash
# ============================================================
# OpenFMS Scripts — Ortak Yardımcı Fonksiyonlar
# ============================================================
# Bu dosya diğer script'ler tarafından source edilir.
# Tek başına çalıştırılmaz.
# ============================================================

set -euo pipefail

# ── Renkler ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ── Proje kök dizini ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS_DIR="$PROJECT_ROOT/logs"
RESULTS_DIR="$PROJECT_ROOT/results"

# ── Loglama ─────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_header()  { echo -e "\n${BOLD}${PURPLE}════════════════════════════════════════${NC}"; echo -e "${BOLD}${PURPLE}  $*${NC}"; echo -e "${BOLD}${PURPLE}════════════════════════════════════════${NC}\n"; }
log_step()    { echo -e "${CYAN}[$1]${NC} $2"; }

# ── Zaman damgası ───────────────────────────────────────────
timestamp() { date '+%Y-%m-%d_%H-%M-%S'; }
timestamp_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

# ── Dizin hazırlama ─────────────────────────────────────────
ensure_dirs() {
    mkdir -p "$LOGS_DIR" "$RESULTS_DIR"
}

# ── Docker yardımcıları ────────────────────────────────────
docker_is_running() {
    docker info > /dev/null 2>&1
}

compose_is_up() {
    local service="$1"
    docker compose ps --status running "$service" 2>/dev/null | grep -q "$service"
}

wait_for_postgres() {
    local max_wait=${1:-60}
    local elapsed=0
    log_info "PostgreSQL hazır olana kadar bekleniyor (max ${max_wait}s)..."
    while [ $elapsed -lt $max_wait ]; do
        if docker compose exec -T db pg_isready -U postgres > /dev/null 2>&1; then
            log_success "PostgreSQL hazir!"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo ""
    log_error "PostgreSQL ${max_wait} saniye icinde baslatılamadı."
    return 1
}

wait_for_mqtt() {
    local max_wait=${1:-30}
    local elapsed=0
    log_info "MQTT broker hazır olana kadar bekleniyor (max ${max_wait}s)..."
    while [ $elapsed -lt $max_wait ]; do
        if docker compose exec -T mqtt mosquitto_pub -t "test/ping" -m "ping" -q 0 > /dev/null 2>&1; then
            log_success "MQTT broker hazir!"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo ""
    log_error "MQTT broker ${max_wait} saniye icinde baslatılamadı."
    return 1
}

# ── Temizlik ────────────────────────────────────────────────
clean_environment() {
    log_info "Eski container'lar ve loglar temizleniyor..."
    cd "$PROJECT_ROOT"
    docker compose down --remove-orphans > /dev/null 2>&1 || true
    local stale=$(docker ps -aq --filter "name=openfms" 2>/dev/null)
    if [ -n "$stale" ]; then
        docker rm -f $stale > /dev/null 2>&1 || true
    fi
    rm -f logs/result_snapshot_*.txt logs/live_dashboard.txt 2>/dev/null || true
    log_success "Ortam temizlendi."
}

# ── Altyapı başlatma ───────────────────────────────────────
start_infrastructure() {
    cd "$PROJECT_ROOT"
    log_info "Docker imajları build ediliyor..."
    docker compose build --quiet

    # config.yaml Docker networking patch
    sed -i 's|broker_address: "localhost"|broker_address: "mqtt"|g' config/config.yaml 2>/dev/null || true
    sed -i 's|broker_address: localhost|broker_address: mqtt|g' config/config.yaml 2>/dev/null || true
    sed -i 's|host: "localhost"|host: "db"|g' config/config.yaml 2>/dev/null || true
    sed -i 's|host: localhost|host: db|g' config/config.yaml 2>/dev/null || true

    log_info "MQTT + PostgreSQL baslatılıyor..."
    docker compose up -d mqtt db
    wait_for_postgres 60
    wait_for_mqtt 30
}

# ── Altyapı + simülatör + manager ──────────────────────────
start_full_stack() {
    start_infrastructure
    log_info "Simulator + Manager baslatılıyor..."
    docker compose up -d simulator manager
    log_info "Servislerin ayaga kalkması icin 10 saniye bekleniyor..."
    sleep 10
}

# ── Tam durdurma ────────────────────────────────────────────
stop_all() {
    cd "$PROJECT_ROOT"
    log_info "Tüm servisler durduruluyor..."
    docker compose down --remove-orphans --volumes > /dev/null 2>&1 || true
    log_success "Tüm servisler durduruldu."
}

# ── Sonuç kaydetme (JSON) ──────────────────────────────────
save_result_json() {
    local filename="$1"
    local content="$2"
    local filepath="$RESULTS_DIR/$filename"
    echo "$content" > "$filepath"
    log_success "Sonuç kaydedildi: $filepath"
}

# ── Süre ölçme ──────────────────────────────────────────────
timer_start() {
    TIMER_START=$(date +%s%N)
}

timer_elapsed_ms() {
    local now=$(date +%s%N)
    echo $(( (now - TIMER_START) / 1000000 ))
}

# ── Python komutu çalıştırma (container içinde) ────────────
run_python_in_container() {
    local python_code="$1"
    docker compose run --rm -T scenario python3 -c "$python_code"
}
