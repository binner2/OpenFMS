## 3. Performans Metrikleri (KPIs) ve Kayıt Yöntemi

Hakem yorumları M1.1, S2.1 ve S2.4 doğrudan metriklerin yetersizliği veya yanlış yorumlanmasına odaklanmaktadır. Bu bağlamda, her simülasyon deneyinde şu 5 temel KPI (Anahtar Performans Göstergesi) mutlaka PostgreSQL veritabanına periyodik (örneğin dakikada bir) veya olay bazlı (event-driven) kaydedilmelidir:

### KPI 1: Information Age ($A_{info}$) vs. Network Latency ($L_{net}$) (Yorum S2.4)
Hakem S2.4'ün eleştirisini kırmak için, ağ üzerinden geçen süreyi temsil eden **Network Latency** ile yöneticinin elindeki bilginin ne kadar eski olduğunu temsil eden **Information Age** ayrılmalıdır.
- **Kaydedilme Yöntemi:** Her `manage_traffic` döngüsünde, alınan VDA5050 state mesajının `timestamp` değeri ile o anki sistem saati (NTP senkronize edilmiş) arasındaki fark milisaniye cinsinden hesaplanıp ortalaması (rolling average) alınmalıdır. Throttled (kısılmış) modda bu değerin, $L_{net}$'ten bağımsız olarak daha yüksek çıkması (ve bu gerçeğin makalede dürüstçe raporlanması) beklenir.

### KPI 2: Scheduling Computation Overhead ($T_{comp}$) (Yorum M1.1)
Centralized Scheduler'ın (merkezi yöneticinin) ölçeklenme davranışını (scaling behavior) kanıtlamak için, karar mekanizmasının ne kadar süre harcadığı ölçülmelidir.
- **Kaydedilme Yöntemi:** Python kodunda `manage_robot()` ve `manage_traffic()` fonksiyonlarına decorator eklenerek veya `time.perf_counter()` ile çalışma süreleri ölçülecektir. X=10 robottan X=50 robota geçildiğinde bu sürenin O(N) veya O(N^2) olarak nasıl arttığı bir CSV tablosuna loglanacaktır. 100ms altı değerler endüstri standardı kabul edilebilir.

### KPI 3: Deadlock / Failure Count ($N_{deadlock}$) (Yorum S2.3)
"Hold-and-Wait" stratejisinin sınırlarını aşması durumunu test etmek için, sistemin kaç kez kilitlendiği veya ikincil tıkanıklığa (secondary congestion) yol açtığı sayılmalıdır.
- **Kaydedilme Yöntemi:** `_find_temporary_waitpoint` fonksiyonunun None dönmesi veya bir robotun ardışık 10 döngü boyunca hedefine ilerleyememesi (livelock/deadlock timeout) durumunda bir `deadlock_event` tablosuna kayıt atılacaktır.

### KPI 4: Fleet Throughput ($R_{task}$)
Tüm filonun dakikada tamamladığı görev sayısıdır.
- **Kaydedilme Yöntemi:** `orders` tablosundaki `completion_timestamp` kayıtları üzerinden, simülasyon süresince (örneğin 2 saat) tamamlanan toplam görev sayısının süreye bölünmesiyle elde edilir. Bu metrik, ablation study (bileşen kapatma) deneylerinde sistemin verimliliğini kıyaslamak için temel başarı kriteridir.

### KPI 5: Average Idle / Wait Time per Robot ($T_{wait}$)
Robotların görev yapmadan sadece yol vermek veya kilitlenmeyi açmak için harcadıkları boş zaman.
- **Kaydedilme Yöntemi:** VDA5050 durum mesajlarındaki `driving=False` ve `operating_mode=WAITING` sürelerinin toplamı olarak hesaplanmalıdır.

---

### Sonuçların Nasıl Kaydedileceği (Data Pipeline)
Deneyler sırasında devasa miktarda log üretilecektir. Sonuçların betimleyici (descriptive) doğadan çıkıp analitik bir forma kavuşması için:
1. Her deney (run) benzersiz bir `experiment_id` ile PostgreSQL `experiments` tablosuna başlatılacak.
2. `state_history` ve `order_history` tablolarından veriler çekilerek, hazırlanan deney scriptleri (`run_scaling_experiments.py`) aracılığıyla Pandas DataFrame'lerine dönüştürülecek.
3. Çıktılar (aggregations) CSV formatında dışa aktarılacak ve Matplotlib/Seaborn kullanılarak ısı haritaları, P99 (yüzdelik) gecikme grafikleri çizdirilecektir.