# Hakem Yanıtı Eylem Planı — Deneyler ve OpenRMF Karşılaştırması

**Tarih:** 2026-03-13
**Odak:** Hakem yorumlarına deneysel kanıtla yanıt verme
**Temel İlke:** Hakemler "mevcut sistemi daha büyük ölçekte test edin" diyor —
mimari yeniden yazım değil, deneysel kanıt üretimi gerekiyor.

---

## ÖNCELIK SIRASI

| # | Yorum | Öncelik | Efor | Çıktı |
|---|-------|---------|------|-------|
| 1 | M1.1+S2.1 Ölçeklendirme | YÜKSEK | 2-3 gün | Table I genişletme + kırılma noktası analizi |
| 2 | S2.2 OpenRMF Karşılaştırma | YÜKSEK | 3-4 gün | Karşılaştırmalı tablo (Table II yeni) |
| 3 | M1.2 Ablation Study | ORTA-YÜKSEK | 1-2 gün | 5-7 hedefli deney + ablation tablosu |
| 4 | S2.3 Hold-and-Wait | ORTA-YÜKSEK | 1-2 gün | Formal bound + S8/S9 test senaryoları |
| 5 | S2.4 Info Age | DÜŞÜK-ORTA | 0.5 gün | Tanım netleştirme + tablo eki |
| 6 | M1.3+M1.4 Metin | DÜŞÜK | 0.5 gün | Makale metin düzenlemesi |

---

## AŞAMA 1: ÖLÇEKLENDIRME DENEYLERİ (M1.1 + S2.1)

### 1.1 Amaç
Hakemlerin istediği: "20-50 robot ölçeğinde test edin, computational overhead raporlayın."
Stratejik yaklaşım: Kırılma noktasını bilimsel katkı olarak sun — "N robota kadar
doğrusal, N+k'dan sonra O(N²) darboğaz" gösterimi.

### 1.2 Deney Matrisi

| Robot (N) | Checkpoint | Waitpoint | Süre | Tekrar | Amaç |
|-----------|-----------|-----------|------|--------|------|
| 4 | 12 | 4 | 15dk | 3 | Baseline (Table I doğrulama) |
| 8 | 24 | 8 | 15dk | 3 | Mevcut Table I referans |
| 16 | 48 | 16 | 15dk | 3 | İlk ölçek artışı |
| 24 | 72 | 24 | 15dk | 3 | Hakem S2.1 alt sınır |
| 32 | 96 | 32 | 15dk | 3 | Hakem S2.1 orta |
| 48 | 144 | 48 | 15dk | 3 | Kırılma noktası tespiti |

**Toplam: 6 × 3 = 18 deney**

### 1.3 Yapılacak Kod Değişiklikleri

**a) FmMain.py — Cycle Time Instrumentasyonu**
- `main_loop()` içinde `time.perf_counter()` ile döngü süresi ölçümü
- Her döngüde `logs/cycle_times.csv`'ye kayıt
- Mevcut `patches/patch_fmmain_instrumentation.py` kullanılacak

**b) FmSimGenerator.py — Harita Ölçekleme**
- `GridFleetGraph(num_robots=N, num_waitpoints=N//2)` ile otomatik topoloji
- Sabit oran: 3N checkpoint + N/2 waitpoint (tıkanıklık yaratmamak için)
- `density_factor=3.0` sabit tutulacak (kontrollü deney)

**c) FmInterface.py — Deney Modu Eklentisi**
- Yeni `experiment` komutu: `FmInterface.py experiment --robots N --duration 15 --seed S`
- Otomatik analytics export (JSON + CSV)
- Warmup periyodu: ilk 5dk verisi atılacak

### 1.4 Ölçülecek KPI'lar

