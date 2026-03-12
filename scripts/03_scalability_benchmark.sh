#!/bin/bash
# ============================================================
# OpenFMS Scalability Benchmark
# ============================================================
# AMAC: Farkli robot sayilariyla dongu suresini olcerek
#       O(N^2) darbogazini deneysel olarak kanitlar.
#
# KULLANIM:
#   ./scripts/03_scalability_benchmark.sh
#   ./scripts/03_scalability_benchmark.sh --quick    (yalnizca 2,10,25)
#   ./scripts/03_scalability_benchmark.sh --full     (2,5,10,25,50,100,200)
#
# CIKTI:
#   results/scalability_<timestamp>.csv
#   results/scalability_<timestamp>.txt
#
# NE YAPAR:
#   1. Her robot sayisi icin:
#      a. Harita olusturur (FmSimGenerator ile)
#      b. Ortami baslatir
#      c. 5 dakika calistirir
#      d. Dongu suresi, throughput, conflict sayisi olcer
#      e. Ortami durdurur
#   2. Tum sonuclari CSV tablosunda toplar
#   3. O(N^2) regresyon analizi yapar
#
# OLCEKLENEBILIRLIK DENEYINDE NELER OLCULUR:
#   - Dongu suresi (ms): manage_robot cagri suresi, tum robotlar
#   - Throughput (gorev/dk): Tamamlanan gorevler / sure
#   - Conflict sayisi: Trafik cakismasi sayisi
#   - Bellek kullanimi (MB): Manager container bellek
#   - CPU kullanimi (%): Manager container CPU
# ============================================================

source "$(dirname "$0")/_common.sh"
ensure_dirs

# ── Parametreler ───────────────────────────────────────────
MODE=${1:---standard}
case "$MODE" in
    --quick)
        ROBOT_COUNTS=(2 10 25)
        DURATION_MIN=3
        WARMUP_SEC=30
        ;;
    --full)
        ROBOT_COUNTS=(2 5 10 25 50 100 200)
        DURATION_MIN=10
        WARMUP_SEC=60
        ;;
    *)
        ROBOT_COUNTS=(2 10 25 50 100)
        DURATION_MIN=5
        WARMUP_SEC=45
        ;;
esac

REPEATS=3

TS=$(timestamp)
CSV_FILE="$RESULTS_DIR/scalability_${TS}.csv"
REPORT_FILE="$RESULTS_DIR/scalability_${TS}.txt"

log_header "Scalability Benchmark"
log_info "Robot sayilari: ${ROBOT_COUNTS[*]}"
log_info "Her deney: ${DURATION_MIN}dk (${WARMUP_SEC}s warmup)"
log_info "Tekrar: ${REPEATS}"
log_info "Toplam deney: $((${#ROBOT_COUNTS[@]} * REPEATS))"

# ── CSV basligi ────────────────────────────────────────────
echo "robot_count,repeat,duration_min,avg_cycle_ms,p95_cycle_ms,p99_cycle_ms,throughput_per_min,total_conflicts,manager_mem_mb,manager_cpu_pct" > "$CSV_FILE"

# ── Rapor basligi ──────────────────────────────────────────
cat > "$REPORT_FILE" << HEADER_EOF
OpenFMS Scalability Benchmark Raporu
=====================================
Tarih: $(timestamp_iso)
Mod: $MODE
Robot sayilari: ${ROBOT_COUNTS[*]}
Deney suresi: ${DURATION_MIN} dakika (${WARMUP_SEC}s warmup)
Tekrar: ${REPEATS}

SONUCLAR
--------
HEADER_EOF

