# Radiofy

> Radio digital para la barra de menú de macOS.  
> No es un “siguiente” más: es un **sintonizador** sobre tus playlists de Spotify.

**3.5-MULTIVERSE** · macOS 10.15+ · Spotify Premium · Hecho en Chile

---

## El problema

Spotify en el Mac es un reproductor excelente… y un pésimo aparato de radio.

Si quieres vibe continuo —fiesta, foco, cocina, auto en la casa— terminas pelearte con la cola, el shuffle que se siente repetido, o saltar a mano. Radiofy nace de esa fricción: **tratar tu biblioteca como dial**, no como lista de tareas.

## La idea

Radiofy vive en la **menubar**. Abres el panel, eliges una fuente (Liked Songs o una playlist) y pulsas **Cambiar**. La app sintoniza otra canción de esa fuente, con el gesto de una radio FM: dial 88–108, frecuencia, tapa, y listo.

No reemplaza a Spotify. **Lo conduce.** Spotify sigue siendo el motor de audio; Radiofy es el mando y la metáfora.

### Qué sientes al usarlo

1. Eliges tu “emisora” (playlist) en **Mis radios**  
2. Pulsas **Cambiar** → otra frecuencia dentro de esa lista  
3. Si la canción te gusta desde el primer segundo, **Desde el inicio** la rebobina  
4. Con **Modo radio ON**, cuando termina una pista la siguiente puede entrar *a mitad* (como si sintonizaras al voleo). OFF = siempre desde el comienzo  
5. Clic en el logo → **vista mini** (tapa + tema + MHz + botones), siempre arriba, sin ocupar el escritorio

## Qué es técnicamente

App nativa de macOS (**Objective-C**) con la interfaz en **HTML/CSS/JS** dentro de un `WKWebView`.

La arquitectura importa porque Spotify castiga la Web API con cuotas (429). Por eso Radiofy es **local-first**:

| Capa | Para qué |
|------|----------|
| **Spotify.app + AppleScript** | Cambiar / seek / leer qué suena *en este Mac*, sin gastar cuota en cada sintonía |
| **Web API (OAuth PKCE)** | Login, listar playlists (con tapas), armar pool, y fallback si el camino local no alcanza |
| **Estado local** | Tokens, cache de playlists, preferencias en `~/Library/Application Support/Radio/` |

En corto: **Cambiar** intenta ser barato y rápido. La nube solo cuando hace falta.

## Requisitos

- macOS 10.15 o superior  
- [Spotify Premium](https://www.spotify.com/premium/) (sin Premium no puedes controlar la reproducción)  
- App de Spotify instalada y con sesión iniciada en el Mac  
- Una app propia en el [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) (Client ID)

La primera vez macOS pedirá permiso de **Automatización** (Radiofy → Spotify). Sin eso, el camino local no funciona.

## Instalar / compilar

```bash
cd radio
./build_mac.sh
open Radiofy.app
```

El script deja `Radiofy.app` listo. Para dejarlo fijo:

```bash
cp -R Radiofy.app /Applications/
```

## Conectar Spotify (una sola vez)

1. Crea una app en el [Developer Dashboard](https://developer.spotify.com/dashboard)  
2. En settings, añade **exactamente** este Redirect URI:

```text
http://127.0.0.1:29501/callback
```

3. Abre Radiofy desde la menubar  
4. Pega el **Client ID** y autoriza en el navegador  
5. Vuelve al panel: ya puedes elegir playlist y pulsar **Cambiar**

> Tip: el redirect es `127.0.0.1`, no `localhost`. Si no calza carácter por carácter, el login falla.

## Controles (mapa rápido)

| Control | Qué hace |
|---------|----------|
| **Cambiar** | Sintoniza otra canción de la fuente activa |
| **Desde el inicio** | Seek a 0 de la pista actual |
| **Dial / MHz** | Feedback visual de sintonía (no es FM real) |
| **Mis radios** | Tus playlists + Liked Songs |
| **Sonando en…** | Dispositivo / destino de Spotify en este Mac |
| **Switch (modo radio)** | ON entra a mitad al avanzar · OFF desde el inicio |
| **Logo** | Alterna panel completo ↔ vista mini |
| **i** | Acerca de (versión) |

## Privacidad

- Todo queda en tu Mac: `~/Library/Application Support/Radio/`  
- Log opcional: `radiofy.log` en esa misma carpeta  
- No hay backend de Radiofy: autenticas contra Spotify; tokens y refresh viven locales  
- La app pide Automatización solo para hablar con Spotify.app

## Desarrollo

Código principal:

```text
radio/
  main.m          # menubar, WKWebView, Spotify local + API, bridge
  ui/             # panel (HTML/CSS/JS)
  build_mac.sh    # compila y empaqueta Radiofy.app
  Info.plist      # versión (CFBundleShortVersionString)
```

Issues y PRs: bienvenidos, sobre todo si respetan el contrato local-first (no spamear la Web API en cada Cambiar).

## Licencia

Código abierto. Hecho en Chile.
