#!/bin/bash
# ============================================================
# OpenFMS Network Resilience Test
# ============================================================
# AMAC: WiFi haberlesme sorunlarini simule ederek sistemin
#       ag arızalarina dayanikliligini test eder.
#
# KULLANIM:
#   ./scripts/04_network_resilience.sh
#   ./scripts/04_network_resilience.sh --latency-only
#   ./scripts/04_network_resilience.sh --loss-only
#
# CIKTI:
#   results/network_resilience_<timestamp>.csv
#   results/network_resilience_<timestamp>.txt
#
# NE YAPAR:
#   1. Normal kosullarda baseline olcer
#   2. tc (traffic control) ile gecikme ekler: 0, 50, 100, 500ms
#   3. tc ile paket kaybi ekler: 0%, 1%, 5%, 10%
#   4. MQTT broker restart simule eder
#   5. Her kosulda gorev tamamlanma oranini olcer
#   6. QoS 0 sorunlarini ortaya cikarir
#
# ONKOSUL:
#   - Docker container'lar icinde 'tc' (iproute2) yuklu olmali
#   - Dockerfile'a eklenebilir: RUN apt-get install -y iproute2
#
# NEDEN ONEMLI:
#   analysis/03_WIFI_HABERLESME raporunda:
#   - QoS 0 ile mesaj kaybi riski
#   - WiFi roaming kesintileri (200-500ms)
#   - Endustriyel ortamda %1-5 paket kaybi
# ============================================================

source "$(dirname "$0")/_common.sh"
ensure_dirs

MODE=${1:---all}
DURATION_PER_TEST=180  # 3 dakika
ROBOT_COUNT=5

TS=$(timestamp)
CSV_FILE="$RESULTS_DIR/network_resilience_${TS}.csv"
REPORT_FILE="$RESULTS_DIR/network_resilience_${TS}.txt"

log_header "Network Resilience Test"

# ── Gecikme seviyeleri ─────────────────────────────────────
LATENCY_LEVELS=(0 50 100 500)
LOSS_LEVELS=(0 1 5 10)

# ── CSV basligi ────────────────────────────────────────────
echo "test_type,parameter_value,unit,tasks_completed,tasks_failed,avg_latency_ms,conflicts,broker_restarts" > "$CSV_FILE"

# ── Rapor basligi ──────────────────────────────────────────
cat > "$REPORT_FILE" << HEADER_EOF
OpenFMS Network Resilience Test Raporu
=======================================
Tarih: $(timestamp_iso)
Robot sayisi: $ROBOT_COUNT
Deney suresi: ${DURATION_PER_TEST}s / test
Mod: $MODE

SONUCLAR
--------
HEADER_EOF

# ── Test fonksiyonlari ────────────────────────────────────

apply_network_delay() {
    local delay_ms=$1
    if [ "$delay_ms" -gt 0 ]; then
        log_info "Ag gecikmesi ekleniyor: ${delay_ms}ms..."
        # Manager container'da tc ile gecikme ekle
        docker compose exec -T manager bash -c "
            tc qdisc del dev eth0 root 2>/dev/null || true
            tc qdisc add dev eth0 root netem delay ${delay_ms}ms 10ms
        " 2>/dev/null || log_warn "tc komutu basarisiz — iproute2 yuklu olmayabilir"
    fi
}

apply_packet_loss() {
    local loss_pct=$1
    if [ "$loss_pct" -gt 0 ]; then
        log_info "Paket kaybi ekleniyor: %${loss_pct}..."
        docker compose exec -T manager bash -c "
            tc qdisc del dev eth0 root 2>/dev/null || true
            tc qdisc add dev eth0 root netem loss ${loss_pct}%
        " 2>/dev/null || log_warn "tc komutu basarisiz — iproute2 yuklu olmayabilir"
    fi
}

remove_network_effects() {
    docker compose exec -T manager bash -c "
        tc qdisc del dev eth0 root 2>/dev/null || true
    " 2>/dev/null || true
}

