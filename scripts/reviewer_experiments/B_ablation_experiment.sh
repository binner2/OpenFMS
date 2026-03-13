#!/bin/bash
# ======================================================================
# Deney Seti B: Ablation Study
# Hakem: M1.2
# Amac: Her bilesenin (fuzzy, priority, reroute, waitpoints) bireysel
#        katkisini olcmek. Bileseni devre disi birakarak baseline ile
#        karsilastirma yapmak.
# ======================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_BASE="$PROJECT_DIR/results/reviewer_experiments/B_ablation"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ── Varsayilan Parametreler ──────────────────────────────────
ROBOT_COUNT=8            # Table I ile uyumlu
REPEATS=5
DURATION_MIN=15
WARMUP_MIN=5
SCENARIO="random"
STATS_INTERVAL=10

# Ablation konfigurasyonlari
declare -A ABLATION_CONFIGS
ABLATION_CONFIGS=(
    ["baseline"]=""
    ["no_fuzzy"]="disable_fuzzy=true"
    ["no_priority"]="disable_priority=true"
    ["no_reroute"]="disable_reroute=true"
    ["no_waitpoints"]="disable_waitpoints=true"
)
CONFIG_ORDER=("baseline" "no_fuzzy" "no_priority" "no_reroute" "no_waitpoints")

# ── Arguman Ayrıstirma ──────────────────────────────────────
usage() {
    echo "Kullanim: $0 [SECENEKLER]"
    echo ""
    echo "Secenekler:"
    echo "  --quick         Hizli mod: 2 tekrar, 5dk sure"
    echo "  --robots N      Robot sayisi (varsayilan: 8)"
    echo "  --repeats N     Tekrar sayisi"
    echo "  --duration N    Deney suresi (dakika)"
    echo "  --configs LIST  Ablation konfigurasyonlari (virgul ile)"
    echo "                  Secenekler: baseline,no_fuzzy,no_priority,no_reroute,no_waitpoints"
    echo "  --dry-run       Sadece plan goster"
    echo "  -h, --help      Bu mesaji goster"
    exit 0
}

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            REPEATS=2
            DURATION_MIN=5
            WARMUP_MIN=2
            shift ;;
        --robots)
            ROBOT_COUNT=$2
            shift 2 ;;
        --repeats)
            REPEATS=$2
            shift 2 ;;
        --duration)
            DURATION_MIN=$2
            shift 2 ;;
        --configs)
            IFS=',' read -ra CONFIG_ORDER <<< "$2"
            shift 2 ;;
        --dry-run)
            DRY_RUN=true
            shift ;;
        -h|--help)
            usage ;;
        *)
            echo "Bilinmeyen arguman: $1"; usage ;;
    esac
done

