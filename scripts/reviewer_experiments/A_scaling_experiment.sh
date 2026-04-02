#!/bin/bash
# ======================================================================
# Deney Seti A: Olceklendirme Deneyi (Scaling Experiment)
# Hakem: M1.1 + S2.1
# Amac: Robot sayisi arttirildiginda sistem performansinin nasil
#        degistigini olcmek. O(N^2) fetch_mex_data darbogazini kanitlamak.
# ======================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_BASE="$PROJECT_DIR/results/reviewer_experiments/A_scaling"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ── Varsayilan Parametreler ──────────────────────────────────
ROBOT_COUNTS=(2 4 8 16 24 32 48)
REPEATS=5
DURATION_MIN=15          # 5dk warmup + 10dk olcum
WARMUP_MIN=5
SCENARIO="random"
STATS_INTERVAL=10        # sistem istatistikleri kayit araligi (sn)

# ── Arguman Ayrıstirma ──────────────────────────────────────
usage() {
    echo "Kullanim: $0 [SECENEKLER]"
    echo ""
    echo "Secenekler:"
    echo "  --quick         Hizli mod: N=2,8,16, 2 tekrar, 5dk sure"
    echo "  --standard      Standart mod: N=2,4,8,16,24,32, 3 tekrar"
    echo "  --full          Tam mod: N=2,4,8,16,24,32,48, 5 tekrar (varsayilan)"
    echo "  --robots LIST   Ozel robot sayilari (virgul ile: 2,8,16)"
    echo "  --repeats N     Tekrar sayisi"
    echo "  --duration N    Deney suresi (dakika)"
    echo "  --scenario S    Senaryo adi (varsayilan: random)"
    echo "  --dry-run       Sadece plan goster, calistirma"
    echo "  -h, --help      Bu mesaji goster"
    exit 0
}

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            ROBOT_COUNTS=(2 8 16)
            REPEATS=2
            DURATION_MIN=5
            WARMUP_MIN=2
            shift ;;
        --standard)
            ROBOT_COUNTS=(2 4 8 16 24 32)
            REPEATS=3
            shift ;;
        --full)
            shift ;;
        --robots)
            IFS=',' read -ra ROBOT_COUNTS <<< "$2"
            shift 2 ;;
        --repeats)
            REPEATS=$2
            shift 2 ;;
        --duration)
            DURATION_MIN=$2
            shift 2 ;;
        --scenario)
            SCENARIO=$2
            shift 2 ;;
        --dry-run)
            DRY_RUN=true
            shift ;;
        -h|--help)
            usage ;;
        *)
            echo "Bilinmeyen arguman: $1"
            usage ;;
    esac
done

