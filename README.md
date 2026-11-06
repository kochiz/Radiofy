# Radiofy

Radio digital en la barra de menú de macOS. Eliges una playlist de Spotify, pulsas **Cambiar**, y suena otra canción de esa lista. No es el botón “siguiente” de Spotify: sintoniza al azar dentro de la fuente que elegiste.

Versión actual: **3.5-MULTIVERSE**. Necesitas macOS 10.15+, Spotify Premium y Spotify abierto en el Mac.

## Para qué sirve

Si dejas música de fondo (laburo, cocina, junta) y te aburre pelear con la cola o con el shuffle, Radiofy te deja tratar Liked Songs o una playlist como una radio: cambias de tema con un clic y sigues.

Spotify sigue reproduciendo el audio. Radiofy solo lo controla desde un panel chico en la menubar (o en vista mini, siempre arriba).

## Controles

- **Cambiar**: otra canción de la playlist / Liked Songs activa.
- **Desde el inicio**: la pista actual vuelve a 0:00.
- **Mis radios**: tus playlists (con tapa) para elegir fuente.
- **Dial / MHz**: feedback visual de sintonía. No es FM de verdad.
- **Modo radio** (switch): ON = al terminar una canción, la siguiente puede entrar a mitad. OFF = la siguiente parte desde el inicio.
- **Logo**: panel completo o vista mini (tapa, título, MHz, Cambiar / Desde el inicio).
- **Sonando en…**: dispositivo de Spotify en este Mac.
- **i**: acerca de / versión.

## Cómo está hecho

App nativa en Objective-C. La UI del panel es HTML/CSS/JS en un WKWebView.

Cambiar intenta ir primero por **Spotify.app** (AppleScript) para no quemar la Web API en cada sintonía. La Web API (login PKCE) se usa para conectar la cuenta, listar playlists y armar pool cuando hace falta. Tokens y preferencias quedan en:

`~/Library/Application Support/Radio/`

Log: `~/Library/Application Support/Radio/radiofy.log`

## Compilar

```bash
cd radio
./build_mac.sh
open Radiofy.app
```

Para instalar:

```bash
cp -R Radiofy.app /Applications/
```

## Conectar Spotify

1. Crea una app en [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard).
2. Añade este Redirect URI tal cual (tiene que ser `127.0.0.1`, no `localhost`):

```text
http://127.0.0.1:29501/callback
```

3. Abre Radiofy, pega el Client ID y autoriza en el navegador.
4. macOS va a pedir permiso de Automatización (Radiofy controla Spotify). Sin eso el camino local no anda.

## Código

```text
radio/main.m       menubar, bridge, Spotify local + API
radio/ui/          panel
radio/build_mac.sh build del .app
radio/Info.plist   versión
```

## Licencia

Código abierto. Hecho en Chile.
