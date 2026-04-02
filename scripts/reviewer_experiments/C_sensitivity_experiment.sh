#!/bin/bash
# ======================================================================
# Deney Seti C: Hassasiyet Analizi (Sensitivity Analysis)
# Hakem: M1.2 (ek)
# Amac: Fuzzy logic parametrelerinin (idle_time, battery, travel_time,
#        wait_time) esik degerlerinin sistem performansina etkisini
#        one-at-a-time (OAT) yontemiyle olcmek.
# ======================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_BASE="$PROJECT_DIR/results/reviewer_experiments/C_sensitivity"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ── Varsayilan Parametreler ──────────────────────────────────
ROBOT_COUNT=8
REPEATS=3
DURATION_MIN=15
WARMUP_MIN=5
SCENARIO="random"
STATS_INTERVAL=10

# Parametrik tarama degerleri (one-at-a-time)
IDLE_TIME_VALUES=(100 200 300 500)           # varsayilan: 300s
BATTERY_THRESHOLDS=(20 30 40 50)             # varsayilan: 40%
TRAVEL_TIME_BOUNDARIES=(100 200 300 400)     # varsayilan: 200s
WAIT_TIME_DEFAULTS=(5 10.5 20 30)            # varsayilan: 10.5s

# ── Arguman Ayrıstirma ──────────────────────────────────────
usage() {
    echo "Kullanim: $0 [SECENEKLER]"
    echo ""
    echo "Secenekler:"
    echo "  --quick         Hizli mod: 2 parametre deger, 1 tekrar"
    echo "  --repeats N     Tekrar sayisi"
    echo "  --duration N    Deney suresi (dakika)"
    echo "  --param NAME    Sadece belirli parametreyi test et"
    echo "                  (idle_time|battery|travel_time|wait_time)"
    echo "  --dry-run       Sadece plan goster"
    echo "  -h, --help      Bu mesaji goster"
    exit 0
}

DRY_RUN=false
SINGLE_PARAM=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            REPEATS=1
            IDLE_TIME_VALUES=(100 300)
            BATTERY_THRESHOLDS=(20 40)
            TRAVEL_TIME_BOUNDARIES=(100 300)
            WAIT_TIME_DEFAULTS=(5 20)
            DURATION_MIN=5
            WARMUP_MIN=2
            shift ;;
        --repeats)    REPEATS=$2; shift 2 ;;
        --duration)   DURATION_MIN=$2; shift 2 ;;
        --param)      SINGLE_PARAM=$2; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        *)            echo "Bilinmeyen arguman: $1"; usage ;;
    esac
done

# Deney matrisi hesapla
PARAMS_TO_TEST=()
declare -A PARAM_VALUES
declare -A PARAM_DEFAULTS

if [ -z "$SINGLE_PARAM" ] || [ "$SINGLE_PARAM" = "idle_time" ]; then
    PARAMS_TO_TEST+=("idle_time")
    PARAM_VALUES[idle_time]="${IDLE_TIME_VALUES[*]}"
    PARAM_DEFAULTS[idle_time]="300"
fi
if [ -z "$SINGLE_PARAM" ] || [ "$SINGLE_PARAM" = "battery" ]; then
    PARAMS_TO_TEST+=("battery")
    PARAM_VALUES[battery]="${BATTERY_THRESHOLDS[*]}"
    PARAM_DEFAULTS[battery]="40"
fi
if [ -z "$SINGLE_PARAM" ] || [ "$SINGLE_PARAM" = "travel_time" ]; then
    PARAMS_TO_TEST+=("travel_time")
    PARAM_VALUES[travel_time]="${TRAVEL_TIME_BOUNDARIES[*]}"
    PARAM_DEFAULTS[travel_time]="200"
fi
if [ -z "$SINGLE_PARAM" ] || [ "$SINGLE_PARAM" = "wait_time" ]; then
    PARAMS_TO_TEST+=("wait_time")
    PARAM_VALUES[wait_time]="${WAIT_TIME_DEFAULTS[*]}"
    PARAM_DEFAULTS[wait_time]="10.5"
fi

