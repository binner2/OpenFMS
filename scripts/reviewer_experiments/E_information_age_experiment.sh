#!/bin/bash
# ======================================================================
# Deney Seti E: Information Age Deneyi
# Hakem: S2.4
# Amac: Network latency ile information age arasindaki farki deneysel
#        olarak gostermek. State publish interval degistirilerek
#        bilgi bayatliginin (staleness) sistem performansina etkisini
#        olcmek.
# ======================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_BASE="$PROJECT_DIR/results/reviewer_experiments/E_information_age"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ── Varsayilan Parametreler ──────────────────────────────────
ROBOT_COUNT=8
PUBLISH_INTERVALS=(0.1 0.5 1.0 2.0 5.0)    # State publish interval (saniye)
REPEATS=3
DURATION_MIN=15
WARMUP_MIN=5
SCENARIO="random"
STATS_INTERVAL=10

# ── Arguman Ayrıstirma ──────────────────────────────────────
usage() {
    echo "Kullanim: $0 [SECENEKLER]"
    echo ""
    echo "Secenekler:"
    echo "  --quick           Hizli mod: 3 interval, 1 tekrar, 5dk"
    echo "  --intervals LIST  Publish intervalleri (virgul ile: 0.1,1.0,5.0)"
    echo "  --robots N        Robot sayisi"
    echo "  --repeats N       Tekrar sayisi"
    echo "  --duration N      Deney suresi (dakika)"
    echo "  --dry-run         Sadece plan goster"
    echo "  -h, --help        Bu mesaji goster"
    exit 0
}

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            PUBLISH_INTERVALS=(0.1 1.0 5.0)
            REPEATS=1
            DURATION_MIN=5
            WARMUP_MIN=2
            shift ;;
        --intervals)  IFS=',' read -ra PUBLISH_INTERVALS <<< "$2"; shift 2 ;;
        --robots)     ROBOT_COUNT=$2; shift 2 ;;
        --repeats)    REPEATS=$2; shift 2 ;;
        --duration)   DURATION_MIN=$2; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        *)            echo "Bilinmeyen: $1"; usage ;;
    esac
done