| KPI | Birim | Kaynak | Table I'e Eklenecek Mi |
|-----|-------|--------|----------------------|
| T_cycle (avg, p50, p95, p99) | ms | cycle_times.csv | Evet (yeni sütun) |
| Throughput | görev/dk | order tamamlanma | Evet |
| Cumulative Delay | s | mevcut metrik | Evet (zaten var) |
| Task Completion Rate | % | tamamlanan/toplam | Evet |
| Conflict Count | sayı | collision_tracker | Evet (zaten var) |
| CPU Usage (avg) | % | docker stats | Evet (yeni sütun) |
| Peak Memory | MB | docker stats | Evet (yeni sütun) |

### 1.5 Beklenen Çıktılar

1. **Table I Extended** — N=4..48 için tüm KPI'lar (mevcut Table I'in genişletilmiş hali)
2. **Figure: T_cycle vs N (log-log)** — O(N²) eğilimi gösteren grafik
3. **Figure: Throughput vs N** — Doğrusallıktan sapma noktası
4. **Figure: CPU/RAM vs N** — Computational overhead
5. **Makale metni:** "Sistem N=24'e kadar kabul edilebilir performans gösteriyor,
   N>32'de fetch_mex_data()'nın O(N²) karmaşıklığı baskın hale geliyor"

### 1.6 Script

Mevcut `A_scaling_experiment.sh` kullanılacak, ancak:
- Robot sayıları: `--robots 4,8,16,24,32,48`
- Tekrar: `--repeats 3` (5 yerine 3, süre tasarrufu)
- FmSimGenerator'un `num_robots` parametresi ile harita otomatik ölçeklenecek

---

## AŞAMA 2: OpenRMF KARŞILAŞTIRMASI (S2.2)

### 2.1 Amaç
Hakem: "Benchmark makalesi iddiasını desteklemek için OpenRMF ile doğrudan karşılaştırma şart."
Bu, üç PR'ın hiçbirinde karşılanmamış — sıfırdan yapılması gereken çalışma.

### 2.2 OpenRMF Kurulum Stratejisi

OpenRMF (open-rmf) açık kaynak bir ROS 2 tabanlı filo yönetim sistemi.
Docker üzerinden çalıştırılabilir.

**Adımlar:**
1. OpenRMF'nin Docker kurulumunu hazırla (`open-rmf/rmf_deployment_template` kullan)
2. Aynı harita topolojisini OpenRMF formatına dönüştür (building.yaml)
3. Aynı görev setini OpenRMF task API'sine gönder
4. Aynı KPI'ları ölç

### 2.3 Karşılaştırma Matrisi

| Parametre | OpenFMS | OpenRMF |
|-----------|---------|---------|
| Robot sayısı | 4, 8, 16 | 4, 8, 16 |
| Harita | Aynı topoloji | Aynı topoloji (dönüştürülmüş) |
| Görev tipi | %70 transport, %20 charge, %10 move | %70 transport, %20 charge, %10 move |
| Süre | 15dk (5dk warmup) | 15dk (5dk warmup) |
| Tekrar | 3 | 3 |

**Toplam: 3 × 3 × 2 = 18 deney (her sistem için 9)**

### 2.4 Karşılaştırılacak KPI'lar

| KPI | Neden Önemli |
|-----|-------------|
| Throughput | Temel verimlilik karşılaştırması |
| Cumulative Delay | Trafik yönetimi etkinliği |
| Task Completion Rate | Güvenilirlik |
| Conflict Count | Çakışma çözüm kalitesi |
| Setup Complexity | Kurulum ve konfigürasyon karmaşıklığı (nitel) |
| VDA 5050 Compliance | Protokol uyumu (nitel) |

### 2.5 Yapılacak İşler

**a) OpenRMF Docker ortamı hazırlama scripti**
- `scripts/reviewer_experiments/openrmf/setup_openrmf.sh`
- ROS 2 Humble + OpenRMF paketleri Docker image'ı
- Navigasyon haritası dönüştürücü (OpenFMS config.yaml → OpenRMF building.yaml)