MEASUREMENT_MIN=$((DURATION_MIN - WARMUP_MIN))
TOTAL_EXPERIMENTS=$(( ${#ROBOT_COUNTS[@]} * REPEATS ))

# ── Renk ve Loglama ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +%H:%M:%S) $*"; }

# ── Deney Plani ──────────────────────────────────────────────
echo "================================================================"
echo "  DENEY SETi A: OLCEKLENDIRME (Scaling Experiment)"
echo "================================================================"
echo ""
echo "  Robot sayilari : ${ROBOT_COUNTS[*]}"
echo "  Tekrar         : $REPEATS"
echo "  Sure           : ${DURATION_MIN}dk (${WARMUP_MIN}dk warmup + ${MEASUREMENT_MIN}dk olcum)"
echo "  Senaryo        : $SCENARIO"
echo "  Toplam deney   : $TOTAL_EXPERIMENTS"
echo "  Sonuc dizini   : $RESULTS_BASE"
echo ""

if $DRY_RUN; then
    echo "[DRY-RUN] Sadece plan gosterildi. Cikiliyor."
    exit 0
fi

# ── Sonuc Dizini Olustur ────────────────────────────────────
mkdir -p "$RESULTS_BASE/plots"

# Ana CSV baslik satiri
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

# Deney konfigurasyonu kaydet
cat > "$RESULTS_BASE/config.json" << EOFCFG
{
    "experiment_set": "A_scaling",
    "timestamp": "$TIMESTAMP",
    "robot_counts": [$(IFS=,; echo "${ROBOT_COUNTS[*]}")],
    "repeats": $REPEATS,
    "duration_min": $DURATION_MIN,
    "warmup_min": $WARMUP_MIN,
    "scenario": "$SCENARIO",
    "stats_interval_s": $STATS_INTERVAL,
    "total_experiments": $TOTAL_EXPERIMENTS
}
EOFCFG

# ── Altyapi Yonetimi ────────────────────────────────────────
cleanup_environment() {
    log_info "Ortam temizleniyor..."
    cd "$PROJECT_DIR"
    docker compose down --remove-orphans > /dev/null 2>&1 || true
    STALE=$(docker ps -aq --filter "name=openfms" 2>/dev/null)
    if [ -n "$STALE" ]; then
        docker rm -f $STALE > /dev/null 2>&1
    fi
    rm -f logs/result_snapshot_*.txt logs/live_dashboard.txt 2>/dev/null
    rm -f logs/cycle_times.csv 2>/dev/null
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

# ── Sistem Istatistikleri Toplayici ─────────────────────────
collect_system_stats() {
    local output_file=$1
    local interval=$2
    echo "timestamp,cpu_pct,mem_usage_mb,mem_limit_mb,net_rx_bytes,net_tx_bytes" > "$output_file"
    while true; do
        local stats
        stats=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" openfms-manager-1 2>/dev/null || echo "0%,0MiB / 0MiB")
        local cpu=$(echo "$stats" | sed 's/%//g' | cut -d',' -f1)
        local mem_raw=$(echo "$stats" | cut -d',' -f2)
        local mem_used=$(echo "$mem_raw" | cut -d'/' -f1 | tr -d ' ' | sed 's/MiB//;s/GiB/*1024/' | bc -l 2>/dev/null || echo "0")
        echo "$(date +%s),$cpu,$mem_used,0,0,0" >> "$output_file"
        sleep "$interval"
    done
}

# ── Sonuc Cikarma (Post-processing) ────────────────────────
extract_metrics() {
    local run_dir=$1
    local experiment_id=$2
    local robot_count=$3
    local repeat=$4
    local seed=$5
    local cycle_csv="$run_dir/cycle_times.csv"

    # Varsayilan degerler
    local avg_cycle=0 p50_cycle=0 p95_cycle=0 p99_cycle=0 max_cycle=0
    local throughput=0 completion_rate=0 tasks_done=0 tasks_failed=0
    local cum_delay=0 avg_task_time=0 med_task_time=0
    local conflicts=0 reroutes=0 deadlocks=0
    local avg_idle=0 utilization=0
    local avg_info_age=0 max_info_age=0
    local wp_sat_avg=0 wp_sat_max=0 sec_congestion=0
    local avg_cpu=0 peak_mem=0
    local avg_latency=0 p95_latency=0

    if [ -f "$cycle_csv" ] && [ "$(wc -l < "$cycle_csv")" -gt 1 ]; then
        # Warmup satirlarini atla (ilk WARMUP_MIN * 60 / tahmini_cycle_suresi)
        # Basitlestirme: ilk %33 satiri warmup olarak atla
        local total_lines=$(( $(wc -l < "$cycle_csv") - 1 ))
        local skip_lines=$(( total_lines / 3 ))
        local measure_lines=$(( total_lines - skip_lines ))

        if [ "$measure_lines" -gt 0 ]; then
            # cycle_duration_ms sutunu (4. sutun)
            avg_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                awk '{ sum += $1; n++ } END { if(n>0) printf "%.2f", sum/n; else print 0 }')
            max_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | tail -1)
            # p50, p95, p99
            p50_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | awk -v p=0.50 'NR==1{n=0} {a[n++]=$1} END{printf "%.2f", a[int(n*p)]}')
            p95_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | awk -v p=0.95 'NR==1{n=0} {a[n++]=$1} END{printf "%.2f", a[int(n*p)]}')
            p99_cycle=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f4 | \
                sort -n | awk -v p=0.99 'NR==1{n=0} {a[n++]=$1} END{printf "%.2f", a[int(n*p)]}')

            # Conflict sayisi (5. sutun toplami)
            conflicts=$(tail -n +$((skip_lines + 2)) "$cycle_csv" | cut -d',' -f5 | \
                awk '{ sum += $1 } END { print sum+0 }')
        fi
    fi

    # Sistem istatistikleri
    local stats_csv="$run_dir/system_stats.csv"
    if [ -f "$stats_csv" ] && [ "$(wc -l < "$stats_csv")" -gt 1 ]; then
        avg_cpu=$(tail -n +2 "$stats_csv" | cut -d',' -f2 | \
            awk '{ sum += $1; n++ } END { if(n>0) printf "%.2f", sum/n; else print 0 }')
        peak_mem=$(tail -n +2 "$stats_csv" | cut -d',' -f3 | \
            sort -n | tail -1)
    fi

    # metrics.json varsa oku
    local metrics_json="$run_dir/metrics.json"
    if [ -f "$metrics_json" ]; then
        throughput=$(python3 -c "import json; d=json.load(open('$metrics_json')); print(d.get('throughput_per_min', 0))" 2>/dev/null || echo 0)
        completion_rate=$(python3 -c "import json; d=json.load(open('$metrics_json')); print(d.get('task_completion_rate', 0))" 2>/dev/null || echo 0)
        tasks_done=$(python3 -c "import json; d=json.load(open('$metrics_json')); print(d.get('total_tasks_completed', 0))" 2>/dev/null || echo 0)
    fi

    # CSV'ye yaz
    echo "$experiment_id,A_scaling,$robot_count,baseline,$repeat,$seed,$DURATION_MIN,\
$avg_cycle,$p50_cycle,$p95_cycle,$p99_cycle,$max_cycle,\
$throughput,$completion_rate,$tasks_done,$tasks_failed,\
$cum_delay,$avg_task_time,$med_task_time,\
$conflicts,$reroutes,$deadlocks,\
$avg_idle,$utilization,\
$avg_info_age,$max_info_age,\
$wp_sat_avg,$wp_sat_max,\
$sec_congestion,\
$avg_cpu,$peak_mem,\
$avg_latency,$p95_latency" >> "$RESULTS_CSV"
}