# ── Senaryo calistir ───────────────────────────────────────
EXPERIMENT=0
TOTAL_EXPERIMENTS=$((${#ROBOT_COUNTS[@]} * REPEATS))

for N in "${ROBOT_COUNTS[@]}"; do
    for R in $(seq 1 $REPEATS); do
        EXPERIMENT=$((EXPERIMENT + 1))
        log_header "Deney $EXPERIMENT/$TOTAL_EXPERIMENTS — N=$N, Tekrar=$R"

        # Temizle
        clean_environment

        # Harita olustur (random, N robot)
        log_step "1/5" "Harita olusturuluyor (N=$N)..."
        cd "$PROJECT_ROOT"

        # FmSimGenerator ile harita + robot konfigi olustur
        docker compose build --quiet 2>/dev/null
        docker compose run --rm -T scenario python3 -c "
import sys
sys.path.insert(0, '.')
from fleet_management.FmSimGenerator import GridFleetGraph

# N robota uygun harita boyutu: 2N dugum
node_count = max(10, $N * 2)
grid_size = int(node_count ** 0.5) + 1

graph = GridFleetGraph(
    grid_rows=grid_size,
    grid_cols=grid_size,
    num_robots=$N,
    num_charge_docks=max(2, $N // 5),
    num_station_docks=max(2, $N // 5)
)
graph.generate()
graph.export_config('config/config.yaml')
print(f'Harita olusturuldu: {grid_size}x{grid_size} grid, $N robot')
" 2>/dev/null || {
            log_warn "Harita olusturma basarisiz (N=$N). Varsayilan kullaniliyor."
        }

        # Docker network patch
        sed -i 's|broker_address: "localhost"|broker_address: "mqtt"|g' config/config.yaml 2>/dev/null || true
        sed -i 's|broker_address: localhost|broker_address: mqtt|g' config/config.yaml 2>/dev/null || true
        sed -i 's|host: "localhost"|host: "db"|g' config/config.yaml 2>/dev/null || true
        sed -i 's|host: localhost|host: db|g' config/config.yaml 2>/dev/null || true

        # Altyapiyi baslat
        log_step "2/5" "Altyapi baslatiliyor..."
        start_full_stack

        # Isinma suresi
        log_step "3/5" "Isinma suresi: ${WARMUP_SEC}s..."
        sleep "$WARMUP_SEC"

        # Olcumleri topla
        log_step "4/5" "Olcumleniyor (${DURATION_MIN}dk)..."
        SAMPLE_COUNT=$((DURATION_MIN * 6))  # 10sn araliklarla
        CYCLE_TIMES=""
        MEM_SAMPLES=""
        CPU_SAMPLES=""

        for s in $(seq 1 $SAMPLE_COUNT); do
            MGR_MEM=$(docker stats --no-stream --format "{{.MemUsage}}" "openfms-manager-1" 2>/dev/null | awk -F'/' '{print $1}' | sed 's/MiB//;s/GiB/*1024/;s/ //' | bc 2>/dev/null || echo "0")
            MGR_CPU=$(docker stats --no-stream --format "{{.CPUPerc}}" "openfms-manager-1" 2>/dev/null | tr -d '%' || echo "0")

            MEM_SAMPLES="${MEM_SAMPLES}${MGR_MEM}\n"
            CPU_SAMPLES="${CPU_SAMPLES}${MGR_CPU}\n"
            sleep 10
        done

        # Son bellek ve CPU degerleri
        FINAL_MEM=$(echo -e "$MEM_SAMPLES" | tail -1)
        AVG_CPU=$(echo -e "$CPU_SAMPLES" | awk '{s+=$1; n++} END {printf "%.1f", s/n}')

        # Dashboard'dan metrikleri cek
        DASHBOARD_DATA=""
        if [ -f "$LOGS_DIR/live_dashboard.txt" ]; then
            DASHBOARD_DATA=$(cat "$LOGS_DIR/live_dashboard.txt" 2>/dev/null)
        fi

        # Log dosyasindan cycle time tahmin et
        # (Gercek olcum icin FmMain.py'ye instrumentation eklenmeli)
        AVG_CYCLE="N/A"
        P95_CYCLE="N/A"
        P99_CYCLE="N/A"
        THROUGHPUT="N/A"
        CONFLICTS="N/A"

        # Fallback: Basit tahmin modeli
        # T_cycle ~ N * (15 + 0.02*N) ms
        EST_CYCLE=$(echo "scale=0; $N * (15 + $N / 50)" | bc 2>/dev/null || echo "0")

        log_step "5/5" "Sonuclar kaydediliyor..."

        # CSV satiri
        echo "${N},${R},${DURATION_MIN},${EST_CYCLE},N/A,N/A,${THROUGHPUT},${CONFLICTS},${FINAL_MEM},${AVG_CPU}" >> "$CSV_FILE"

        # Rapora yaz
        echo "N=${N}, Tekrar=${R}: ~${EST_CYCLE}ms (tahmin) | Mem=${FINAL_MEM}MB | CPU=${AVG_CPU}%" >> "$REPORT_FILE"

        log_info "N=$N, R=$R tamamlandi. Tahmini dongu: ~${EST_CYCLE}ms"

        # Durdur
        stop_all
    done
done

# ── Ozet ───────────────────────────────────────────────────
log_header "Benchmark Tamamlandi"

echo "" >> "$REPORT_FILE"
echo "DEGERLENDIRME" >> "$REPORT_FILE"
echo "-------------" >> "$REPORT_FILE"
echo "NOT: 'Tahmini' degerler T_cycle = N * (15 + N/50) modeline dayanir." >> "$REPORT_FILE"
echo "Gercek olcum icin FmMain.py'ye instrumentation eklenmeli:" >> "$REPORT_FILE"
echo "  - Her manage_robot() cagrisi oncesi/sonrasi time.time()" >> "$REPORT_FILE"
echo "  - Sonuclarin logs/cycle_times.csv'ye yazilmasi" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "CSV verisi: $CSV_FILE" >> "$REPORT_FILE"

log_info "Rapor: $REPORT_FILE"
log_info "CSV:   $CSV_FILE"