**b) OpenRMF deney scripti**
- `scripts/reviewer_experiments/openrmf/run_openrmf_benchmark.sh`
- Aynı görev setini OpenRMF'ye gönderme
- KPI toplama (ROS 2 topic'lerden)

**c) Karşılaştırma rapor scripti**
- `scripts/reviewer_experiments/openrmf/compare_results.py`
- Yan yana tablo üretimi (LaTeX formatında)
- Bar chart: OpenFMS vs OpenRMF metrikleri

### 2.6 Alternatif Plan (OpenRMF Çalıştırılamazsa)

Eğer OpenRMF'nin Docker kurulumu pratik sorunlar nedeniyle başarısız olursa:
1. Salzillo [38]'ın yayınlanmış sonuçlarını tablo olarak al
2. Aynı koşullarda (benzer robot/görev sayısı) OpenFMS sonuçlarını karşılaştır
3. "Literature-based comparison" olarak sun
4. M1.3'teki dil yumuşatma ile birleştir: "direct comparison is planned as future work"

**Bu alternatif SADECE son çare olarak kullanılmalı — hakemler doğrudan
karşılaştırma istiyor.**

### 2.7 Beklenen Çıktı

- **Table II (yeni):** "OpenFMS vs OpenRMF Comparative Results"
- **Figure:** Bar chart — her KPI için yan yana karşılaştırma
- **Makale metni:** Section ile başlayan karşılaştırma tartışması

---

## AŞAMA 3: ABLATION STUDY (M1.2)

### 3.1 Amaç
Hakem: "Scheduling kapalıyken FIFO ne olur? Node reservation kaldırılsa?"
Strateji: 90+ deney yerine 5-7 hedefli deney.

### 3.2 Ablation Konfigürasyonları (5 senaryo)

| # | Config | Değişiklik | Beklenti |
|---|--------|-----------|----------|
| 1 | Baseline | Tüm bileşenler aktif | Referans |
| 2 | No-Fuzzy | Fuzzy → FIFO atama | Throughput düşer, idle time artar |
| 3 | No-Priority | Priority → FCFS conflict | Yüksek öncelikli görevler gecikmeli |
| 4 | No-Reroute | Reroute devre dışı | Deadlock süresi artar |
| 5 | No-Waitpoint | Waitpoint → yerinde dur | Conflict count patlar |

### 3.3 Parametre Hassasiyeti (3 ek deney)

Hakem spesifik olarak α, β, λ parametrelerini sormuş:

| # | Parametre | Varsayılan | Test | Amaç |
|---|-----------|-----------|------|------|
| 6 | idle_time max | 300s | 100s, 500s | Fuzzy hassasiyeti |
| 7 | battery threshold | 40% | 20%, 60% | Şarj kararı etkisi |

### 3.4 Deney Detayları

- Robot sayısı: **8** (Table I ile tutarlı)
- Süre: 15dk (5dk warmup)
- Tekrar: **3**
- **Toplam: 7 × 3 = 21 deney**

### 3.5 Yapılacak Kod Değişiklikleri

**FmTaskHandler.py — Ablation Toggle**
```python
# Çevre değişkeninden ablation config oku:
# ABLATION_CONFIG="disable_fuzzy=true"
ablation = os.environ.get("ABLATION_CONFIG", "")
if "disable_fuzzy" in ablation:
    # evaluate_robot_for_task() → return 1.0 (FIFO)
```

**FmTrafficHandler.py — Reroute/Waitpoint Toggle**
```python
if "disable_reroute" in ablation:
    # reroute_robot() → no-op
if "disable_waitpoints" in ablation:
    # _find_temporary_waitpoint() → return None (yerinde bekle)
```

### 3.6 Beklenen Çıktı

- **Table III (yeni):** Ablation Results — her config için KPI değerleri
- **Figure:** Stacked bar chart — her bileşenin % katkısı
- **Makale metni:** "Each component contributes X% to overall performance"

---

## AŞAMA 4: HOLD-AND-WAIT DOYGUNLUK (S2.3)

