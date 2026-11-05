# Radiofy

Radio digital para la barra de menú de macOS. Sintoniza Liked Songs o tus playlists y deja que el vibe elija el momento.

**Requisito:** Spotify Premium · macOS 10.15+

## Qué es

App nativa (Objective-C) con UI en HTML/CSS/JS dentro de un `WKWebView`.

- **Spotify.app primero** (AppleScript / osascript) para Cambiar sin gastar cuota de la Web API
- **Web API** para login (PKCE), playlists y fallback
- Skins: On Air, Neon, Classic, Vinyl, Studio

## Build

```bash
cd radio
./build_mac.sh
open Radiofy.app
```

## Uso

1. Abre Radiofy desde la barra de menú
2. Conecta con tu Client ID de [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
3. Redirect URI: `http://127.0.0.1:29501/callback`
4. Pulsa **Cambiar** para sintonizar otra canción

**Modo radio:** al terminar una canción, ON entra a mitad · OFF parte desde el inicio.

## Privacidad

Tokens y estado: `~/Library/Application Support/Radio/`  
Log: `~/Library/Application Support/Radio/radiofy.log`

## Licencia

Código abierto. Hecho en Chile.
