# Reklama Click Lab

Reklam görseli ve **açık rıza tabanlı yerel analitik** test projesidir.

## Yapı

- `index.html` — reklam görseli. Tıklanınca `privacy-analytics/?ref=AD001` sayfasına gider.
- `reklam.png` — reklam görseli.
- `privacy-analytics/index.html` — açık rıza ekranı.
- `privacy-analytics/server.py` — yalnızca rıza verildikten sonra `/track` üzerinden kayıt alan yerel Python sunucusu.
- `privacy-analytics/report.html` — kayıtları gösteren yönetim raporu.
- `ciktilar/` — statik HTML rapor arşivi.
- `report.html` — bağımsız tarayıcı/IP teknik rapor sayfası; analitik kayıt servisine bağlı değildir.
- `github-report.html` — statik tarayıcı teknik raporu.

## Yerel analitik sunucusunu çalıştırma

Termux / Linux:

```bash
cd privacy-analytics
python3 server.py
```

Sonra:

```text
http://0.0.0.0:8080/
```

Rapor:

```text
http://0.0.0.0:8080/report
```

Sağlık kontrolü:

```text
http://0.0.0.0:8080/health
```

### Port değiştirme

```bash
ANALYTICS_PORT=8090 python3 server.py
```

LAN üzerinden erişim gerekiyorsa ayrıca bilinçli olarak:

```bash
ANALYTICS_HOST=0.0.0.0 ANALYTICS_PORT=8080 python3 server.py
```

Bu durumda sunucuyu internete doğrudan açmadan önce erişim kontrolü ve HTTPS/proxy katmanı ekleyin.

## GitHub Pages sınırı

GitHub Pages statik hostingdir. `server.py`, SQLite ve `/track` endpoint'i GitHub Pages üzerinde çalışmaz.

Bu nedenle:

- GitHub Pages: görsel ve statik HTML yayınlama.
- Python sunucusu: gerçek kayıt/SQLite analitiği.

GitHub Pages üzerinde yalnızca statik bir sayfa yayınlamak, kayıtların GitHub deposuna otomatik yazıldığı anlamına gelmez.

## Gizlilik

Kayıt yalnızca kullanıcı açıkça **“Onaylıyorum ve devam et”** düğmesine bastıktan sonra yapılır.

Sunucu aşağıdaki alanları kaydedebilir:

- IP adresi
- zaman damgası
- User-Agent
- Referer
- rapor referansı

`analytics.sqlite3`, log ve ortam dosyaları `.gitignore` içindedir ve repoya gönderilmemelidir.

## Hızlı doğrulama

```bash
python3 -m py_compile privacy-analytics/server.py
python3 privacy-analytics/server.py
```

Başka bir terminalden:

```bash
curl http://0.0.0.0:8080/health
curl http://0.0.0.0:8080/api/count
```

`/track` endpoint'i `consent: true` olmadan kayıt kabul etmez.
