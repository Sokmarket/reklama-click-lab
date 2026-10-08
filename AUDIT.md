# A–Z Denetim ve Düzeltme Kaydı

Tarih: 2026-10-08

## Kritik bulgular

1. `privacy-analytics/index.html` açık rıza alıyor ancak `/track` endpoint'ine veri göndermiyordu.
   **Düzeltildi:** Onaydan sonra aynı-origin `POST /track` gönderiliyor.

2. `privacy-analytics/server.py` yalnızca `0.0.0.0` üzerinde çalışıyor ve önceki yapıda
   GitHub Pages ile gerçek analitik sunucusu birbirine karıştırılabiliyordu.
   **Düzeltildi:** Statik yayın ile Python/SQLite analitik katmanı README'de ayrıştırıldı.
   Sunucu artık proje kökündeki reklamı ve analitik sayfalarını da yerelden servis ediyor.

3. `privacy-analytics/index.html` IP almak için üçüncü taraf `ipify` servislerini kullanıyordu.
   **Düzeltildi:** Yerel sunucu kayıt isteği IP'yi sunucu tarafında alıyor; onay olmadan kayıt yok.

4. `/track` için rıza kontrolü, payload boyutu ve temel güvenlik başlıkları güçlendirildi.

5. Root `index.html` reklam görseli tıklanabilir değildi.
   **Düzeltildi:** Reklam artık `ref=AD001` ile analitik/onay akışına bağlanıyor.

6. `report.html` yalnızca IPv4 sağlayıcısına bağımlıydı.
   **Düzeltildi:** IPv6 destekli `api64.ipify.org` ilk sıraya alındı ve timeout/fallback eklendi.

7. `report.html` geo verisindeki `connection.domain` değeri CIDR olarak kullanılıyordu.
   **Düzeltildi:** Geçersiz CIDR ataması kaldırıldı; RDAP verisi varsa CIDR alanını dolduruyor.

8. `github-report.html` ve `ciktilar/002.html` IP Analytics adı taşımasına rağmen yalnızca tarayıcı
   telemetrisi gösteriyordu.
   **Düzeltildi:** Başlıkları `Browser Technical Report` olarak değiştirildi.

9. SQLite, log, `.env` ve Python cache dosyalarının repoya gitmemesi için `.gitignore` kontrol edildi.

## Testler

- Python `py_compile`: PASS
- Tüm HTML dosyaları Python HTML parser ile okundu: PASS
- Tüm inline JavaScript blokları Node `--check` ile doğrulandı: PASS
- Yerel bağlantı/asset kontrolü: PASS
- `GET /`, `/reklam.png`, `/privacy-analytics/`, `/privacy-analytics/report`, `/health`, `/api/count`: PASS
- `/track` + `consent:false`: reddedildi
- `/track` + `consent:true`: kayıt oluşturuldu
- `/api/count`: kayıt sayısını doğru verdi
- `/api/logs`: kayıt döndürdü
- Test SQLite dosyası ZIP'e dahil edilmedi.

## Önemli dağıtım notu

GitHub Pages Python çalıştırmaz. Bu nedenle GitHub Pages üzerinde HTML/PNG yayınlanabilir,
fakat SQLite tabanlı `/track`, `/api/logs` ve `/api/count` endpoint'leri çalışmaz.

Gerçek analitik için Python sunucusu veya başka bir backend gerekir.
