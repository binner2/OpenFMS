# Neden Sorunlu? (Şüpheci Perspektif: Bug, Bellek, Ölçeklenebilirlik, Eşzamanlılık)

## 1) Genel Sorun Sınıfları

### A. Ağ / Wi‑Fi iletişimi
- Bağlantı modelinin tek broker merkezli olması, arıza alanını büyütür (SPOF).
- Wi‑Fi gibi kayıplı/jitter'lı ortamlarda mesaj sıralaması, tekrar teslimat ve idempotency stratejileri açıkça sistematikleştirilmemiş görünür.
- QoS kullanımı heterojen; bazı kritik akışlar QoS0 ile gönderiliyor. Bu, paket kaybında sessiz veri kaybı üretebilir.

### B. Eşzamanlılık ve yarış durumları
- Çok robot yönetimi hedeflenirken paylaşılan mutable state kullanımı, thread-safe garantisini zayıflatır.
- MQTT callback tarafı ile planlama/trafik döngüsü arasındaki veri bütünlüğü (atomic snapshot) net değil.
- Yeniden bağlanma döngülerinde backoff ve circuit-breaker mantığı sınırlı; bu durum bağlantı fırtınası (reconnect storm) üretebilir.

### C. Ölçeklenebilirlik
- Tek süreçte analitik + kontrol + görselleştirme yükünün birlikte çalışması, CPU ve GIL baskısı oluşturur.
- Kritik yol üzerinde DB erişimlerinin ve JSON işleme yükünün robot sayısıyla birlikte lineer/lineer-üstü büyüme riski var.
- Tek broker + tek DB örneği ile yatay ölçeklenme planı net değil.

### D. Operasyonel dayanıklılık
- SLO tabanlı işletim (örn. 99p komut gecikmesi) net tanımlı değil.
- Kaos testleri, ağ bozulması enjeksiyonu ve otomatik rollback stratejileri görünür değil.

## 2) Wi‑Fi Üzerinden Haberleşme Neden İyi Kurgulanmamış?

Wi‑Fi ortamı deterministik değildir: paket kaybı, kanal doluluğu, geçici erişim noktası kopmaları, roaming ve jitter doğaldır. Bu nedenle iyi tasarım, "bağlanınca çalışır" yaklaşımını aşmalı, "kısmi arızada da doğru davranır" ilkesini hedeflemelidir.

Mevcut yaklaşımın zayıflıkları:

1. **Güvenlik katmanı yetersizliği**
   - TLS/mTLS yoksa üretimde sahte yayıncı ve MITM riski oluşur.
2. **Teslimat semantiği zayıflığı**
   - QoS0 kritik telemetride kayıp demektir; QoS1/2 seçimi veri sınıfına göre yapılmalı.
3. **Oturum sürekliliği ve deduplikasyon eksikleri**
   - Ağ flap durumunda tekrar yayınlar için idempotent işlem anahtarı zorunlu olmalı.
4. **Backpressure yokluğu**
   - Broker veya tüketici yavaşladığında üretici hızını düşürecek akış kontrolü eksik.
5. **Gözlemlenebilirlik eksikliği**
   - Topic başına lag, drop, duplicate, reorder metrikleri standartlaştırılmalı.

## 3) Bellek Sızıntısı ve Kaynak Riskleri (Şüpheci Denetim)

Aşağıdaki riskler özellikle izlenmelidir:

- Sınırsız büyüyen in-memory cache/dictionary yapıları
- Uzun yaşayan thread'lerde kapanmayan kaynaklar
- Tekrarlanan log handler ekleme riskleri
- Büyük JSON payload'ların sık parse edilmesi nedeniyle GC baskısı

Belirti odaklı gözlem planı:
- RSS/PSS trendi (zaman-serisi)
- Cache boyutu (anahtar sayısı) ve TTL dışına taşan girdiler
- Dosya tanıtıcı (FD) sayısı
- Thread sayısı ve bekleme süreleri

## 4) Paralel Çalıştırılabilirlik ve Concurrency Değerlendirmesi

İki kritik ilke öneririm:

1. **Actor-benzeri ayrıştırma**: Robot başına olay kuyruğu + tek yazıcı prensibi.
2. **Snapshot temelli karar**: Trafik planı tek bir tutarlı anlık görüntü üzerinde hesaplanmalı.

"Hepsi shared object üstünden çözülsün" yaklaşımı kısa vadede kolay görünür ama uzun vadede yarış koşulu ve nondeterminism üretir.

## 5) "Judo Programlama" Bu Bağlamda İşe Yarar mı?

Judo metaforu (rakibin kuvvetini ona karşı kullanmak) yazılımda şu anlama gelir: sistemi brute-force büyütmek yerine darboğazı mimari akışla "dönüştürmek".

- **İşe yarar** çünkü: yoğun yükte merkezi kilitlere abanmak yerine, yükü olay akışı ve partition ile dağıtırsınız.
- **Yetersiz kalabilir** çünkü: fiziksel katman (Wi‑Fi RF çakışmaları) mimari incelikle tamamen ortadan kalkmaz.

Sonuç: Judo yaklaşımı gerekli ama tek başına yeterli değildir; RF planlama, AP yerleşimi, kanal planı ve QoS politikasıyla tamamlanmalıdır.