TOTAL_EXPERIMENTS=$(( ${#CONFIG_ORDER[@]} * REPEATS ))

# ── Renk ve Loglama ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +%H:%M:%S) $*"; }

# ── Deney Plani ──────────────────────────────────────────────
echo "================================================================"
echo "  DENEY SETi B: ABLATION STUDY"
echo "================================================================"
echo ""
echo "  Konfigurasyonlar:"
for cfg in "${CONFIG_ORDER[@]}"; do
    local_desc="${ABLATION_CONFIGS[$cfg]:-}"
    if [ -z "$local_desc" ]; then
        echo "    - $cfg (tum bilesenler aktif)"
    else
        echo "    - $cfg ($local_desc)"
    fi
done
echo ""
echo "  Robot sayisi   : $ROBOT_COUNT"
echo "  Tekrar         : $REPEATS"
echo "  Sure           : ${DURATION_MIN}dk"
echo "  Toplam deney   : $TOTAL_EXPERIMENTS"
echo "  Sonuc dizini   : $RESULTS_BASE"
echo ""

if $DRY_RUN; then
    echo "[DRY-RUN] Cikiliyor."
    exit 0
fi

# ── Sonuc Dizini ve CSV ─────────────────────────────────────
mkdir -p "$RESULTS_BASE/plots"

RESULTS_CSV="$RESULTS_BASE/results.csv"
if [ ! -f "$RESULTS_CSV" ]; then
    echo "experiment_id,set,robot_count,config_variant,repeat,seed,duration_min,\
avg_cycle_ms,p50_cycle_ms,p95_cycle_ms,p99_cycle_ms,max_cycle_ms,\
throughput_per_min,task_completion_rate,total_tasks_completed,total_tasks_failed,\
cumulative_delay_s,avg_task_completion_s,median_task_completion_s,\
total_conflicts,total_reroutes,total_deadlocks,\
avg_idle_time_s,fleet_utilization_pct,\
avg_info_age_s,max_info_age_s,\
waitpoint_saturation_avg,waitpoint_saturation_max,\
secondary_congestion_events,\
avg_cpu_pct,peak_mem_mb,\
avg_latency_ms,p95_latency_ms" > "$RESULTS_CSV"
fi

cat > "$RESULTS_BASE/config.json" << EOFCFG
{
    "experiment_set": "B_ablation",
    "timestamp": "$TIMESTAMP",
    "robot_count": $ROBOT_COUNT,
    "configurations": [$(printf '"%s",' "${CONFIG_ORDER[@]}" | sed 's/,$//')],
    "repeats": $REPEATS,
    "duration_min": $DURATION_MIN,
    "total_experiments": $TOTAL_EXPERIMENTS
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
    local config_variant=$3
    local repeat=$4
    local seed=$5
    local cycle_csv="$run_dir/cycle_times.csv"

    local avg_cycle=0 p50_cycle=0 p95_cycle=0 p99_cycle=0 max_cycle=0
    local throughput=0 completion_rate=0 tasks_done=0 tasks_failed=0
    local cum_delay=0 avg_task_time=0 med_task_time=0
    local conflicts=0 reroutes=0 deadlocks=0
    local avg_idle=0 utilization=0
    local avg_cpu=0 peak_mem=0

    if [ -f "$cycle_csv" ] && [ "$(wc -l < "$cycle_csv")" -gt 1 ]; then
        local total_lines=$(( $(wc -l < "$cycle_csv") - 1 ))
        local skip_lines=$(( total_lines / 3 ))
        if [ $((total_lines - skip_lines)) -gt 0 ]; then
            avg_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                awk '{ sum += $1; n++ } END { if(n>0) printf "%.2f", sum/n; else print 0 }')
            p50_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | awk -v p=0.50 '{a[NR]=$1} END{printf "%.2f", a[int(NR*p)]}')
            p95_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | awk -v p=0.95 '{a[NR]=$1} END{printf "%.2f", a[int(NR*p)]}')
            p99_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | awk -v p=0.99 '{a[NR]=$1} END{printf "%.2f", a[int(NR*p)]}')
            max_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | sort -n | tail -1)
            conflicts=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f5 | \
                awk '{ sum += $1 } END { print sum+0 }')
        fi
    fi

    local stats_csv="$run_dir/system_stats.csv"
    if [ -f "$stats_csv" ] && [ "$(wc -l < "$stats_csv")" -gt 1 ]; then
        avg_cpu=$(tail -n +2 "$stats_csv" | cut -d',' -f2 | awk '{ sum+=$1; n++ } END { if(n>0) printf "%.2f",sum/n; else print 0 }')
        peak_mem=$(tail -n +2 "$stats_csv" | cut -d',' -f3 | sort -n | tail -1)
    fi

    echo "$experiment_id,B_ablation,$ROBOT_COUNT,$config_variant,$repeat,$seed,$DURATION_MIN,\
$avg_cycle,$p50_cycle,$p95_cycle,$p99_cycle,$max_cycle,\
$throughput,$completion_rate,$tasks_done,$tasks_failed,\
$cum_delay,$avg_task_time,$med_task_time,\
$conflicts,$reroutes,$deadlocks,\
$avg_idle,$utilization,\
0,0,0,0,0,\
$avg_cpu,$peak_mem,\
0,0" >> "$RESULTS_CSV"
}

# ── ANA DENEY DONGUSU ───────────────────────────────────────
EXPERIMENT_NUM=0
FAILED=0
START_TIME=$(date +%s)

