#!/bin/bash
# ======================================================================
# Deney Seti D: Hold-and-Wait Doygunluk Deneyi (Saturation)
# Hakem: S2.3
# Amac: Waitpoint kapasitesinin asildiginda (|R| > |V_W|) sistemin
#        nasil davrandigini deneysel olarak gostermek. Secondary
#        congestion ve deadlock olusumunu olcmek.
# ======================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_BASE="$PROJECT_DIR/results/reviewer_experiments/D_saturation"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ── Varsayilan Parametreler ──────────────────────────────────
ROBOT_COUNTS=(4 8 12 16 20 24)
WAITPOINT_COUNT=8        # Kasitli olarak dusuk: doygunluk noktasini tetiklemek icin
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
    echo "  --quick          Hizli mod: N=4,12,24, 1 tekrar, 5dk"
    echo "  --robots LIST    Robot sayilari (virgul ile: 4,8,12)"
    echo "  --waitpoints W   Waitpoint sayisi (varsayilan: 8)"
    echo "  --repeats N      Tekrar sayisi"
    echo "  --duration N     Deney suresi (dakika)"
    echo "  --dry-run        Sadece plan goster"
    echo "  -h, --help       Bu mesaji goster"
    exit 0
}

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            ROBOT_COUNTS=(4 12 24)
            REPEATS=1
            DURATION_MIN=5
            WARMUP_MIN=2
            shift ;;
        --robots)     IFS=',' read -ra ROBOT_COUNTS <<< "$2"; shift 2 ;;
        --waitpoints) WAITPOINT_COUNT=$2; shift 2 ;;
        --repeats)    REPEATS=$2; shift 2 ;;
        --duration)   DURATION_MIN=$2; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        *)            echo "Bilinmeyen: $1"; usage ;;
    esac
done

TOTAL_EXPERIMENTS=$(( ${#ROBOT_COUNTS[@]} * REPEATS ))

# ── Renk ve Loglama ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +%H:%M:%S) $*"; }

echo "================================================================"
echo "  DENEY SETi D: HOLD-AND-WAIT DOYGUNLUK (Saturation)"
echo "================================================================"
echo ""
echo "  Robot sayilari   : ${ROBOT_COUNTS[*]}"
echo "  Waitpoint sayisi : $WAITPOINT_COUNT (sabit)"
echo "  Tekrar           : $REPEATS"
echo "  Sure             : ${DURATION_MIN}dk"
echo "  Toplam deney     : $TOTAL_EXPERIMENTS"
echo ""
echo "  Doygunluk noktasi: N > W = $WAITPOINT_COUNT robot"
echo "  Beklenti: N=$((WAITPOINT_COUNT+1))+ itibariyle secondary congestion"
echo ""

if $DRY_RUN; then
    echo "[DRY-RUN] Cikiliyor."
    exit 0
fi

# ── Sonuc Dizini ve CSV ─────────────────────────────────────
mkdir -p "$RESULTS_BASE/plots"

RESULTS_CSV="$RESULTS_BASE/results.csv"
if [ ! -f "$RESULTS_CSV" ]; then
    echo "experiment_id,set,robot_count,waitpoint_count,saturation_ratio,repeat,seed,duration_min,\
avg_cycle_ms,p95_cycle_ms,max_cycle_ms,\
throughput_per_min,task_completion_rate,\
total_conflicts,total_reroutes,total_deadlocks,\
cumulative_delay_s,\
waitpoint_saturation_avg,waitpoint_saturation_max,\
secondary_congestion_events,\
deadlock_duration_total_s,deadlock_count,\
avg_cpu_pct,peak_mem_mb" > "$RESULTS_CSV"
fi

cat > "$RESULTS_BASE/config.json" << EOFCFG
{
    "experiment_set": "D_saturation",
    "timestamp": "$TIMESTAMP",
    "robot_counts": [$(IFS=,; echo "${ROBOT_COUNTS[*]}")],
    "waitpoint_count": $WAITPOINT_COUNT,
    "repeats": $REPEATS,
    "duration_min": $DURATION_MIN,
    "total_experiments": $TOTAL_EXPERIMENTS,
    "hypothesis": "N > $WAITPOINT_COUNT itibariyle secondary congestion ve deadlock artisi beklenir"
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
    local robot_count=$3
    local repeat=$4
    local seed=$5
    local saturation_ratio
    saturation_ratio=$(echo "scale=2; $robot_count / $WAITPOINT_COUNT" | bc)

    local avg_cycle=0 p95_cycle=0 max_cycle=0
    local throughput=0 completion_rate=0
    local conflicts=0 reroutes=0 deadlocks=0
    local cum_delay=0
    local wp_sat_avg=0 wp_sat_max=0 sec_congestion=0
    local deadlock_dur=0 deadlock_count=0
    local avg_cpu=0 peak_mem=0
    local cycle_csv="$run_dir/cycle_times.csv"

    if [ -f "$cycle_csv" ] && [ "$(wc -l < "$cycle_csv")" -gt 1 ]; then
        local total_lines=$(( $(wc -l < "$cycle_csv") - 1 ))
        local skip_lines=$(( total_lines / 3 ))
        if [ $((total_lines - skip_lines)) -gt 0 ]; then
            avg_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                awk '{ sum+=$1;n++ } END { if(n>0) printf "%.2f",sum/n; else print 0 }')
            p95_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | awk -v p=0.95 '{a[NR]=$1} END{printf "%.2f", a[int(NR*p)]}')
            max_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | sort -n | tail -1)
            conflicts=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f5 | \
                awk '{ sum+=$1 } END { print sum+0 }')
        fi
    fi

    local stats_csv="$run_dir/system_stats.csv"
    if [ -f "$stats_csv" ] && [ "$(wc -l < "$stats_csv")" -gt 1 ]; then
        avg_cpu=$(tail -n +2 "$stats_csv" | cut -d',' -f2 | awk '{sum+=$1;n++} END{if(n>0) printf "%.2f",sum/n; else print 0}')
        peak_mem=$(tail -n +2 "$stats_csv" | cut -d',' -f3 | sort -n | tail -1)
    fi

    echo "$experiment_id,D_saturation,$robot_count,$WAITPOINT_COUNT,$saturation_ratio,$repeat,$seed,$DURATION_MIN,\
$avg_cycle,$p95_cycle,$max_cycle,\
$throughput,$completion_rate,\
$conflicts,$reroutes,$deadlocks,\
$cum_delay,\
$wp_sat_avg,$wp_sat_max,\
$sec_congestion,\
$deadlock_dur,$deadlock_count,\
$avg_cpu,$peak_mem" >> "$RESULTS_CSV"
}

