# Ghostty en Windows (port experimental)

Este árbol contiene un port nativo de Ghostty para Windows basado en un
apprt Win32 propio (`src/apprt/win32/`). El estado actual es **funcional
como terminal**: ventana nativa, renderizado OpenGL, ConPTY, teclado
(incluyendo AltGr, dead keys e IME para CJK), mouse, scroll, resize con
reflow, colores, título dinámico, portapapeles, señales de consola
(Ctrl+C), **tabs nativos** (ctrl+shift+t, ctrl+pgup/pgdn) y **splits**
(ctrl+shift+o/e, navegación con ctrl+alt+flechas).

## Compilar

Requisitos: [Zig 0.15.2](https://ziglang.org/download/) y nada más
(no se necesita Visual Studio ni el Windows SDK).

```sh
zig build -Dapp-runtime=win32 -Dtarget=native-native-gnu
./zig-out/bin/ghostty.exe
```

Notas:

- El ABI **GNU** (`-Dtarget=native-native-gnu`) es necesario porque Zig
  es autocontenido con MinGW; el ABI MSVC (el default en Windows)
  requiere el Windows SDK instalado.
- Los builds Debug usan el subsistema de consola para ver logs; los
  builds release (`--release=fast`) son aplicaciones GUI puras.
- La shell por defecto es `cmd.exe`. Puedes cambiarla en el archivo de
  configuración (`%LOCALAPPDATA%\ghostty\config.ghostty`), por ejemplo:
  `command = pwsh.exe`.

## Arquitectura del port

- `src/apprt/win32/` — runtime de aplicación Win32: message loop,
  contexto WGL (OpenGL 4.3 core), input de teclado/mouse, IME (imm32),
  portapapeles, DPI por monitor. `Window.zig` es la ventana top-level
  con la barra de tabs nativa (comctl32) y el árbol de splits; cada
  surface (`Surface.zig`) es una ventana hija WS_CHILD con su propio
  contexto GL.
- `src/renderer/OpenGL.zig` — ramas win32: el contexto GL se crea en el
  hilo principal, se libera en `finalizeSurfaceInit` y el hilo del
  renderer lo toma en `threadEnter`; dibuja y hace `SwapBuffers` por su
  cuenta (a diferencia de GTK, que dibuja en el hilo principal).
- `src/pty.zig` / `src/Command.zig` — ya traían soporte ConPTY completo
  (upstream); el IO corre sobre el backend IOCP de libxev.
- **win32-input-mode (modo 9001)** — `src/terminal/modes.zig` +
  `src/input/key_encode.zig`: cuando ConPTY lo solicita (lo hace al
  arrancar), cada evento de tecla se envía como un KEY_EVENT_RECORD
  Win32 exacto (`ESC [ Vk ; Sc ; Uc ; Kd ; Cs ; Rc _`), igual que
  Windows Terminal. Esto hace que Ctrl+C llegue como señal de consola
  real a los procesos (p. ej. interrumpir `ping -t`).

## Empaquetado

- **ZIP portable**: `./dist/windows/package.sh 1.3.2` (usa `ZIG=` si zig
  no está en PATH) → `zig-out/dist/ghostty-<ver>-windows-x86_64.zip`.
- **Instalador**: con Inno Setup instalado
  (`winget install JRSoftware.InnoSetup`):
  `ISCC.exe dist\windows\ghostty.iss` →
  `zig-out/dist/ghostty-<ver>-windows-x86_64-setup.exe`. Instala en
  ámbito usuario o máquina, crea entrada en el menú Inicio, icono de
  escritorio y PATH opcionales, y desinstalador.
- **winget**: manifiestos listos en `dist/windows/winget/`; ver su
  README para el proceso de publicación (requiere URL pública del
  instalador + SHA-256).

## Configuración

La config vive en `%LOCALAPPDATA%\ghostty\config.ghostty` y es el mismo
formato que en macOS/Linux. Notas específicas de Windows:

- `theme = light:...,dark:...` funciona: el tema claro/oscuro del
  sistema se detecta al arrancar y en vivo (Configuración → Colores).
- `background-opacity` aplica opacidad uniforme a la ventana (DWM no
  compone alpha por píxel de OpenGL de forma fiable, así que el texto
  también se atenúa ligeramente, a diferencia de macOS).
- `background-blur` activa el efecto acrylic detrás de la ventana (el
  radio numérico se trata como on/off).
- Las claves `macos-*` y `window-colorspace` se ignoran sin error.
- `window-save-state = always` guarda y restaura posición/tamaño de la
  ventana entre sesiones.
- `font-family` acepta tanto la familia ("JetBrainsMono NFM") como el
  nombre completo estilo macOS ("JetBrainsMono NFM Regular").
- Recarga de config: `ctrl+shift+,` o reiniciar.
- La franja vacía de la barra de tabs arrastra la ventana; doble clic
  en ella maximiza/restaura.

## Pendientes conocidos

- Arrastrar el divisor de splits con el mouse (hoy se redimensiona con
  `resize_split`/keybindings; `equalize_splits` también funciona).
- Reordenar tabs con drag & drop (`move_tab` no implementado).
- `close_tab` con modos "other"/"right" (solo "this" implementado).
- IME: implementado según el contrato IMM32 (preedit inline + ventana
  de candidatos junto al cursor), pero sin validar con un IME CJK real
  instalado en la máquina de desarrollo.
- i18n (gettext) deshabilitado en Windows.