TOTAL_EXPERIMENTS=$(( ${#PUBLISH_INTERVALS[@]} * REPEATS ))

# ── Renk ve Loglama ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +%H:%M:%S) $*"; }

echo "================================================================"
echo "  DENEY SETi E: INFORMATION AGE"
echo "================================================================"
echo ""
echo "  State publish intervalleri: ${PUBLISH_INTERVALS[*]} (saniye)"
echo "  Robot sayisi              : $ROBOT_COUNT"
echo "  Tekrar                    : $REPEATS"
echo "  Sure                      : ${DURATION_MIN}dk"
echo "  Toplam deney              : $TOTAL_EXPERIMENTS"
echo ""
echo "  Olculecek metrikler:"
echo "    - Network Latency   = t_received - t_state_generated"
echo "    - Information Age   = t_decision - t_state_generated"
echo "    - Staleness         = t_decision - t_received (cache bekleme)"
echo ""

if $DRY_RUN; then
    echo "[DRY-RUN] Cikiliyor."
    exit 0
fi

# ── Sonuc Dizini ve CSV ─────────────────────────────────────
mkdir -p "$RESULTS_BASE/plots"

RESULTS_CSV="$RESULTS_BASE/results.csv"
if [ ! -f "$RESULTS_CSV" ]; then
    echo "experiment_id,set,robot_count,publish_interval_s,repeat,seed,duration_min,\
avg_cycle_ms,p95_cycle_ms,\
throughput_per_min,task_completion_rate,\
total_conflicts,\
avg_network_latency_ms,p95_network_latency_ms,\
avg_info_age_ms,p95_info_age_ms,max_info_age_ms,\
avg_staleness_ms,p95_staleness_ms,\
stale_decision_count,stale_decision_pct,\
task_quality_score,\
avg_cpu_pct,peak_mem_mb" > "$RESULTS_CSV"
fi

cat > "$RESULTS_BASE/config.json" << EOFCFG
{
    "experiment_set": "E_information_age",
    "timestamp": "$TIMESTAMP",
    "robot_count": $ROBOT_COUNT,
    "publish_intervals_s": [$(IFS=,; echo "${PUBLISH_INTERVALS[*]}")],
    "repeats": $REPEATS,
    "duration_min": $DURATION_MIN,
    "total_experiments": $TOTAL_EXPERIMENTS,
    "metrics": {
        "network_latency": "t_received - t_state_generated",
        "information_age": "t_decision - t_state_generated",
        "staleness": "t_decision - t_received"
    }
}
EOFCFG

# ── Altyapi Fonksiyonlari ───────────────────────────────────
cleanup_environment() {
    cd "$PROJECT_DIR"
    docker compose down --remove-orphans > /dev/null 2>&1 || true
    STALE=$(docker ps -aq --filter "name=openfms" 2>/dev/null)
    [ -n "$STALE" ] && docker rm -f $STALE > /dev/null 2>&1
    rm -f logs/result_snapshot_*.txt logs/live_dashboard.txt logs/cycle_times.csv 2>/dev/null
}

wait_for_postgres() {
    for i in {1..30}; do
        docker compose exec db pg_isready -U postgres > /dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

patch_config_for_docker() {
    cd "$PROJECT_DIR"
    sed -i 's|broker_address: "localhost"|broker_address: "mqtt"|g' config/config.yaml
    sed -i 's|broker_address: localhost|broker_address: mqtt|g' config/config.yaml
    sed -i 's|host: "localhost"|host: "db"|g' config/config.yaml
    sed -i 's|host: localhost|host: db|g' config/config.yaml
}

collect_system_stats() {
    local output_file=$1
    echo "timestamp,cpu_pct,mem_usage_mb" > "$output_file"
    while true; do
        local stats
        stats=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" openfms-manager-1 2>/dev/null || echo "0%,0MiB / 0MiB")
        local cpu=$(echo "$stats" | sed 's/%//g' | cut -d',' -f1)
        local mem_used=$(echo "$stats" | cut -d',' -f2 | cut -d'/' -f1 | tr -d ' ' | sed 's/MiB//;s/GiB/*1024/' | bc -l 2>/dev/null || echo "0")
        echo "$(date +%s),$cpu,$mem_used" >> "$output_file"
        sleep "$STATS_INTERVAL"
    done
}

extract_metrics() {
    local run_dir=$1
    local experiment_id=$2
    local interval=$3
    local repeat=$4
    local seed=$5
    local cycle_csv="$run_dir/cycle_times.csv"

    local avg_cycle=0 p95_cycle=0
    local throughput=0 completion_rate=0 conflicts=0
    local avg_net_lat=0 p95_net_lat=0
    local avg_info_age=0 p95_info_age=0 max_info_age=0
    local avg_staleness=0 p95_staleness=0
    local stale_count=0 stale_pct=0
    local task_quality=0
    local avg_cpu=0 peak_mem=0

    if [ -f "$cycle_csv" ] && [ "$(wc -l < "$cycle_csv")" -gt 1 ]; then
        local total_lines=$(( $(wc -l < "$cycle_csv") - 1 ))
        local skip_lines=$(( total_lines / 3 ))
        if [ $((total_lines - skip_lines)) -gt 0 ]; then
            avg_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                awk '{sum+=$1;n++} END{if(n>0) printf "%.2f",sum/n; else print 0}')
            p95_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | awk -v p=0.95 '{a[NR]=$1} END{printf "%.2f", a[int(NR*p)]}')
            conflicts=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f5 | \
                awk '{sum+=$1} END{print sum+0}')
        fi
    fi

    local stats_csv="$run_dir/system_stats.csv"
    if [ -f "$stats_csv" ] && [ "$(wc -l < "$stats_csv")" -gt 1 ]; then
        avg_cpu=$(tail -n +2 "$stats_csv" | cut -d',' -f2 | awk '{sum+=$1;n++} END{if(n>0) printf "%.2f",sum/n; else print 0}')
        peak_mem=$(tail -n +2 "$stats_csv" | cut -d',' -f3 | sort -n | tail -1)
    fi

    echo "$experiment_id,E_information_age,$ROBOT_COUNT,$interval,$repeat,$seed,$DURATION_MIN,\
$avg_cycle,$p95_cycle,\
$throughput,$completion_rate,\
$conflicts,\
$avg_net_lat,$p95_net_lat,\
$avg_info_age,$p95_info_age,$max_info_age,\
$avg_staleness,$p95_staleness,\
$stale_count,$stale_pct,\
$task_quality,\
$avg_cpu,$peak_mem" >> "$RESULTS_CSV"
}

# ── ANA DENEY DONGUSU ───────────────────────────────────────
EXPERIMENT_NUM=0
FAILED=0
START_TIME=$(date +%s)

for INTERVAL in "${PUBLISH_INTERVALS[@]}"; do
    for R in $(seq 1 $REPEATS); do
        EXPERIMENT_NUM=$((EXPERIMENT_NUM + 1))
        SEED=$((ROBOT_COUNT * 1000 + R))
        EXP_ID="E_I${INTERVAL}_R${R}_${TIMESTAMP}"
        RUN_DIR="$RESULTS_BASE/run_${EXP_ID}"
        mkdir -p "$RUN_DIR"

        echo ""
        echo "================================================================"
        log_info "DENEY $EXPERIMENT_NUM / $TOTAL_EXPERIMENTS"
        log_info "Publish Interval: ${INTERVAL}s | Tekrar: $R/$REPEATS"
        echo "================================================================"

        cleanup_environment

        cd "$PROJECT_DIR"
        docker compose build > "$RUN_DIR/build.log" 2>&1 || {
            log_error "Docker build basarisiz!"
            FAILED=$((FAILED + 1))
            continue
        }

        docker compose run --rm \
            -e ROBOT_COUNT=$ROBOT_COUNT \
            -e RANDOM_SEED=$SEED \
            scenario python3 fleet_management/FmInterface.py generate "$SCENARIO" \
            > "$RUN_DIR/map_gen.log" 2>&1 || true

        patch_config_for_docker

        docker compose up -d mqtt db simulator > /dev/null 2>&1
        if ! wait_for_postgres; then
            log_error "PostgreSQL hazir degil!"
            cleanup_environment
            FAILED=$((FAILED + 1))
            continue
        fi

        collect_system_stats "$RUN_DIR/system_stats.csv" "$STATS_INTERVAL" &
        STATS_PID=$!

        log_info "Deney basliyor (interval=${INTERVAL}s, ${DURATION_MIN}dk)..."
        DURATION_SEC=$((DURATION_MIN * 60))

        timeout "${DURATION_SEC}s" docker compose run --rm \
            -e EXPERIMENT_ID="$EXP_ID" \
            -e ROBOT_COUNT=$ROBOT_COUNT \
            -e RANDOM_SEED=$SEED \
            -e STATE_PUBLISH_INTERVAL="$INTERVAL" \
            scenario python3 -u fleet_management/FmInterface.py run "$SCENARIO" \
            > "$RUN_DIR/experiment.log" 2>&1
        EXIT_CODE=$?

        kill $STATS_PID 2>/dev/null || true
        wait $STATS_PID 2>/dev/null || true

        [ -f "$PROJECT_DIR/logs/cycle_times.csv" ] && cp "$PROJECT_DIR/logs/cycle_times.csv" "$RUN_DIR/"
        cp "$PROJECT_DIR/logs/FmLogHandler.log" "$RUN_DIR/" 2>/dev/null || true

        extract_metrics "$RUN_DIR" "$EXP_ID" "$INTERVAL" "$R" "$SEED"

        [ $EXIT_CODE -eq 124 ] && log_ok "Tamamlandi (timeout)." || \
        [ $EXIT_CODE -eq 0 ] && log_ok "Tamamlandi." || \
        log_warn "Hata (exit=$EXIT_CODE)."

        cleanup_environment
    done
done

echo ""
echo "================================================================"
echo "  DENEY SETi E: INFORMATION AGE TAMAMLANDI"
echo "================================================================"
echo "  Toplam: $TOTAL_EXPERIMENTS | Basarili: $((TOTAL_EXPERIMENTS - FAILED)) | Basarisiz: $FAILED"
echo "  Sonuc: $RESULTS_CSV"
echo ""
echo "  Beklenen bulgular:"
echo "    - Dusuk interval (0.1s): Dusuk info age, yuksek ag yuku"
echo "    - Yuksek interval (5.0s): Yuksek info age, bayat kararlar"
echo "    - Optimum nokta: ~0.5-1.0s arasi"
echo "================================================================"