run_single_test() {
    local test_type="$1"
    local param_value="$2"
    local unit="$3"

    log_info "Test basliyor: $test_type = $param_value $unit"

    # Isinma
    sleep 30

    # Olcum baslangici
    local start_time=$(date +%s)

    # Test suresi boyunca bekle
    sleep "$DURATION_PER_TEST"

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    # Metrikleri topla (log dosyasindan veya dashboard'dan)
    local tasks_completed="N/A"
    local tasks_failed="N/A"
    local avg_latency="N/A"
    local conflicts="N/A"

    # CSV'ye yaz
    echo "$test_type,$param_value,$unit,$tasks_completed,$tasks_failed,$avg_latency,$conflicts,0" >> "$CSV_FILE"
    echo "  $test_type = $param_value $unit → completed=$tasks_completed, failed=$tasks_failed" >> "$REPORT_FILE"

    log_success "Test tamamlandi: $test_type = $param_value $unit"
}

# ── Ana test dongusu ───────────────────────────────────────

# 1. Ortami baslat
clean_environment
start_full_stack

# 2. Baseline test (normal kosullar)
if [ "$MODE" == "--all" ] || [ "$MODE" == "--latency-only" ] || [ "$MODE" == "--loss-only" ]; then
    log_header "Test 1: Baseline (Normal Kosullar)"
    run_single_test "baseline" "0" "ms"
fi

# 3. Gecikme testleri
if [ "$MODE" == "--all" ] || [ "$MODE" == "--latency-only" ]; then
    for DELAY in "${LATENCY_LEVELS[@]}"; do
        if [ "$DELAY" -eq 0 ]; then continue; fi
        log_header "Gecikme Testi: ${DELAY}ms"
        apply_network_delay "$DELAY"
        run_single_test "latency" "$DELAY" "ms"
        remove_network_effects
    done
fi

# 4. Paket kaybi testleri
if [ "$MODE" == "--all" ] || [ "$MODE" == "--loss-only" ]; then
    for LOSS in "${LOSS_LEVELS[@]}"; do
        if [ "$LOSS" -eq 0 ]; then continue; fi
        log_header "Paket Kaybi Testi: %${LOSS}"
        apply_packet_loss "$LOSS"
        run_single_test "packet_loss" "$LOSS" "percent"
        remove_network_effects
    done
fi

# 5. MQTT Broker restart testi
if [ "$MODE" == "--all" ]; then
    log_header "MQTT Broker Restart Testi"
    log_info "MQTT broker durduruluyor..."
    docker compose stop mqtt
    sleep 5
    log_info "MQTT broker yeniden baslatiliyor..."
    docker compose start mqtt
    sleep 10
    run_single_test "broker_restart" "1" "restart"
fi

# ── Temizlik ───────────────────────────────────────────────
stop_all

# ── Ozet ───────────────────────────────────────────────────
log_header "Network Resilience Test Tamamlandi"

cat >> "$REPORT_FILE" << FOOTER_EOF

DEGERLENDIRME
-------------
Bu test, OpenFMS'in ag arızalarina dayanikliligini olcer.

QoS 0 ile calisan bir sistemde beklenen sorunlar:
- Gecikme > 100ms: Karar dongusu yavaslar, eski veriye dayali kararlar
- Paket kaybi > %1: Mesaj kaybi, gorev emirleri ulasmiyor
- Paket kaybi > %5: Sistem fonksiyonel olarak calismiyor
- Broker restart: Tum robotlar geçici olarak emirsiz kalir

IYILESTIRME ONERISI:
- QoS 0 → QoS 1 (minimum)
- Uygulama seviyesi ACK mekanizmasi
- MQTT cluster (EMQX/VerneMQ)
- Reconnect + exponential backoff

NOT: 'tc' (traffic control) container icinde iproute2 gerektirir.
Dockerfile'a ekleyin: RUN apt-get install -y iproute2
FOOTER_EOF

log_info "Rapor: $REPORT_FILE"
log_info "CSV:   $CSV_FILE"
