# Ghost mit Third-Party-Proxy & Redis-Caching

Dieses Repository enthält eine Docker-Compose-Vorlage für eine datenschutzfreundliche Ghost-Installation. Alle externen Ressourcen (JSDelivr-Bibliotheken, YouTube-Embeds/Thumbnails) werden lokal unter `https://meine-website.de/proxy/…` geproxied und gecached. Ghost nutzt Redis für internes Caching und Traefik für SSL & Routing. 

## Features

✅ **Vollautomatische Einrichtung**: Kein manueller Aufwand im Admin-Interface  
✅ **Spectre-Theme**: Automatischer Download und Aktivierung  
✅ **Vorkonfigurierte Inhalte**: 5 statische Seiten + 2 Beispiel-Posts  
✅ **Smart Routing**: Blog unter `/blog/`, Presse unter `/presse/mitteilungen/`  
✅ **Datenschutzfreundlich**: Lokaler Proxy für externe Assets (NPM, YouTube)  
✅ **Redis-Caching**: Optimierte Performance  
✅ **Traefik-Integration**: SSL und Routing
✅ **Konfiguration über `.env`**

> [!WARNING]
> Datenschutzfreundliche YouTube-Embeds funktionieren nur in Kombination mit meinem Theme [Spectre](https://github.com/hutt/spectre/blob/main/README.de.md#datenschutzfreundliche-youtube-video-einbettungen).

## Voraussetzungen

- Docker ≥ 20.10, Docker Compose ≥ 1.29  
- Domain mit DNS-Eintrag auf Ihren Server  
- Traefik v3 als Ingress (SSL, Compression). Installation:  
  https://goneuland.de/traefik-v3-installation-konfiguration-und-crowdsec-security/

## Schnellstart

Repository klonen

```bash
git clone https://github.com/hutt/spectre-docker-compose.git meine-website.de
cd meine-website.de
```

Umgebungsvariablen konfigurieren

```bash
cp example.env .env
nano .env # Anpassen: Domain, E-Mail, Passwort, Blog-Titel...
```

Starten
```bash
docker compose up -d
```

Logs verfolgen

```bash
docker compose logs -f ghost-bootstrap
```

Nach ca. 2-3 Minuten ist das Grundgerüst der Website fertig.
