# Bu Repo Nedir, Ne İşe Yarar?

## 1) Amaç ve İşlevsel Kapsam

OpenFMS, AGV/AMR sınıfı robotlar için bir filo yöneticisi sunmayı amaçlar: görev üretimi/ataması, trafik çatışma çözümü, robot durum takibi, temel performans analizi.

Sistem; MQTT tabanlı VDA5050 benzeri topic yapısı, PostgreSQL kalıcılığı, terminal odaklı operasyon akışı ve simülatör bileşeni içerir. Kısaca: "robotlara iş ver, konum/süreç durumlarını topla, çakışmaları azalt, sonuçları raporla".

## 2) Mimari Karakteri

Mimari, klasik bir **monolitik orkestratör** modelidir:

- `FmMain`: ana döngü + MQTT callback köprüsü
- `FmScheduleHandler`: görev yaşam döngüsü
- `FmTrafficHandler`: düğüm/rota çatışma yönetimi
- `submodules/*`: VDA5050 mesaj türleri ve DB erişimi
- `FmRobotSimulator`: robot davranış emülasyonu

Bu yapı öğrenme ve hızlı prototipleme için güçlüdür; fakat üretimde "tek süreçte her şey" yaklaşımı kapasiteyi ve hata izolasyonunu sınırlayabilir.

## 3) Bu Çalışmanın Akademik Değeri

Repo, çok robotlu koordinasyon çalışmalarında aşağıdaki araştırma sorularına zemin olabilir:

- Merkezi denetleyici ile dağıtık denetleyicinin performans farkı
- Çatışma çözüm stratejilerinin throughput/latency etkisi
- Wi‑Fi kalitesi (packet loss/jitter) değişiminde görev tamamlama olasılığı
- QoS seviyelerinin durum tutarlılığına etkisi

Dolayısıyla repo "nihai ürün" olmasa da, **deneysel altyapı ve algoritmik kıyaslama platformu** olarak değerlidir.
