# OpenFMS Hakem Yorumları ve Analizi: Sentezlenmiş Revizyon ve Eylem Planı

Bu belge, hakem yorumlarının (M1.1-M1.4, S2.1-S2.4) gereksinimleri ile sistemin mevcut mimari durumunun çapraz analizini (cross-reference) yaparak, "Sistemi baştan yazmak" yerine **"Mevcut sistemin sınırlarını akademik olarak ispatlamak ve benchmarking iddialarını temellendirmek"** üzerine kurgulanmış eylem planını içerir.

## 1. Kodda ve Sistemde Yapılması Gerekenler

Hakemlerin asıl talebi sistemin mimari zafiyetlerinin düzeltilmesi değil, **bu zafiyetlerin (darboğazların) deneysel olarak ortaya konmasıdır.**

### A) Ölçeklendirme Kırılma Noktasının (Breaking Point) Tespiti (M1.1 / S2.1)
- **Gereksinim:** O(N²) zaman karmaşıklığına sahip `manage_traffic` fonksiyonunun 20-50 robot ölçeğinde nasıl davrandığını (Computational Overhead) ölçmek.
- **Kod Değişikliği:** Merkezi karar döngüsünün süresini ($T_{comp}$) ölçecek timer'lar sisteme eklenecek ve sonuçlar loglanacaktır. Eğer sistem 20 robotta kilitleniyorsa (Cumulative Delay 3000s+), bu "Başarısızlık" olarak değil, "Sistemin Doyma Noktası (Saturation Point)" olarak makaleye bilimsel bir katkı olarak eklenecektir.

### B) OpenRMF ile Doğrudan Karşılaştırma (S2.2)
- **Gereksinim:** "Başkası test etti" argümanı zayıftır. Aynı topoloji (`config.yaml`) kullanılarak OpenRMF'nin performansı ile OpenFMS'inki karşılaştırılmalıdır.
- **Eylem:** Deney scriptlerine (veya makale metnine), OpenRMF'nin `rmf_core` paketinin 18x15m grid üzerindeki 4, 8 ve 16 robotluk simülasyon sonuçlarını Baseline (Referans) olarak alacak bir yapı eklenecektir.

### C) Hold-and-Wait Çökme Durumu (Failure Mode) Analizi (S2.3)
- **Gereksinim:** Robot sayısı ($|R|$), haritadaki bekleme noktası kapasitesini ($|V_W|$) aştığında sistemin nasıl çöktüğünü (Secondary Congestion / Livelock) formal olarak kanıtlamak.
- **Kod Değişikliği:** `conflict_test.py` dosyasına $|R| > |V_W|$ durumunu zorlayan yeni bir test senaryosu (Örn: S8) eklenecektir. Kodda `_find_temporary_waitpoint` fonksiyonunun kapasite aşımında `None` dönmesi bir hata olarak değil, beklenen bir kısıt (graceful degradation veya livelock) olarak raporlanacaktır.

### D) Ağ Gecikmesi vs. Bilgi Yaşı (Network Latency vs. Information Age) (S2.4)
- **Gereksinim:** Makaledeki 0.01s sabit gecikmenin yanıltıcı olduğu vurgulanmalı ve Information Age formülü eklenmelidir.
- **Formülizasyon:**
  - $\tau_{network}(t) = t_{receive} - t_{send}$ (Paket iletim gecikmesi)
  - $\tau_{age}(t) = t_{decision} - t_{sample}$ (Bilgi yaşı; ölçüm ile karar anı arasındaki fark)
- **Eylem:** Deney çıktılarında $\tau_{age}$ metrik olarak kaydedilecek ve Throttled modda bilginin nasıl bayatladığı (stale) sayısal olarak gösterilecektir.

### E) Seçici Ablation Study (M1.2)
- **Gereksinim:** 90+ kombinasyon yerine, sadece hedefe yönelik bileşenlerin etkisini ölçmek.
- **Eylem:** Yalnızca şu 3 senaryo çalıştırılacaktır:
  1. *Baseline:* Fuzzy Scheduling + Node Reservation AÇIK
  2. *Ablation 1:* FIFO Scheduling + Node Reservation AÇIK (Fuzzy'nin katkısını ölçer)
  3. *Ablation 2:* Fuzzy Scheduling + Node Reservation KAPALI (Kilitlenmeleri izole eder)

---

## 2. Performans Metrikleri ve Veri Kaydetme Stratejisi

Deneyler sonucunda makalenin tablolarını (Table I) güncellemek için şu spesifik KPI'lar (Key Performance Indicators) kaydedilecektir:

1. **Information Age ($\tau_{age}$):** Robotun fiziksel konumu okuduğu an ile yöneticinin bu konumu işlediği an arasındaki ms cinsinden fark. (Throttled modda yüksek çıkması beklenir).
2. **Scheduling Computation Overhead ($T_{comp}$):** `manage_traffic` fonksiyonunun milisaniye cinsinden çalışma süresi. (Ölçeklendikçe O(N²) artışı ispatlamak için).
3. **Deadlock / Failure Count ($N_{deadlock}$):** $|R| > |V_W|$ olduğunda sistemin düştüğü livelock sayısı.
4. **Fleet Throughput ($R_{task}$):** Belirli bir simülasyon penceresinde (örn: 1 saat) tamamlanan görev sayısı (Task / Hour).

**Sonuçların Kaydedilmesi:**
Deney scriptleri (`run_scaling_experiments.py` vb.) çıktılarında bu KPI'ları parse ederek bir CSV (`results/scaling_metrics.csv` ve `results/ablation_metrics.csv`) dosyasına yazacaktır. Bu CSV dosyaları makale revizyonunda (Matplotlib ile çizdirilecek grafikleri desteklemek üzere) doğrudan kullanılacaktır.