# ── ANA DENEY DONGUSU ───────────────────────────────────────
EXPERIMENT_NUM=0
FAILED=0
START_TIME=$(date +%s)

for N in "${ROBOT_COUNTS[@]}"; do
    for R in $(seq 1 $REPEATS); do
        EXPERIMENT_NUM=$((EXPERIMENT_NUM + 1))
        SEED=$((N * 1000 + R))
        EXP_ID="A_N${N}_R${R}_${TIMESTAMP}"
        RUN_DIR="$RESULTS_BASE/run_${EXP_ID}"
        mkdir -p "$RUN_DIR"

        echo ""
        echo "================================================================"
        log_info "DENEY $EXPERIMENT_NUM / $TOTAL_EXPERIMENTS"
        log_info "Robot: $N | Tekrar: $R/$REPEATS | Seed: $SEED"
        echo "================================================================"

        # 1. Temizlik
        cleanup_environment

        # 2. Docker build
        log_info "Docker imajlari derleniyor..."
        cd "$PROJECT_DIR"
        docker compose build > "$RUN_DIR/build.log" 2>&1
        if [ $? -ne 0 ]; then
            log_error "Docker build basarisiz! Atlaniyor."
            FAILED=$((FAILED + 1))
            continue
        fi

        # 3. Harita olustur (N robota uygun)
        log_info "Harita olusturuluyor: $SCENARIO (N=$N)..."
        docker compose run --rm \
            -e ROBOT_COUNT=$N \
            -e RANDOM_SEED=$SEED \
            scenario python3 fleet_management/FmInterface.py generate "$SCENARIO" \
            > "$RUN_DIR/map_gen.log" 2>&1
        if [ $? -ne 0 ]; then
            log_warn "Harita olusturma basarisiz, varsayilan harita ile devam ediliyor."
        fi

        # 4. Docker ag konfigurasyonu
        patch_config_for_docker

        # 5. Altyapi baslat
        log_info "Altyapi baslatiliyor (MQTT, PostgreSQL, Simulator)..."
        docker compose up -d mqtt db simulator > /dev/null 2>&1
        if ! wait_for_postgres; then
            log_error "PostgreSQL hazir degil! Atlaniyor."
            cleanup_environment
            FAILED=$((FAILED + 1))
            continue
        fi
        log_ok "PostgreSQL hazir."

        # 6. Sistem istatistikleri toplayicisini baslat
        collect_system_stats "$RUN_DIR/system_stats.csv" "$STATS_INTERVAL" &
        STATS_PID=$!

        # 7. Deneyi calistir (zaman sinirli)
        log_info "Deney basliyor ($DURATION_MIN dakika)..."
        DURATION_SEC=$((DURATION_MIN * 60))

        timeout "${DURATION_SEC}s" docker compose run --rm \
            -e EXPERIMENT_ID="$EXP_ID" \
            -e ROBOT_COUNT=$N \
            -e RANDOM_SEED=$SEED \
            scenario python3 -u fleet_management/FmInterface.py run "$SCENARIO" \
            > "$RUN_DIR/experiment.log" 2>&1
        EXIT_CODE=$?

        # 8. Istatistik toplayiciyi durdur
        kill $STATS_PID 2>/dev/null || true
        wait $STATS_PID 2>/dev/null || true

        # 9. Cycle times CSV'yi kopyala
        if [ -f "$PROJECT_DIR/logs/cycle_times.csv" ]; then
            cp "$PROJECT_DIR/logs/cycle_times.csv" "$RUN_DIR/cycle_times.csv"
        fi

        # 10. Mevcut log dosyalarini kopyala
        cp "$PROJECT_DIR/logs/FmLogHandler.log" "$RUN_DIR/" 2>/dev/null || true

        # 11. Metrikleri cikar
        log_info "Metrikler cikartiliyor..."
        extract_metrics "$RUN_DIR" "$EXP_ID" "$N" "$R" "$SEED"

        if [ $EXIT_CODE -eq 124 ]; then
            log_ok "Deney zamana bagli olarak tamamlandi (timeout - beklenen davranis)."
        elif [ $EXIT_CODE -eq 0 ]; then
            log_ok "Deney basariyla tamamlandi."
        else
            log_warn "Deney hata ile sonuclandi (exit=$EXIT_CODE)."
        fi

        # Temizlik
        cleanup_environment

        # Ilerleme raporu
        ELAPSED=$(( $(date +%s) - START_TIME ))
        ELAPSED_MIN=$(( ELAPSED / 60 ))
        REMAINING=$(( (TOTAL_EXPERIMENTS - EXPERIMENT_NUM) * ELAPSED / EXPERIMENT_NUM / 60 ))
        log_info "Ilerleme: $EXPERIMENT_NUM/$TOTAL_EXPERIMENTS | Gecen: ${ELAPSED_MIN}dk | Tahmini kalan: ${REMAINING}dk"
    done
done

# ── Ozet Rapor ──────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  DENEY SETi A: TAMAMLANDI"
echo "================================================================"
echo ""
echo "  Toplam deney    : $TOTAL_EXPERIMENTS"
echo "  Basarili        : $((TOTAL_EXPERIMENTS - FAILED))"
echo "  Basarisiz       : $FAILED"
echo "  Sonuc CSV       : $RESULTS_CSV"
echo "  Detayli loglar  : $RESULTS_BASE/run_*/"
echo ""
echo "  Grafik olusturmak icin:"
echo "    python3 scripts/reviewer_experiments/plot_results.py --set A"
echo ""
echo "================================================================"