for CONFIG in "${CONFIG_ORDER[@]}"; do
    ABLATION_SETTING="${ABLATION_CONFIGS[$CONFIG]:-}"

    for R in $(seq 1 $REPEATS); do
        EXPERIMENT_NUM=$((EXPERIMENT_NUM + 1))
        SEED=$((ROBOT_COUNT * 1000 + R))
        EXP_ID="B_${CONFIG}_R${R}_${TIMESTAMP}"
        RUN_DIR="$RESULTS_BASE/run_${EXP_ID}"
        mkdir -p "$RUN_DIR"

        echo ""
        echo "================================================================"
        log_info "DENEY $EXPERIMENT_NUM / $TOTAL_EXPERIMENTS"
        log_info "Config: $CONFIG | Tekrar: $R/$REPEATS | Setting: ${ABLATION_SETTING:-tum aktif}"
        echo "================================================================"

        cleanup_environment

        cd "$PROJECT_DIR"
        docker compose build > "$RUN_DIR/build.log" 2>&1
        if [ $? -ne 0 ]; then
            log_error "Docker build basarisiz! Atlaniyor."
            FAILED=$((FAILED + 1))
            continue
        fi

        docker compose run --rm \
            -e ROBOT_COUNT=$ROBOT_COUNT \
            -e RANDOM_SEED=$SEED \
            scenario python3 fleet_management/FmInterface.py generate "$SCENARIO" \
            > "$RUN_DIR/map_gen.log" 2>&1 || true

        patch_config_for_docker

        docker compose up -d mqtt db simulator > /dev/null 2>&1
        if ! wait_for_postgres; then
            log_error "PostgreSQL hazir degil! Atlaniyor."
            cleanup_environment
            FAILED=$((FAILED + 1))
            continue
        fi
        log_ok "Altyapi hazir."

        collect_system_stats "$RUN_DIR/system_stats.csv" "$STATS_INTERVAL" &
        STATS_PID=$!

        # Ablation ayarlarini cevre degiskeni olarak gonder
        log_info "Deney basliyor (config=$CONFIG, ${DURATION_MIN}dk)..."
        DURATION_SEC=$((DURATION_MIN * 60))

        timeout "${DURATION_SEC}s" docker compose run --rm \
            -e EXPERIMENT_ID="$EXP_ID" \
            -e ROBOT_COUNT=$ROBOT_COUNT \
            -e RANDOM_SEED=$SEED \
            -e ABLATION_CONFIG="$ABLATION_SETTING" \
            scenario python3 -u fleet_management/FmInterface.py run "$SCENARIO" \
            > "$RUN_DIR/experiment.log" 2>&1
        EXIT_CODE=$?

        kill $STATS_PID 2>/dev/null || true
        wait $STATS_PID 2>/dev/null || true

        [ -f "$PROJECT_DIR/logs/cycle_times.csv" ] && cp "$PROJECT_DIR/logs/cycle_times.csv" "$RUN_DIR/"
        cp "$PROJECT_DIR/logs/FmLogHandler.log" "$RUN_DIR/" 2>/dev/null || true

        extract_metrics "$RUN_DIR" "$EXP_ID" "$CONFIG" "$R" "$SEED"

        [ $EXIT_CODE -eq 124 ] && log_ok "Deney zamana bagli tamamlandi." || \
        [ $EXIT_CODE -eq 0 ] && log_ok "Deney basariyla tamamlandi." || \
        log_warn "Deney hata ile sonuclandi (exit=$EXIT_CODE)."

        cleanup_environment

        ELAPSED=$(( $(date +%s) - START_TIME ))
        REMAINING=$(( (TOTAL_EXPERIMENTS - EXPERIMENT_NUM) * ELAPSED / EXPERIMENT_NUM / 60 ))
        log_info "Ilerleme: $EXPERIMENT_NUM/$TOTAL_EXPERIMENTS | Tahmini kalan: ${REMAINING}dk"
    done
done

# ── Ozet ────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  DENEY SETi B: ABLATION STUDY TAMAMLANDI"
echo "================================================================"
echo ""
echo "  Toplam deney : $TOTAL_EXPERIMENTS"
echo "  Basarili     : $((TOTAL_EXPERIMENTS - FAILED))"
echo "  Basarisiz    : $FAILED"
echo "  Sonuc CSV    : $RESULTS_CSV"
echo ""
echo "  Ablation karsilastirma grafigi icin:"
echo "    python3 scripts/reviewer_experiments/plot_results.py --set B"
echo "================================================================"
