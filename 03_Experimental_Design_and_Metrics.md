# Ölçeklenebilir Deneysel Çalışmalar ve Metrik Analizi

## 1. Deneysel Çalışmalar Nasıl Yapılmalı?

Bir filo yönetim sisteminin başarısı, yalnızca 5-10 robotluk demo ortamlarında değil, büyük veri ve trafik yükü altında (ölçeklenebilirlik - scalability) kanıtlanmalıdır. OpenFMS projesinde yer alan mevcut araçlarla (örneğin `FmSimGenerator.py` ve `FmInterface.py`) bu deneyler şu şekilde kurgulanabilir:

### a) Simülasyon Ortamının Hazırlanması (FmSimGenerator.py)
`FmSimGenerator` aracı, devasa ızgara (grid) veya rastgele düğüm ağları (graph) üretmek için kullanılır. Ölçeklenebilirlik testi için fiziksel olarak genişletilmiş, binlerce düğümden (`Cx`) ve bunlara bağlı bekleme noktalarından (`Wx`) oluşan test haritaları otomatik olarak yaratılmalıdır.
- **Harita Karmaşıklığı:** Sadece geniş alanlar değil, "darboğaz (bottleneck) koridorları", "çoklu kavşaklar" ve "tek yönlü yollar" içeren haritalar üretilmelidir.
- **Robot Ölçeklendirmesi:** Deneyler sırasıyla logaritmik olarak artan sayılarla yapılmalıdır: **10, 50, 100, 250, 500 ve 1000 robot**. 1000 sayısı, modern büyük e-ticaret (Amazon, Alibaba) depolarının ölçeğini yansıtan akademik bir "Stres Testi" sınırıdır.

### b) Trafik ve Görev Yükü Üretimi (FmInterface.py)
`FmInterface.py` üzerinden, robotlara sürekli (sürekli yenilenen - continuous dispatch) görev basan bir senaryo çalıştırılmalıdır. Robotların boş kalma (idle) süresi minimumda tutularak sistemin "Ağır Yük (Heavy Load)" altındaki davranışı incelenmelidir.

## 2. Mevcut Performans Metrikleri ve Yetersizlikleri

Proje raporunda (`project_report.md`) belirtilen mevcut metrikler şunlardır:
1. `compute_average_execution_duration`: Ortalama görev tamamlama süresi.
2. `compute_overall_throughput`: Dakika başına tamamlanan görev sayısı.
3. `compute_robot_avg_latency`: MQTT gecikmesi (Latency).
4. `collision_tracker`: Karşılaşılan trafik çakışma (conflict) sayısı.

### Mevcut Metrikler Neden Yetersizdir?
- **Sadece Ortalamalara (Mean) Odaklanılması:** Gecikmelerin aritmetik ortalamasını almak yanıltıcıdır. 99 robot 1 saniyede görev yaparken, 1 robot sistemdeki bir hata yüzünden 100 saniye kilitli kalıyorsa (deadlock), ortalama çok etkilenmez ama bu durum endüstriyel olarak kabul edilemezdir.
- **Kuyruk Gecikmesi (Tail Latency) Eksikliği:** P95 ve P99 (Yüzdelik dilim) metrikleri hesaplanmamaktadır.
- **Uzamsal Metriklerin Eksikliği:** Robotlar haritanın hangi bölgelerinde yığılıyor? Isı haritası (Heatmap) çıkarılmıyor.

## 3. Eklenmesi Gereken Yeni Performans Metrikleri ve Grafikler

Sistemi akademik olarak geçerli kılmak için şu metrikler ve grafikler şarttır:

### a) Gerekli Yeni Metrikler
1. **Yüzdelik Gecikme Dilimleri (P50, P90, P95, P99 Latency):** Sistemin en kötü senaryodaki (Tail Latency) yanıt süresini ölçer. Özellikle P99 gecikmesi MQTT broker ve TrafficHandler darboğazını doğrudan gösterir.
2. **Görev Kesinti / İptal Oranı (Task Preemption/Abort Rate):** Çözülemeyen kilitlenmeler (deadlock) nedeniyle yöneticinin kaç görevi iptal edip baştan başlatmak zorunda kaldığı.
3. **Robot Kullanım Oranı (Robot Utilization %):** Robotların toplam operasyon süresinin yüzde kaçını hareket ederek (productive), yüzde kaçını başkalarına yol vermek için bekleyerek (waiting/yielding) geçirdiği.
4. **Hesaplama Süresi (Computation Time per Cycle):** `FmMain` içindeki tek bir karar döngüsünün kaç milisaniye sürdüğü. 1000 robotta bu sürenin üstel olarak (O(N^2)) artıp artmadığını görmek elzemdir.

### b) Çizilmesi Gereken Grafikler
1. **Robot Sayısı vs. Throughput (Görev İşleme Hızı):** X ekseninde robot sayısı (10'dan 1000'e), Y ekseninde tamamlanan görev/saat. Sistem ölçeklenebilirse bu grafik doğrusal (linear) artmalı; darboğaz varsa belirli bir robot sayısından sonra plato çizmeli veya düşmelidir.
2. **Robot Sayısı vs. Ortalama ve P99 Karar Gecikmesi (Decision Latency):** O(N^2) karmaşıklığını görselleştirmek için.
3. **Uzamsal Bekleme Isı Haritası (Spatial Wait Heatmap):** Harita üzerinde robotların en çok bekleme (yield) yaptığı noktaların sıcaklık renkleriyle çizdirilmesi. Bu, "Trafik kilitlenmeleri yazılımsal mı yoksa harita dizaynından mı kaynaklanıyor?" sorusuna yanıt verir.
4. **Ağ Band Genişliği Kullanımı vs. Robot Sayısı:** MQTT üzerinden Wi-Fi ağına binen MB/s yükün grafiği. Ağ çökme noktasını (Saturation point) bulmak için gereklidir.

## 4. Sonuçların Yorumlanması ve Başarı Kriterleri

Projenin başarılı sayılabilmesi için şu eşiklerin geçilmesi gerekir:
- **Kilitlenme (Deadlock) Oranı:** 1000 robotluk ve 24 saatlik bir simülasyon testinde "Sıfır" manuel müdahale ve "Sıfır" sonsuz kilitlenme (unresolved deadlock).
- **P99 Karar Gecikmesi:** Sistemdeki en yüksek karar gecikmesinin (örneğin robotun durup yeniden yönlendirilmesi) < 500 ms olması. (Endüstriyel gerçek zamanlı sistem sınırı).
- **Ölçeklenebilirlik Eğrisi:** Robot sayısı 100'den 1000'e çıktığında toplam işlem hacminin (Throughput) düşmemesi, ideal olarak orantılı şekilde artması. Eksiye doğru bir kırılım noktası varsa (thrashing), proje o ölçekte başarısız kabul edilir.
