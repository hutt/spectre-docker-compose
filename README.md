# Ghost mit Spectre-Theme, Third-Party-Proxy & Redis-Caching (automatisches Deployment)

Dieses Repository enthält eine Docker-Compose-Vorlage für eine datenschutzfreundliche Ghost-Installation mkit aktiviertem [Spectre-Theme](https://github.com/hutt/spectre). Externe Ressourcen wie JSDelivr-Bibliotheken oder Thumbnails werden über `https://meine-website.de/proxy/…` lokal geproxied und gecached. Ghost nutzt Redis für internes Caching und optional Traefik für SSL & Routing (dafür einfach die `docker-compose.traefik.yaml` nutzen. 

> [!WARNING]
> Dieses Deployment eigenet sich nur für selbstgehostete Ghost-Instanzen. Das einfache Theme für fremdgehostete Ghost-Seiten gibt es [hier](https://github.com/hutt/spectre).

## Features
* **automatische Theme-Installation**: Das [Spectre Theme](https://github.com/hutt/spectre) für Blogs und Websites, die mit der Partei Die Linke zu tun haben, wird automatisch heruntergeladen und aktiviert.  
* **automatische Routen-Konfiguration**: Für gewöhnlich muss man statische Startseiten oder andere für ein Blogging-CMS „außerdewöhnlichere“ Features in Ghost mit einer YAML-Datei konfigurieren. Hier wird die sogenannte `routes.yaml` automatisch [für Spectre konfiguriert](bootstrap/routes.yaml).
* **Datenschutzfreundlich**: Ein lokaler Proxy cached Assets von JSDelivr und YouTube-Embeds ([Hier gibt es mehr Informationen dazu](https://github.com/hutt/spectre/blob/main/README.de.md#datenschutzfreundliche-youtube-video-einbettungen)). 
* **Vorkonfigurierte Inhalte**: 5 Beispiel-Seiten + 2 Beispiel-Posts
* **Redis**: Performance-Optimierung durch vorinstalliertes und -konfiguriertes Datenbank-Caching. 
* **traefik-kompatibel**: Es gibt optional eine Compose File mit Labels für Deployments mit [traefik](https://traefik.io/). Hier gibt es eine [gute Anleitung für Anfänger](https://goneuland.de/traefik-v3-installation-konfiguration-und-crowdsec-security/).
* **Konfiguration über `.env`-Datei**: Die wichtigsten Einstellungen können über eine Datei mit Umgebungsvariablen gesetzt werden (Vorlage: [example.env](example.env))

> [!IMPORTANT]
> Datenschutzfreundliche YouTube-Embeds funktionieren nur in Kombination mit meinem Theme Spectre. [Mehr Infos…](https://github.com/hutt/spectre/blob/main/README.de.md#datenschutzfreundliche-youtube-video-einbettungen)

## Voraussetzungen

- Server mit:
  - Docker
  - Docker Compose
  - Traefik v3 ([optional](docker-compose.traefik.yml); Bei GoNeuland gibt es eine [sehr gute und ausführliche Installationsanleitung](https://goneuland.de/traefik-v3-installation-konfiguration-und-crowdsec-security/))
- Domain und DNS-Record, der auf den Server zeigt

## Schnellstart

### nginx

Diese Version proxied den gesamten Netzwerkverkehr durch den nginx-Container. Third-Party-Requests an JSDelivr und für [datenschutzfreundliche YouTube-Embeds](https://github.com/hutt/spectre/blob/main/README.de.md#datenschutzfreundliche-youtube-video-einbettungen) werden ebenfalls durch nginx geleitet.

```bash
# Repository klonen & ins Arbeitsverzeichnis wechseln (Arbeitsverzeichnis ist hier "meine-website.de")
git clone https://github.com/hutt/spectre-docker-compose.git meine-website.de && cd meine-website.de

# Vorlage für Datei mit Umgebumngsvariablen kopieren und nach eigenen Bedürfnissen anpassen
cp example.env .env
nano .env # Anpassen: Domain, E-Mail, Passwort, Blog-Titel...

# Deps starten und Container hochfahren:
docker compose up -d

# Logs verfolgen
docker compose logs -f
```

### Mit traefik

Diese Version nutzt traefik als Reverse Proxy (externes Netzwerk `proxy`) und nginx als Caching-Proxy für Third-Party-Requests an JSDelivr und für [datenschutzfreundliche YouTube-Embeds](https://github.com/hutt/spectre/blob/main/README.de.md#datenschutzfreundliche-youtube-video-einbettungen). Grundlage ist [diese Anleitung](https://goneuland.de/traefik-v3-installation-konfiguration-und-crowdsec-security/).

```bash
# Repository klonen & ins Arbeitsverzeichnis wechseln (Arbeitsverzeichnis ist hier "meine-website.de")
git clone https://github.com/hutt/spectre-docker-compose.git meine-website.de && cd meine-website.de

# Vorlage für Datei mit Umgebumngsvariablen kopieren und nach eigenen Bedürfnissen anpassen
cp example.env .env
nano .env # Anpassen: Domain, E-Mail, Passwort, Blog-Titel...

# Deps starten und Container hochfahren:
docker compose -f docker-compose.traefik.yml up -d

# Logs verfolgen
docker compose -f docker-compose.traefik.yml logs -f
```

Nach etwa einer Minute sollte alles laufen.