# ── ANA DENEY DONGUSU ───────────────────────────────────────
EXPERIMENT_NUM=0
FAILED=0
START_TIME=$(date +%s)

for N in "${ROBOT_COUNTS[@]}"; do
    SAT_RATIO=$(echo "scale=2; $N / $WAITPOINT_COUNT" | bc)

    for R in $(seq 1 $REPEATS); do
        EXPERIMENT_NUM=$((EXPERIMENT_NUM + 1))
        SEED=$((N * 1000 + R))
        EXP_ID="D_N${N}_W${WAITPOINT_COUNT}_R${R}_${TIMESTAMP}"
        RUN_DIR="$RESULTS_BASE/run_${EXP_ID}"
        mkdir -p "$RUN_DIR"

        echo ""
        echo "================================================================"
        log_info "DENEY $EXPERIMENT_NUM / $TOTAL_EXPERIMENTS"
        log_info "Robot: $N | Waitpoints: $WAITPOINT_COUNT | Sat.Ratio: $SAT_RATIO | Tekrar: $R"
        [ "$(echo "$SAT_RATIO > 1" | bc)" -eq 1 ] && log_warn "DOYGUNLUK BOLGESI: N($N) > W($WAITPOINT_COUNT)"
        echo "================================================================"

        cleanup_environment

        cd "$PROJECT_DIR"
        docker compose build > "$RUN_DIR/build.log" 2>&1 || {
            log_error "Docker build basarisiz!"
            FAILED=$((FAILED + 1))
            continue
        }

        # Dar koridor haritasi ile olustur (doygunluk testine uygun)
        docker compose run --rm \
            -e ROBOT_COUNT=$N \
            -e WAITPOINT_COUNT=$WAITPOINT_COUNT \
            -e RANDOM_SEED=$SEED \
            -e MAP_TYPE="corridor" \
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

        log_info "Deney basliyor (N=$N, W=$WAITPOINT_COUNT, ${DURATION_MIN}dk)..."
        DURATION_SEC=$((DURATION_MIN * 60))

        timeout "${DURATION_SEC}s" docker compose run --rm \
            -e EXPERIMENT_ID="$EXP_ID" \
            -e ROBOT_COUNT=$N \
            -e WAITPOINT_COUNT=$WAITPOINT_COUNT \
            -e RANDOM_SEED=$SEED \
            scenario python3 -u fleet_management/FmInterface.py run "$SCENARIO" \
            > "$RUN_DIR/experiment.log" 2>&1
        EXIT_CODE=$?

        kill $STATS_PID 2>/dev/null || true
        wait $STATS_PID 2>/dev/null || true

        [ -f "$PROJECT_DIR/logs/cycle_times.csv" ] && cp "$PROJECT_DIR/logs/cycle_times.csv" "$RUN_DIR/"
        cp "$PROJECT_DIR/logs/FmLogHandler.log" "$RUN_DIR/" 2>/dev/null || true

        extract_metrics "$RUN_DIR" "$EXP_ID" "$N" "$R" "$SEED"

        [ $EXIT_CODE -eq 124 ] && log_ok "Tamamlandi (timeout)." || \
        [ $EXIT_CODE -eq 0 ] && log_ok "Tamamlandi." || \
        log_warn "Hata (exit=$EXIT_CODE)."

        cleanup_environment
    done
done

echo ""
echo "================================================================"
echo "  DENEY SETi D: DOYGUNLUK TESTi TAMAMLANDI"
echo "================================================================"
echo "  Toplam: $TOTAL_EXPERIMENTS | Basarili: $((TOTAL_EXPERIMENTS - FAILED)) | Basarisiz: $FAILED"
echo "  Sonuc: $RESULTS_CSV"
echo ""
echo "  Onemli: N > $WAITPOINT_COUNT durumlarinda secondary congestion"
echo "  artisi beklenmektedir. Sonuclari kontrol edin."
echo "================================================================"
