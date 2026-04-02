#!/bin/bash
# ============================================================
# OpenFMS Race Condition Detector
# ============================================================
# AMAC: Paylasilan kaynaklari (cache dict, set, counter) tarar
#       ve thread-safety eksikliklerini raporlar.
#
# KULLANIM:
#   ./scripts/09_race_condition_detector.sh
#
# CIKTI:
#   results/race_condition_report_<timestamp>.txt
#
# NE YAPAR:
#   1. Tum .py dosyalarinda paylasilan degiskenleri tespit eder
#   2. Bu degiskenlere erisim noktalarini (okuma/yazma) listeler
#   3. Lock/mutex korumasi olup olmadigini kontrol eder
#   4. MQTT callback vs Main loop thread cakismalarini tespit eder
#   5. Risk seviyesi atar (KRITIK / YUKSEK / ORTA / DUSUK)
#
# NEDEN ONEMLI:
#   analysis/04_ESMAMANLILIK.md:
#   - BUG-04: state.cache dict iterasyon sirasinda degisebilir
#   - online_robots set korumasiz
#   - collision_tracker atomik degil (read-modify-write)
#   - ThreadPool aktive edildiginde crash garantili
# ============================================================

source "$(dirname "$0")/_common.sh"
ensure_dirs

TS=$(timestamp)
REPORT_FILE="$RESULTS_DIR/race_condition_report_${TS}.txt"

log_header "Race Condition Detector"

cat > "$REPORT_FILE" << HEADER_EOF
OpenFMS Race Condition Analiz Raporu
=====================================
Tarih: $(timestamp_iso)

BU RAPOR NE GOSTERIR:
- Birden fazla thread tarafindan erisilebilecek paylasilan kaynaklar
- Bu kaynaklarin Lock/mutex ile korunup korunmadigi
- MQTT callback thread vs main loop thread cakismalari
- ThreadPoolExecutor aktive edildiginde olası yarış durumlari

PAYLASILAN KAYNAKLAR
--------------------
HEADER_EOF

RISK_COUNT=0

# ── Paylasilan degisken tespiti ────────────────────────────

check_shared_resource() {
    local name="$1"
    local pattern="$2"
    local description="$3"
    local severity="$4"

    # Yazma erisimi
    local writes=$(grep -rn --include="*.py" -E "$pattern" \
        "$PROJECT_ROOT/fleet_management" "$PROJECT_ROOT/submodules" 2>/dev/null)

    if [ -n "$writes" ]; then
        local write_count=$(echo "$writes" | wc -l)

        # Lock korunmasi var mi?
        local has_lock=$(grep -rn --include="*.py" -E "(with.*lock|_lock\.acquire|Lock\(\))" \
            "$PROJECT_ROOT/fleet_management" "$PROJECT_ROOT/submodules" 2>/dev/null | \
            grep -c "$name" || echo "0")

        local protection="YOK"
        if [ "$has_lock" -gt 0 ]; then
            protection="VAR ($has_lock lock referansi)"
            severity="DUSUK"
        fi

        RISK_COUNT=$((RISK_COUNT + 1))

        echo "" >> "$REPORT_FILE"
        echo "[$severity] $name" >> "$REPORT_FILE"
        echo "  Aciklama: $description" >> "$REPORT_FILE"
        echo "  Erisim sayisi: $write_count" >> "$REPORT_FILE"
        echo "  Lock korumasi: $protection" >> "$REPORT_FILE"
        echo "  Konumlar:" >> "$REPORT_FILE"
        echo "$writes" | head -10 >> "$REPORT_FILE"
        if [ "$write_count" -gt 10 ]; then
            echo "  ... ve $((write_count - 10)) ek konum" >> "$REPORT_FILE"
        fi

        if [ "$protection" == "YOK" ]; then
            echo -e "  ${RED}[$severity]${NC} $name — $description (Lock: YOK, $write_count erisim)"
        else
            echo -e "  ${GREEN}[KORUNUYOR]${NC} $name — $description ($protection)"
        fi
    fi
}

log_step "1/6" "Cache dict'leri taranıyor..."
check_shared_resource \
    "state_handler.cache" \
    "self\.cache\[.*\]\s*=" \
    "State cache — MQTT thread yazar, main loop okur/iterate eder" \
    "KRITIK"