### 4.1 Amaç
Hakem: "Robot sayısı waitpoint kapasitesini aştığında ne olur?"
Formal cevap: |R| > |V_W| durumunun deneysel gösterimi.

### 4.2 Formal Bound Analizi

Mevcut topoloji: `config.yaml`'da waitpoint sayısı kontrol edilecek.
FmSimGenerator varsayılanı: `num_waitpoints=10`

**Teorem (makaleye eklenecek):**
```
V_W = toplam waitpoint sayısı
R = aktif robot sayısı
Güvenli operasyon garantisi: |R| ≤ |V_W|
|R| > |V_W| ⇒ en az k = |R| - |V_W| robot waitpoint bulamaz
⇒ _find_temporary_waitpoint() = None ⇒ robot yerinde durur
⇒ Potansiyel livelock (iki robot birbirini bekler, waitpoint yok)
```

### 4.3 Deney Matrisi

| N (Robot) | W (Waitpoint) | N/W Oranı | Beklenen Durum |
|-----------|--------------|-----------|---------------|
| 4 | 8 | 0.50 | Güvenli |
| 8 | 8 | 1.00 | Sınırda |
| 10 | 8 | 1.25 | İlk bozulma |
| 12 | 8 | 1.50 | Belirgin bozulma |
| 16 | 8 | 2.00 | Ciddi tıkanıklık |

- Waitpoint sabit: 8 (kasıtlı olarak düşük)
- Tekrar: 3
- **Toplam: 5 × 3 = 15 deney**

### 4.4 conflict_test.py Genişletmesi

Mevcut S1-S7'ye ek senaryolar:

**S8: Waitpoint Overflow**
- 4 robot, 2 waitpoint → 2 robot waitpoint bulamaz
- Beklenti: `_find_temporary_waitpoint()` None döner, robot yerinde bekler

**S9: Cascade Deadlock**
- 3+ robot döngüsel bağımlılık + yetersiz waitpoint
- Beklenti: Livelock tespiti ve süresi ölçümü

### 4.5 Beklenen Çıktı

- **Figure:** Conflict count vs N/W oranı (doygunluk eğrisi)
- **Figure:** Cumulative delay vs N/W (patlama noktası)
- **Makale metni:** Formal bound + "graceful degradation" veya "failure" tespiti
- **Genişletilmiş conflict_test.py** S8, S9 senaryoları ile

---

## AŞAMA 5: INFORMATION AGE (S2.4)

### 5.1 Amaç
Hakem: "Network latency ve information age farkını netleştirin."
Bu, en düşük eforlu yanıttır — çoğunlukla metin düzenlemesi.

### 5.2 Formal Tanımlar (makaleye eklenecek)

```
τ_network(t) = t_receive − t_send       (ağ iletim gecikmesi)
τ_age(t)     = t_decision − t_sample    (bilgi yaşı)
τ_staleness  = τ_age − τ_network        (cache bekleme süresi)
```

### 5.3 Doğrulama Deneyi

Mevcut E_information_age_experiment.sh kullanılacak, ancak kapsamı daraltılmış:
- Publish interval: 0.5s, 1.0s, 3.0s (sadece 3 değer)
- Robot: 8
- Tekrar: 3
- **Toplam: 3 × 3 = 9 deney**

### 5.4 Yapılacak Kod Değişikliği

`patches/patch_state_information_age.py` zaten hazır.
`compute_information_age()` fonksiyonu τ_age hesaplayacak.

### 5.5 Beklenen Çıktı

- Table I'e ek sütun: τ_age (ortalama bilgi yaşı)
- **Figure:** τ_network vs τ_age vs publish_interval
- Makale metni: 2-3 paragraf tanım netleştirmesi

---

## AŞAMA 6: METİN DÜZENLEMELERİ (M1.3 + M1.4)

### 6.1 M1.3 — Dil Yumuşatma
- "outperforms" → "provides comparable results"
- "superior" → "offers advantages in VDA 5050 compliance"
- OpenRMF karşılaştırma sonuçlarına göre calibrate edilecek

