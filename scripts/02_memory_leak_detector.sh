#!/bin/bash
# ============================================================
# OpenFMS Memory Leak Detector
# ============================================================
# AMAC: Bellek sizintisi tespiti icin Fleet Manager'i
#       belirli bir sure calistirip bellek kullanimini izler.
#
# KULLANIM:
#   ./scripts/02_memory_leak_detector.sh [sure_dakika] [robot_sayisi]
#   ./scripts/02_memory_leak_detector.sh 30 10
#
# CIKTI:
#   results/memory_leak_<timestamp>.csv  (zaman serisi)
#   results/memory_leak_<timestamp>.txt  (ozet rapor)
#
# NE YAPAR:
#   1. Docker ortamini baslatir (mqtt, db, simulator, manager)
#   2. Belirli araliklarla (10sn) container bellek kullanimini olcer
#   3. Bellek buyume trendini hesaplar
#   4. LEAK-01 (DB pool), LEAK-02 (logger), LEAK-03 (analytics_data)
#      icin gostergeler arar
#   5. CSV + metin ozet rapor uretir
# ============================================================

source "$(dirname "$0")/_common.sh"
ensure_dirs

DURATION_MIN=${1:-10}
ROBOT_COUNT=${2:-5}
SAMPLE_INTERVAL=10  # saniye
TOTAL_SAMPLES=$(( (DURATION_MIN * 60) / SAMPLE_INTERVAL ))

log_header "Memory Leak Detector"
log_info "Sure: ${DURATION_MIN} dakika | Robot: ${ROBOT_COUNT} | Ornekleme: her ${SAMPLE_INTERVAL}s"
log_info "Toplam ornekleme sayisi: $TOTAL_SAMPLES"

TS=$(timestamp)
CSV_FILE="$RESULTS_DIR/memory_leak_${TS}.csv"
REPORT_FILE="$RESULTS_DIR/memory_leak_${TS}.txt"

# ── Ortam hazirla ──────────────────────────────────────────
clean_environment
start_full_stack

# ── CSV basligi ────────────────────────────────────────────
echo "sample,elapsed_sec,manager_mem_mb,simulator_mem_mb,db_mem_mb,mqtt_mem_mb,manager_cpu_pct" > "$CSV_FILE"

# ── Veri toplama ───────────────────────────────────────────
log_header "Bellek Izleme Basliyor (${DURATION_MIN}dk)"

get_container_mem_mb() {
    local service="$1"
    local mem_bytes
    mem_bytes=$(docker stats --no-stream --format "{{.MemUsage}}" "openfms-${service}-1" 2>/dev/null | awk -F'/' '{print $1}' | tr -d ' ')
    # mem_bytes MiB or GiB olabilir
    if echo "$mem_bytes" | grep -q "GiB"; then
        echo "$mem_bytes" | sed 's/GiB//' | awk '{printf "%.1f", $1 * 1024}'
    elif echo "$mem_bytes" | grep -q "MiB"; then
        echo "$mem_bytes" | sed 's/MiB//'
    elif echo "$mem_bytes" | grep -q "KiB"; then
        echo "$mem_bytes" | sed 's/KiB//' | awk '{printf "%.2f", $1 / 1024}'
    else
        echo "0"
    fi
}

get_container_cpu() {
    local service="$1"
    docker stats --no-stream --format "{{.CPUPerc}}" "openfms-${service}-1" 2>/dev/null | tr -d '%' || echo "0"
}

FIRST_MEM=""
LAST_MEM=""

for i in $(seq 1 $TOTAL_SAMPLES); do
    ELAPSED=$((i * SAMPLE_INTERVAL))

    MGR_MEM=$(get_container_mem_mb "manager")
    SIM_MEM=$(get_container_mem_mb "simulator")
    DB_MEM=$(get_container_mem_mb "db")
    MQTT_MEM=$(get_container_mem_mb "mqtt")
    MGR_CPU=$(get_container_cpu "manager")

    echo "$i,$ELAPSED,$MGR_MEM,$SIM_MEM,$DB_MEM,$MQTT_MEM,$MGR_CPU" >> "$CSV_FILE"

    # Ilk ve son deger kaydet
    if [ "$i" -eq 1 ]; then
        FIRST_MEM="$MGR_MEM"
    fi
    LAST_MEM="$MGR_MEM"

    # Ilerleme goster
    if (( i % 6 == 0 )); then
        log_info "Ornekleme $i/$TOTAL_SAMPLES (${ELAPSED}s) — Manager: ${MGR_MEM}MB | CPU: ${MGR_CPU}%"
    fi

    sleep "$SAMPLE_INTERVAL"