log_step "2/6" "online_robots set taranıyor..."
check_shared_resource \
    "online_robots" \
    "online_robots\.(add|remove|discard|clear)" \
    "Online robot seti — MQTT thread ekler, main loop okur" \
    "YUKSEK"

log_step "3/6" "collision_tracker taranıyor..."
check_shared_resource \
    "collision_tracker" \
    "collision_tracker\s*\+=" \
    "Carpishma sayaci — read-modify-write atomik degil" \
    "ORTA"

log_step "4/6" "temp_robot_delay_time taranıyor..."
check_shared_resource \
    "temp_robot_delay_time" \
    "temp_robot_delay_time\[" \
    "Robot bekleme sureleri dict — paralel erisimde race condition" \
    "YUKSEK"

log_step "5/6" "last_traffic_dict taranıyor..."
check_shared_resource \
    "last_traffic_dict" \
    "last_traffic_dict" \
    "Son trafik durum dict — paralel erisimde overwrite" \
    "YUKSEK"

log_step "6/6" "DB baglanti havuzu taranıyor..."
check_shared_resource \
    "db_conn" \
    "self\.db_conn\.(cursor|commit|rollback)" \
    "Veritabani baglantisi — birden fazla thread ayni baglantıyı kullanabilir" \
    "YUKSEK"

# ── Lock kullanim ozeti ────────────────────────────────────
echo "" >> "$REPORT_FILE"
echo "LOCK KULLANIMI" >> "$REPORT_FILE"
echo "--------------" >> "$REPORT_FILE"

LOCK_DEFS=$(grep -rn --include="*.py" -E "(Lock\(\)|RLock\(\)|Semaphore\(\))" \
    "$PROJECT_ROOT/fleet_management" "$PROJECT_ROOT/submodules" 2>/dev/null)
LOCK_USES=$(grep -rn --include="*.py" -E "(with.*_lock|\.acquire\(\)|\.release\(\))" \
    "$PROJECT_ROOT/fleet_management" "$PROJECT_ROOT/submodules" 2>/dev/null)

echo "Lock tanimlari:" >> "$REPORT_FILE"
if [ -n "$LOCK_DEFS" ]; then
    echo "$LOCK_DEFS" >> "$REPORT_FILE"
else
    echo "  (Hicbir lock tanimlanmamis!)" >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "Lock kullanim noktalari:" >> "$REPORT_FILE"
if [ -n "$LOCK_USES" ]; then
    echo "$LOCK_USES" >> "$REPORT_FILE"
else
    echo "  (Hicbir lock kullanilmiyor!)" >> "$REPORT_FILE"
fi

# ── Thread modeli ozeti ────────────────────────────────────
echo "" >> "$REPORT_FILE"
echo "THREAD MODELI" >> "$REPORT_FILE"
echo "-------------" >> "$REPORT_FILE"

THREAD_REFS=$(grep -rn --include="*.py" -E "(threading\.|Thread\(|ThreadPoolExecutor|loop_start)" \
    "$PROJECT_ROOT/fleet_management" "$PROJECT_ROOT/submodules" 2>/dev/null)
echo "$THREAD_REFS" >> "$REPORT_FILE"

# ── Sonuc ──────────────────────────────────────────────────
echo "" >> "$REPORT_FILE"
echo "OZET" >> "$REPORT_FILE"
echo "-----" >> "$REPORT_FILE"
echo "Tespit edilen paylasilan kaynak: $RISK_COUNT" >> "$REPORT_FILE"

LOCK_DEF_COUNT=$(echo "$LOCK_DEFS" | grep -c "Lock" 2>/dev/null || echo "0")
echo "Tanimlanan Lock sayisi: $LOCK_DEF_COUNT" >> "$REPORT_FILE"

log_header "Sonuc"
if [ "$RISK_COUNT" -gt 0 ]; then
    log_warn "$RISK_COUNT paylasilan kaynak tespit edildi."
    log_warn "Mevcut Lock sayisi: $LOCK_DEF_COUNT"
    if [ "$LOCK_DEF_COUNT" -lt "$RISK_COUNT" ]; then
        log_error "Yetersiz koruma! $((RISK_COUNT - LOCK_DEF_COUNT)) kaynak korumasiz."
    fi
else
    log_success "Paylasilan kaynak riski tespit edilmedi."
fi

log_info "Rapor: $REPORT_FILE"