TOTAL_COMBOS=0
for param in "${PARAMS_TO_TEST[@]}"; do
    local_vals=(${PARAM_VALUES[$param]})
    TOTAL_COMBOS=$(( TOTAL_COMBOS + ${#local_vals[@]} ))
done
TOTAL_EXPERIMENTS=$(( TOTAL_COMBOS * REPEATS ))

# ── Renk ve Loglama ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +%H:%M:%S) $*"; }

echo "================================================================"
echo "  DENEY SETi C: HASSASIYET ANALIZI (Sensitivity)"
echo "================================================================"
echo ""
echo "  Parametreler:"
for param in "${PARAMS_TO_TEST[@]}"; do
    echo "    $param: ${PARAM_VALUES[$param]} (varsayilan: ${PARAM_DEFAULTS[$param]})"
done
echo ""
echo "  Robot sayisi  : $ROBOT_COUNT"
echo "  Tekrar        : $REPEATS"
echo "  Sure          : ${DURATION_MIN}dk"
echo "  Toplam kombo  : $TOTAL_COMBOS"
echo "  Toplam deney  : $TOTAL_EXPERIMENTS"
echo ""

if $DRY_RUN; then
    echo "[DRY-RUN] Cikiliyor."
    exit 0
fi

# ── Sonuc Dizini ve CSV ─────────────────────────────────────
mkdir -p "$RESULTS_BASE/plots"

RESULTS_CSV="$RESULTS_BASE/results.csv"
if [ ! -f "$RESULTS_CSV" ]; then
    echo "experiment_id,set,robot_count,parameter_name,parameter_value,repeat,seed,duration_min,\
avg_cycle_ms,p50_cycle_ms,p95_cycle_ms,p99_cycle_ms,max_cycle_ms,\
throughput_per_min,task_completion_rate,total_tasks_completed,\
total_conflicts,total_reroutes,\
avg_idle_time_s,fleet_utilization_pct,\
avg_cpu_pct,peak_mem_mb" > "$RESULTS_CSV"
fi

cat > "$RESULTS_BASE/config.json" << EOFCFG
{
    "experiment_set": "C_sensitivity",
    "timestamp": "$TIMESTAMP",
    "robot_count": $ROBOT_COUNT,
    "parameters": {
        $(for param in "${PARAMS_TO_TEST[@]}"; do
            echo "\"$param\": {\"values\": [${PARAM_VALUES[$param]// /, }], \"default\": ${PARAM_DEFAULTS[$param]}},"
        done | sed '$ s/,$//')
    },
    "repeats": $REPEATS,
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
    local param_name=$3
    local param_value=$4
    local repeat=$5
    local seed=$6
    local cycle_csv="$run_dir/cycle_times.csv"

    local avg_cycle=0 p50_cycle=0 p95_cycle=0 p99_cycle=0 max_cycle=0
    local throughput=0 completion_rate=0 tasks_done=0
    local conflicts=0 reroutes=0
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
        avg_cpu=$(tail -n +2 "$stats_csv" | cut -d',' -f2 | awk '{ sum+=$1;n++ } END { if(n>0) printf "%.2f",sum/n; else print 0 }')
        peak_mem=$(tail -n +2 "$stats_csv" | cut -d',' -f3 | sort -n | tail -1)
    fi

    echo "$experiment_id,C_sensitivity,$ROBOT_COUNT,$param_name,$param_value,$repeat,$seed,$DURATION_MIN,\
$avg_cycle,$p50_cycle,$p95_cycle,$p99_cycle,$max_cycle,\
$throughput,$completion_rate,$tasks_done,\
$conflicts,$reroutes,\
$avg_idle,$utilization,\
$avg_cpu,$peak_mem" >> "$RESULTS_CSV"
}

# ── ANA DENEY DONGUSU ───────────────────────────────────────
EXPERIMENT_NUM=0
FAILED=0
START_TIME=$(date +%s)

for PARAM_NAME in "${PARAMS_TO_TEST[@]}"; do
    VALUES=(${PARAM_VALUES[$PARAM_NAME]})

    for PARAM_VAL in "${VALUES[@]}"; do
        for R in $(seq 1 $REPEATS); do
            EXPERIMENT_NUM=$((EXPERIMENT_NUM + 1))
            SEED=$((ROBOT_COUNT * 1000 + R))
            EXP_ID="C_${PARAM_NAME}_${PARAM_VAL}_R${R}_${TIMESTAMP}"
            RUN_DIR="$RESULTS_BASE/run_${EXP_ID}"
            mkdir -p "$RUN_DIR"

            echo ""
            echo "================================================================"
            log_info "DENEY $EXPERIMENT_NUM / $TOTAL_EXPERIMENTS"
            log_info "Param: $PARAM_NAME=$PARAM_VAL | Tekrar: $R/$REPEATS"
            echo "================================================================"

            cleanup_environment

            cd "$PROJECT_DIR"
            docker compose build > "$RUN_DIR/build.log" 2>&1 || {
                log_error "Docker build basarisiz! Atlaniyor."
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

            log_info "Deney basliyor ($PARAM_NAME=$PARAM_VAL, ${DURATION_MIN}dk)..."
            DURATION_SEC=$((DURATION_MIN * 60))

            timeout "${DURATION_SEC}s" docker compose run --rm \
                -e EXPERIMENT_ID="$EXP_ID" \
                -e ROBOT_COUNT=$ROBOT_COUNT \
                -e RANDOM_SEED=$SEED \
                -e "FUZZY_${PARAM_NAME^^}=$PARAM_VAL" \
                scenario python3 -u fleet_management/FmInterface.py run "$SCENARIO" \
                > "$RUN_DIR/experiment.log" 2>&1
            EXIT_CODE=$?

            kill $STATS_PID 2>/dev/null || true
            wait $STATS_PID 2>/dev/null || true

            [ -f "$PROJECT_DIR/logs/cycle_times.csv" ] && cp "$PROJECT_DIR/logs/cycle_times.csv" "$RUN_DIR/"
            cp "$PROJECT_DIR/logs/FmLogHandler.log" "$RUN_DIR/" 2>/dev/null || true

            extract_metrics "$RUN_DIR" "$EXP_ID" "$PARAM_NAME" "$PARAM_VAL" "$R" "$SEED"

            [ $EXIT_CODE -eq 124 ] && log_ok "Tamamlandi (timeout)." || \
            [ $EXIT_CODE -eq 0 ] && log_ok "Tamamlandi." || \
            log_warn "Hata (exit=$EXIT_CODE)."

            cleanup_environment
        done
    done
done

echo ""
echo "================================================================"
echo "  DENEY SETi C: HASSASIYET ANALIZI TAMAMLANDI"
echo "================================================================"
echo "  Toplam: $TOTAL_EXPERIMENTS | Basarili: $((TOTAL_EXPERIMENTS - FAILED)) | Basarisiz: $FAILED"
echo "  Sonuc: $RESULTS_CSV"
echo "================================================================"
