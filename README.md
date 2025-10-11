# Ghost mit Third-Party-Proxy & Redis-Caching

Dieses Repository enthält eine Docker-Compose-Vorlage für eine datenschutzfreundliche Ghost-Installation. Alle externen Ressourcen (JSDelivr-Bibliotheken, YouTube-Embeds/Thumbnails) werden lokal unter `https://meine-website.de/proxy/…` geproxied und gecached. Ghost nutzt Redis für internes Caching und Traefik für SSL & Routing. 

## Features

- Ghost CMS in Docker  
- Nginx-Proxy für `/proxy/npm/` (24h Cache) und `/proxy/youtube/` (1h Cache)  
- Header-Strippen zum Schutz personenbezogener Daten  
- Redis-Cache-Adapter für Ghost  
- Traefik für SSL (Let's Encrypt) und Routing  
- Konfiguration über `.env`

> [!WARNING]
> ⚠️ Datenschutzfreundliche YouTube-Embeds funktionieren nur in Kombination mit meinem Theme [Spectre](https://github.com/hutt/spectre/blob/main/README.de.md#datenschutzfreundliche-youtube-video-einbettungen).

## Voraussetzungen

- Docker ≥ 20.10, Docker Compose ≥ 1.29  
- Domain mit DNS-Eintrag auf Ihren Server  
- Traefik v3 als Ingress (SSL, Compression). Installation:  
  https://goneuland.de/traefik-v3-installation-konfiguration-und-crowdsec-security/

## Projektstruktur

```
meine-website.de/
├── docker-compose.yml
├── .env
├── config.production.json
├── nginx-proxy.conf
├── content/          # Ghost-Daten, Themes
├── redis/            # Redis-Persistenz
└── proxy-cache/      # Nginx-Cache
```

## Installation

1. Repository klonen  
   ```
   git clone https://github.com/hutt/spectre-docker-compose.git meine-website.de
   cd meine-website.de
   ```
2. `.env` kopieren und anpassen  
   ```
   cp example.env .env
   # DOMAIN, GHOST_URL, SMTP, CACHE-Settings etc. setzen
   ```
3. Docker-Container starten  
   ```
   docker compose up -d
   ```
4. Logs prüfen  
   ```
   docker compose logs -f
   ```
