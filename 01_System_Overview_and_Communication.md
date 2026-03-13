# OpenFMS Sistem Analizi ve Haberleşme Mimarisi İncelemesi

## 1. Projenin Amacı ve İşlevi

OpenFMS (Open Source Fleet Management System), Otonom Yönlendirmeli Araçların (AGV) ve mobil robotların kontrol edilmesi, görev planlamasının yapılması ve rotalandırılması amacıyla geliştirilmiş Python tabanlı açık kaynaklı bir filo yönetim sistemidir. Sistem, endüstri standardı olan VDA5050 protokolüne uygun bir mesajlaşma altyapısını MQTT üzerinden sağlamaktadır. PostgreSQL kullanılarak robot ve sistem durumlarının kalıcı hale getirilmesi (persistence) hedeflenmiştir.

Temel bileşenler şunlardır:
- **Bulanık Mantık (Fuzzy Logic) Temelli Görev Dağıtımı:** Batarya seviyesi, boşta bekleme süresi, seyahat mesafesi ve taşıma kapasitesi (payload) gibi değişkenler kullanılarak robotlara dinamik görev atanmaktadır.
- **Trafik ve Çakışma Yönetimi:** Kavşak noktalarında geçiş üstünlükleri (cross conflicts), varış noktasındaki bekleme çakışmaları (last-mile conflicts) ve kilitlenmeleri (deadlock) önlemek üzere özel bekleme düğümleri (waitpoints - Wx) üzerinden araç trafik akışı kontrol edilmektedir.
- **Simülatör Entegrasyonu:** `FmRobotSimulator.py` ile gerçek donanıma ihtiyaç duyulmadan VDA5050 mesajlaşması ve robot kinematiği simüle edilebilmektedir.

## 2. Sistemin Temel Sorunları

Akademik bir perspektifle sistem mimarisi incelendiğinde, projenin mevcut durumunda ciddi ölçeklenebilirlik, darboğaz (bottleneck) ve tek nokta hataları (SPOF - Single Point of Failure) barındırdığı görülmektedir:

1. **Ardışık İşlem Döngüsü (Sequential Main Loop) ve Python GIL Kısıtlaması:** `FmMain.main_loop()` içerisinde 1000'den fazla robotun durumlarının güncellenmesi ve kararlarının ardışık (sequential) olarak işletilmesi, Python'ın Global Interpreter Lock (GIL) mekanizması nedeniyle CPU'nun tek bir çekirdeğinde darboğaza sebep olmaktadır. Yüksek ölçeklerde bu durum, reaksiyon sürelerini dramatik şekilde artırır.
2. **Durum Paylaşımı ve "Shared Mutable State" Sorunları:** Sistemin `FmTrafficHandler` sınıfında paylaşımlı değişkenler kullanması (örn. `collision_tracker`, `last_traffic_dict`), eşzamanlı programlamada "Race Condition" (Yarış Durumu) ihtimalini artırır ve bellek sızıntılarına zemin hazırlar.
3. **Senkron Veritabanı ve Mesajlaşma Yükü:** 1000+ robot hedeflenirken, sistemin anlık veritabanı okuma/yazma (PostgreSQL) ve MQTT üzerinden haberleşme işlemlerini eşzamanlı (asenkron olmayan) yapısı, I/O darboğazlarına neden olmaktadır.

## 3. Wi-Fi Üzerinden Haberleşme ve MQTT Kurgusunun Analizi

Projenin iletişim katmanı tek bir Mosquitto MQTT broker'ı etrafında kurgulanmıştır. Tüm robotların aynı merkeze bağlandığı bu yapı, geleneksel **Yıldız (Star) Topolojisi** örneğidir.

### Neden Sorunlu ve Kötü Kurgulanmış?
1. **Tek Nokta Hatası (SPOF - Single Point of Failure):** Tekil Mosquitto düğümü, sistemin tam merkezinde yer alır. Bu broker'ın çökmesi veya ağ izolasyonunda kalması durumunda tüm 1000 robot kontrolden çıkar, yeni görev alamaz ve acil durum manevraları sekteye uğrar.
2. **Wi-Fi Yarı-Çift Yönlü (Half-Duplex) Doğası ve CSMA/CA Gecikmeleri:** Wi-Fi protokolünde ağ ortamı paylaşımlı bir iletim kanalıdır. 1000 adet mobil robotun yüksek frekansta (örneğin 10Hz) telemetri ve VDA5050 "state" verisi basması, aynı Access Point'e bağlı istemciler arasında "Collision Avoidance" (CSMA/CA) nedeniyle devasa jitter (gecikme sapması) yaratır. Geciken paketler trafik denetleyicisinde (FmTrafficHandler) yanlış konum verisine sebep olarak robotların çarpışmasına yol açar.
3. **Bölgesel (Spatial) Optimizasyonun Eksikliği:** Tüm haberleşmenin "kullar/v2/birfen/AGV-XXX/state" formatında tek bir broker ağına yüklenmesi, robotların sadece kendi yakınlarındaki robotlardan haberdar olmasını engelleyen bir tasarımdır. Halbuki fabrika sahasındaki bir robotun 500 metre ilerideki robotun MQTT telemetrisine doğrudan veya aynı hiyerarşide ihtiyacı yoktur.

### Nasıl Olmalıydı? (Akademik Öneriler)

Büyük ölçekli endüstriyel ortamlarda (1000+ robot), güvenilir, deterministik ve kayıpsız bir haberleşme mimarisi şu şekillerde kurulmalıdır:

1. **Dağıtık MQTT Kümelemesi (Clustering):** Tekil bir Mosquitto yerine **EMQX** veya **VerneMQ** gibi yatayda ölçeklenebilen, Erlang/OTP tabanlı "high-availability" (Yüksek Erişilebilirlik) sunan broker'lar kullanılmalıydı. Node'lar arası yük dağılımı yapılarak robotlar bölgelerine (zone) göre farklı broker node'larına bağlanmalıydı.
2. **Mesh (Örgü) veya Hibrit Ağ Topolojileri:** Wi-Fi'ın dezavantajlarını kapatmak için D2D (Device to Device) iletişim kurgulanabilir. Örneğin, ROS2'nin **DDS (Data Distribution Service)** standardı kullanılarak Multicast üzerinden robotların sadece kendi bölgelerindeki komşu robotlarla peer-to-peer haberleştiği, merkezi filo yöneticisinin ise sadece "global waypoint" emirlerini ilettiği bir kurgu, "Network Contention" (ağ çekişmesi) problemini doğrudan ortadan kaldırırdı.
3. **QoS (Quality of Service) ve Veri Seyreltme (Data Throttling):** VDA5050'nin yapısı gereği statik robotların da saniyede defalarca aynı konumu raporlaması gereksizdir. "Event-Driven" (olay güdümlü) durum yayınları yapılmalı veya QoS 1 seviyesinde paket tutunmaları azaltılmalıdır.
4. **Bölgesel (Zone-Partitioned) Haberleşme Alanları:** Konumsal olarak harita alt ağlara (subnets / zones) bölünmeli ve robotların iletişim kapsamı bulundukları bölgedeki alt-yöneticiye (edge device/broker) daraltılmalıdır.
