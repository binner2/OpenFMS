# Mimari Revizyon ve Eşzamanlı (Concurrent) Programlama Analizi

## 1. Kod Tabanında Bug ve Hata Analizi

OpenFMS projesinin kod tabanı incelendiğinde, eşzamanlı işlem ve ölçeklenebilirlik açısından ciddi yapısal sorunlar göze çarpmaktadır:

### a) Python GIL ve İş Parçacığı (Thread) Sorunları
Python'daki *Global Interpreter Lock (GIL)*, Python nesnelerine erişimi kilitler ve herhangi bir anda yalnızca tek bir iş parçacığının Python bayt kodunu yürütmesine izin verir. Projedeki `FmMain` döngüsü her ne kadar ThreadPool ve veri tabanı bağlantı havuzları (`ThreadedConnectionPool`) üzerinden paralelleştirilmeye çalışılsa da, CPU-bound olan trafik yönetimi (A* pathfinding, çarpışma tespiti `manage_traffic` vb.) GIL nedeniyle gerçek anlamda paralel çalışamaz.

### b) Paylaşımlı Mutable State (Shared State) ve Race Condition
`FmTrafficHandler` içerisinde robotların bekleme süreleri (`temp_fb_wait_time`) ve rezerve edilmiş noktalar (`last_traffic_dict`) gibi veriler sınıf/örnek (instance) seviyesinde paylaşımlı sözlüklerde tutulmaktadır. Birden fazla thread aynı anda bu değişkenleri değiştirdiğinde *Race Condition* ortaya çıkar. Bu durum, "yanlış düğüme rezervasyon yapılması" gibi ölümcül yönlendirme hatalarına (robotların fiziksel çarpışmasına) neden olabilir.

### c) Bellek Sızıntısı (Memory Leak) Eğilimleri
Eski bir `collision_tracker` (çarpışma izleyici) veri yapısı içinde listeler kullanılmış. Eğer bu tracker sınırsız şekilde büyür, tamamlanmış görevlerin ardından nesneler Garbage Collector'a bırakılmazsa veya MQTT abonelikleri (subscription callback) asenkron bağlanıp doğru kapatılmazsa (dangling callbacks) bellek sızıntıları kaçınılmazdır. Özellikle 1000 robot her saniye durum güncellediğinde, sürekli nesne üretimi belleği kısa sürede tüketecektir.

## 2. Revizyon Stratejisi: Nasıl Bir Programlama Yapılmalıydı?

Sistemi baştan yazacak olsaydım, "Concurrent" (Eşzamanlı) ve "Scalable" (Ölçeklenebilir) bir mimari kurgulardım:

### a) Programlama Dili ve Paradigma Seçimi
Sistem Python yerine eşzamanlılığın temel (first-class citizen) olduğu **Go (Golang)** veya bellek güvenliği (memory safety) garantisi veren **Rust** ile yazılmalıydı.
- **Go** ile binlerce `goroutine` yaratılarak her robotun (ya da her bölgenin) mesajları, kanallar (channels) üzerinden birbirlerini bloklamadan (non-blocking) yönetilebilirdi.
- Bu yapı, "Judo Programlama" konseptinde bahsedildiği gibi (sorunları güce karşı güçle değil, akışla yönetmek) verinin akışına göre tepki veren *Reaktif Mimariler (Reactive Architecture)* kurmayı kolaylaştırır.

### b) Actor Modeli Kullanımı
Paylaşımlı değişkenler (shared state) yerine **Actor Modeli** kullanılmalıdır (Örn: Erlang, Akka, veya Go'da Goroutine+Channels).
- Her robotun dijital ikizi (Digital Twin) bir "Actor" olmalıdır.
- Actor'ler state'lerini kendi içlerinde gizler ve diğer actor'ler ile sadece mesajlaşarak (message passing) iletişim kurarlar. Böylece mutex (kilit) kullanmaya gerek kalmaz, *Race condition* imkansız hale gelir.

### c) Asenkron I/O ve Event-Driven Kurgu
PostgreSQL sorguları ve MQTT işlemleri tamamen asenkron hale getirilmeliydi. (Python'da `asyncio` ile yapılabilirdi, ancak CPU darboğazını çözmezdi). I/O bekleme sürelerinde CPU boşa harcanmamalı.

### d) Veri Yapıları Optimizasyonu
Arama (lookup) işlemlerinin `O(N)` olan Listeler yerine `O(1)` olan Set veya Hash map yapılarında yapılması (proje raporunda düzeltildiği belirtilmiş ancak baştan böyle kurgulanmalıydı) şarttır.

## 3. Revizyon Uygulama Planı (Refactoring Plan)

Aşağıdaki plan, kodun tamamen revize edilmesini içermektedir:

1. **Gereksinim ve Metrik Belirleme:** VDA5050 mesaj protokolü gereksinimlerinin tam listesinin çıkarılması. "Başarı", 1000 robotun 10Hz'de sıfır hata (kilitlenme olmadan) koordine edilmesi olarak tanımlanır.
2. **Mimari Tasarım (Actor Modeli):** Go dili kullanılarak `RobotActor`, `ZoneActor` (Bölge yöneticisi) ve `MapActor` sınıflarının tanımlanması.
3. **Zone-Based (Bölgesel) Parçalama:** Harita karelere (grid veya voronoi hücreleri) ayrılarak, her bölgedeki trafiğin o bölgenin kendi `ZoneActor`'ü tarafından yönetilmesinin sağlanması (Yükün N parçaya bölünmesi).
4. **Memory State ve Cache:** Veritabanına anlık gitmek yerine, hızlı karar almak için Redb veya Redis gibi in-memory (bellek içi) önbellek yapıları kullanılması.
5. **Event-Sourcing Veri Modeli:** PostgreSQL sadece bir "State" tutucu olarak değil, eylemlerin olay dizisi (Event Sourcing) olarak kaydedildiği bir analitik deposu (CQRS mimarisi) olarak yapılandırılmalıdır.
6. **Stress Testleri Yaratılması:** Kodlama aşamasında Test-Driven Development (TDD) yaklaşımıyla, ilk olarak eşzamanlı erişim çatışmalarını (Race conditions) simüle eden testlerin yazılması.