### 6.2 M1.4 — Novelty Gap Tablosu
Makaleye eklenecek tablo:

| Feature | OpenRMF | OpenFMS | Fark |
|---------|---------|---------|------|
| VDA 5050 | Kısmi | Tam | OpenFMS avantajı |
| Fuzzy Dispatch | Yok | Var | Yeni katkı |
| Hold-and-Wait | Priority-based | Priority + Waitpoint | Yeni katkı |
| Benchmarking | Yok | Var | Yeni katkı |

---

## UYGULAMA ZAMANLAMA PLANI

```
Gün 1-2:   AŞAMA 1 — FmMain instrumentasyon + ölçeklendirme deneyleri (N=4..48)
Gün 3-5:   AŞAMA 2 — OpenRMF Docker kurulumu + karşılaştırma deneyleri
Gün 6-7:   AŞAMA 3 — Ablation toggle kodları + 7 hedefli deney
Gün 8:     AŞAMA 4 — Hold-and-wait deneyleri + S8/S9 test senaryoları
Gün 9:     AŞAMA 5 — Information age deneyleri (3 değer)
Gün 10:    AŞAMA 6 — Tüm grafiklerin üretimi + makale metin düzenlemeleri
```

**Toplam deney: 18 + 18 + 21 + 15 + 9 = 81 deney**
(Önceki planın 141 deneyinden %43 azaltma — hakem odaklı optimizasyon)

---

## KRİTİK KARARLAR

### Karar 1: Kırılma Noktası = Bilimsel Katkı
O(N²) kırılma noktasını "başarısızlık" olarak değil, "bilimsel bulgu" olarak sun.
"Sistemimiz N=24'e kadar doğrusal ölçeklenir, ötesinde fetch_mex_data()'nın
quadratic karmaşıklığı baskın hale gelir" → Bu, hakemlerin istediği scaling
behavior analizi.

### Karar 2: OpenRMF Karşılaştırması Zorunlu
Bu makale "benchmark" iddia ediyor — benchmark olmadan benchmark makalesi olmaz.
En az N=4,8 ile karşılaştırma yapılmalı.

### Karar 3: Ablation Seçici Olmalı
90+ deney değil, 5-7 hedefli deney. Her biri spesifik bir hakem sorusuna cevap.

### Karar 4: conflict_test.py Silinmemeli, Genişletilmeli
S8 (waitpoint overflow) ve S9 (cascade deadlock) eklenmeli.

---

## DOSYA YAPISI (oluşturulacak/güncellenecek)

```
scripts/reviewer_experiments/
├── HAKEM_YANIT_EYLEM_PLANI.md          ← BU DOSYA
├── A_scaling_experiment.sh             ← mevcut, güncelle (robot sayıları)
├── B_ablation_experiment.sh            ← mevcut, güncelle (7 config)
├── D_saturation_experiment.sh          ← mevcut, güncelle (N/W oranları)
├── E_information_age_experiment.sh     ← mevcut, güncelle (3 interval)
├── run_all_experiments.sh              ← mevcut
├── plot_results.py                     ← mevcut, güncelle (karşılaştırma grafikleri)
├── patches/
│   ├── patch_fmmain_instrumentation.py ← mevcut
│   ├── patch_state_information_age.py  ← mevcut
│   └── patch_ablation_toggles.py       ← YENİ: ablation env var desteği
├── openrmf/                            ← YENİ DIZIN
│   ├── setup_openrmf.sh                ← OpenRMF Docker kurulumu
│   ├── convert_topology.py             ← config.yaml → OpenRMF building.yaml
│   ├── run_openrmf_benchmark.sh        ← OpenRMF deney scripti
│   └── compare_results.py              ← Yan yana karşılaştırma raporu
└── conflict_tests/                     ← YENİ DIZIN
    ├── S8_waitpoint_overflow.py         ← |R| > |V_W| senaryosu
    └── S9_cascade_deadlock.py           ← Döngüsel bağımlılık + yetersiz wp
```