done

# ── Analiz ─────────────────────────────────────────────────
log_header "Analiz"

# Bellek buyume hesapla
if [ -n "$FIRST_MEM" ] && [ -n "$LAST_MEM" ]; then
    MEM_GROWTH=$(echo "$LAST_MEM - $FIRST_MEM" | bc 2>/dev/null || echo "?")
    MEM_RATE=$(echo "scale=2; ($LAST_MEM - $FIRST_MEM) / $DURATION_MIN * 60" | bc 2>/dev/null || echo "?")
else
    MEM_GROWTH="?"
    MEM_RATE="?"
fi

# Rapor olustur
cat > "$REPORT_FILE" << REPORT_EOF
OpenFMS Memory Leak Detector Raporu
====================================
Tarih: $(timestamp_iso)
Sure: ${DURATION_MIN} dakika
Robot sayisi: ${ROBOT_COUNT}
Ornekleme araligi: ${SAMPLE_INTERVAL} saniye
Toplam ornekleme: ${TOTAL_SAMPLES}

SONUCLAR
--------
Baslangic bellek (Manager): ${FIRST_MEM} MB
Bitis bellek (Manager):     ${LAST_MEM} MB
Toplam artis:               ${MEM_GROWTH} MB
Artis hizi:                 ${MEM_RATE} MB/saat

DEGERLENDIRME
-------------
REPORT_EOF

# Karar ver
if [ "$MEM_GROWTH" != "?" ]; then
    GROWTH_INT=$(echo "$MEM_GROWTH" | awk '{printf "%d", $1}')
    if [ "$GROWTH_INT" -lt 10 ]; then
        echo "SONUC: TEMIZ — Bellek sizintisi tespit edilmedi." >> "$REPORT_FILE"
        echo "  Artis < 10 MB, normal GC davranisi icerisinde." >> "$REPORT_FILE"
        log_success "Bellek sizintisi tespit edilmedi (artis: ${MEM_GROWTH} MB)"
    elif [ "$GROWTH_INT" -lt 50 ]; then
        echo "SONUC: UYARI — Hafif bellek artisi tespit edildi." >> "$REPORT_FILE"
        echo "  Artis: ${MEM_GROWTH} MB / ${DURATION_MIN}dk" >> "$REPORT_FILE"
        echo "  Olasi kaynaklar:" >> "$REPORT_FILE"
        echo "    - analytics_data dict birikimi (LEAK-03)" >> "$REPORT_FILE"
        echo "    - latency_data bucket birikimi" >> "$REPORT_FILE"
        echo "  Oneri: Daha uzun sure (1-4 saat) ile tekrar test edin." >> "$REPORT_FILE"
        log_warn "Hafif bellek artisi: ${MEM_GROWTH} MB / ${DURATION_MIN}dk"
    else
        echo "SONUC: KRITIK — Bellek sizintisi tespit edildi!" >> "$REPORT_FILE"
        echo "  Artis: ${MEM_GROWTH} MB / ${DURATION_MIN}dk" >> "$REPORT_FILE"
        echo "  Tahmini 24 saatlik artis: ~$(echo "scale=0; $MEM_RATE * 24" | bc) MB" >> "$REPORT_FILE"
        echo "  Olasi kaynaklar:" >> "$REPORT_FILE"
        echo "    - LEAK-01: DB pool baglanti sizintisi (putconn cagirilmiyor)" >> "$REPORT_FILE"
        echo "    - LEAK-02: Logger handler birikimi" >> "$REPORT_FILE"
        echo "    - LEAK-03: analytics_data/orders_issued sinirsiz buyume" >> "$REPORT_FILE"
        echo "    - BUG-03: Kapatilmayan cursor'lar" >> "$REPORT_FILE"
        log_error "BELLEK SIZINTISI: ${MEM_GROWTH} MB / ${DURATION_MIN}dk (tahmini ${MEM_RATE} MB/saat)"
    fi
else
    echo "SONUC: Olcum yapilamadi." >> "$REPORT_FILE"
    log_warn "Bellek olcumu yapilamadi."
fi

echo "" >> "$REPORT_FILE"
echo "CSV verisi: $CSV_FILE" >> "$REPORT_FILE"

# ── Temizlik ───────────────────────────────────────────────
stop_all

log_info "Rapor: $REPORT_FILE"
log_info "CSV:   $CSV_FILE"
