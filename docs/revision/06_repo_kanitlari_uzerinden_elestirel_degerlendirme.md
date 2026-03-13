# Repo Kanıtları Üzerinden Eleştirel Değerlendirme

Bu dosya, değerlendirmeyi soyut öneriden çıkarıp doğrudan repo içi gözlemlere bağlar.

## 1) İletişim Katmanı

- MQTT broker konfigürasyonu `allow_anonymous true` içeriyor; bu, üretim güvenlik modeli açısından risklidir.
- Varsayılan broker portu 1883 (plaintext), TLS/mTLS katmanı görünür değil.
- Birçok publish/subscribe akışında QoS0 kullanımı mevcut; kayıplı Wi‑Fi ortamında kritik telemetri için kırılgan olabilir.

## 2) Dayanıklılık / Yeniden Bağlanma

- Ana yöneticide reconnect denemesi sürekli döngü ile ele alınıyor; artan bekleme (exponential backoff) ve sınırlandırma (circuit-breaker) belirgin değil.
- Bu yaklaşım, broker arızalarında "reconnect storm" oluşturma riskini artırır.

## 3) Eşzamanlılık ve Döngü Modeli

- Kodda thread-safe DB proxy yaklaşımı var; olumlu bir adım.
- Buna rağmen ana kontrol döngüsü sürekli while-loop ve zaman tabanlı tetiklere bağlı.
- MQTT callback ile kontrol döngüsü arasında verinin "tutarlı anlık görüntü" olarak ele alınması açıkça ayrıştırılmamış.

## 4) Ölçüm ve Analitik

- Analitikte throughput, latency, idle gibi metrikler üretiliyor; bu güçlü bir başlangıç.
- Ancak istatistiksel deney protokolü (tekrar sayısı, güven aralığı, seed kontrolü) standartlaştırılmış görünmüyor.
- Bu nedenle çıkan grafikler açıklayıcı olsa da bilimsel genellenebilirlik sınırlı kalabilir.

## 5) Operasyonel Riskler

- Docker compose tek MQTT + tek DB topolojisi ile hızlı kurulum sağlıyor; fakat üretimde SPOF riski barındırıyor.
- TODO listesinde 1000+ robot ve star/mesh değerlendirmesi gibi kritik başlıklar hâlâ açık; bu da projenin mevcut olgunluk seviyesini doğruluyor.

## 6) Sonuç

Repo, güçlü bir araştırma platformu ve hızlı prototipleme zemini sunuyor; ancak Wi‑Fi altında yüksek güvenilirlik ve büyük ölçek hedefi için mimari ayrıştırma, güvenlik ve deney metodolojisi katmanlarında kapsamlı revizyon gerekli.
