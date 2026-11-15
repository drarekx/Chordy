# Chordy

Toca progresiones de acordes con el teclado del Mac o tu controlador MIDI. App nativa de macOS con ventana e icono en el Dock. Swift + AppKit/SwiftUI, sin dependencias en el código. Repo: https://github.com/drarekx/Chordy (constante `AppInfo.repo` en `AppDelegate.swift`, también en `install.sh` y README).

Creada con la skill `crear-app-mac`: misma estructura, instalador, actualizador, temas, idiomas y menú que Wallpy, DemoImages y Droppy.

## Compilar y ejecutar

```sh
swift build                      # debug, comprobación rápida
./build-app.sh                   # release → build/Chordy.app + build/Chordy.zip (universal con Xcode; nativo con solo CLT)
VERSION=1.2.0 ./build-app.sh     # versión en Info.plist (por defecto 1.0.0)
open build/Chordy.app
.build/debug/Chordy -appLanguage ca   # probar otro idioma sin tocar los ajustes
```

- Requisitos: macOS 14+. `Package.swift` usa tools 5.10 (modo Swift 5).
- No hay tests. Verificar compilando y lanzando la app (y con capturas, ver «Pruebas manuales»).
- La copia instalada vive en `/Applications/Chordy.app`; la de `build/` es de desarrollo y tiene versión 1.0.0, así que su actualizador siempre ve versiones nuevas.

## Publicar una versión

```sh
git tag v1.0.1 && git push origin v1.0.1
```

`.github/workflows/release.yml` (macos-15) compila con `VERSION` = tag y crea el release con `Chordy.zip` y `Chordy.zip.sha256`. `Updater.swift` consulta `releases/latest`, verifica el SHA-256 y el `Info.plist` y cambia el bundle. `build.yml` compila arm64 + x86_64 y verifica que `en` y `ca` tienen las mismas claves y que todo `tr()` está traducido. La app no está notarizada (firma ad-hoc). Commits con la skill `commit:commit`.

## Estructura (`Sources/Chordy/`)

| Archivo | Qué hace |
|---|---|
| `main.swift`, `AppDelegate.swift` | Arranque, `AppInfo` (nombre, repo, Buy Me a Coffee, `menuBarApp`), icono y menú de la barra de menús, ventanas (principal y Ajustes), menú principal, gancho de depuración |
| `MainView.swift` | Ventana principal: zona de tocar (`PlayArea`) + panel lateral (Sonido, MIDI) |
| `PlayViews.swift` | Cabecera, historial de acordes (Canvas + TimelineView), modo/BPM, rueda de colores, pads de grado |
| `Music.swift` | Teoría: notas, modos, grados, colores, direcciones WASD, símbolos y notas MIDI de cada acorde |
| `Patch.swift` | Modelo de sonido (`Patch`), rangos de parámetros y los 14 sonidos de fábrica |
| `Synth.swift` | Sintetizador en `AVAudioSourceNode`: 3 osciladores (PolyBLEP + tabla de armónicos), biquad RBJ con envolvente, ADSR, vibrato, compresor (DynamicsProcessor). El hilo principal solo encola comandos |
| `ChordEngine.swift` | Estado musical (tono, modo, color, octava, BPM, acordes sonando, historial) y arranque/parada de acordes |
| `SoundPanel.swift` | Editor de sonido: presets (guardar, guardar como, deshacer, borrar), forma de onda, 3 osciladores, armónicos, filtro, envolvente, vibrato, volumen. `ParamSlider` con escala logarítmica |
| `SoundLibrary.swift` | Sonidos de fábrica + propios (`sounds.json`), seleccionado y borrador en edición |
| `KeyboardInput.swift` | Teclado del Mac (monitor local, sin permisos) |
| `MidiIO.swift` | CoreMIDI: escucha todas las fuentes (hot-plug), fuente virtual «Chordy», envío a dispositivos |
| `MidiMapping.swift` | Controles, acciones mapeables y presets (Teclas, Launchkey 25 MK2) |
| `MidiController.swift` | Learn, guiado, automapeo, despacho de acciones, salida de acordes, luces del Launchkey (InControl) |
| `MidiPanel.swift` | Panel MIDI |
| `Loops.swift` | Modelo de loop, cuantizar/recortar/rotar (`LoopMath`), grabadora con metrónomo, reproductor (sigue tono/BPM en vivo), `loops.json` |
| `LoopPanel.swift` | Panel de loops: grabar, lista, renombrar (doble clic), vista previa, editor de recorte y desplazamiento |
| `AppModel.swift` | Une motor, sonidos, teclado, MIDI y loops; reparte los atajos (R, P, Esc) al teclado y al MIDI |
| `SettingsPane.swift` | Ajustes: colores, abrir al iniciar sesión, idioma, actualizaciones, invitar a un café |
| `Settings.swift` | `UserDefaults` (`com.egluu.chordy`), `LoginItem` (`SMAppService`) |
| `Theme.swift` | Colores (sacados del tema elegido) y controles comunes: `AppButtonStyle`, `IconButton`, `SegmentedControl`, `SectionLabel`, `AppTextField`, `SwitchRow`, `appCard` |
| `Themes.swift` | `AppTheme` (Original, Solarized, Dracula, Nord, Gruvbox, Monokai, One Dark, Tokyo Night, Catppuccin, Rosé Pine, Everforest, Kanagawa, GitHub Dark), `ThemedRoot`, `ThemeSwatch` |
| `Updater.swift` | Autoactualización desde GitHub Releases con SHA-256 |
| `Localization.swift` | Idiomas (en, es, ca): `tr()`, `Localizer`, tablas |
| `Icon/AppIcon.html` | Fuente del icono. `scripts/make-icon.sh` lo renderiza con Chrome headless y genera `Resources/AppIcon.icns` (versionado) e `Icon/AppIcon-1024.png` |

## Convenciones

- Código, comentarios y commits en inglés. Interfaz en castellano, inglés y catalán.
- **Todo texto visible pasa por `tr("…")`** (o `tr("… %@ …", arg)`). La clave es el texto en castellano; añadir la traducción a `en` y `ca` en `Localization.swift` con los mismos `%@`/`%d`. Nunca interpolar dentro de un texto traducible. Los nombres propios (temas, formatos) no se traducen.
- Estilo: usar `Theme` y sus componentes, nunca colores sueltos. Toda ventana nueva va dentro de `ThemedRoot { … }` (sigue el tema y el idioma).
- Estado de UI en tipos `@MainActor`; trabajo pesado (archivos, procesos) fuera del hilo principal.
- Borrar archivos del usuario = papelera (`trashItem`/`recycle`), nunca `removeItem`.
- El menú de la barra (o el de la app) mantiene siempre: Ajustes…, Buscar actualizaciones…, Invítame a un café… (`cup.and.saucer`), versión y Salir.
- Mantener el README al día (con capturas en `docs/`) cuando cambian funciones visibles.

## Cosas que ya costaron (no repetir)

- **`NSHostingController`/`NSHostingView` redimensionan la ventana**: `sizingOptions = []`, `setContentSize` y después `setFrameAutosaveName`. En paneles hechos a mano, el `NSHostingView` con autoresizing y **sin Auto Layout**: con restricciones, `_changeWindowFrameFromConstraintsIfNecessary` impone el tamaño mínimo de SwiftUI.
- Nunca `setFrame(…, animate: true)` con SwiftUI dentro: da saltos. Cambiar el marco de golpe y animar el contenido.
- **`@Published` avisa en `willSet`**: un sink que redimensiona o repinta ahí ve el valor viejo y la vista se queda desfasada. Hacerlo en `DispatchQueue.main.async` o con `.receive(on: RunLoop.main)`.
- **Sin menú principal no funcionan ⌘C/⌘V/⌘A** en campos de texto de una app de barra de menús: `setupMainMenu()` lo crea aunque no se vea.
- Los `NSPanel` se esconden al desactivarse la app (`hidesOnDeactivate = false` si deben quedarse); un panel `.nonactivatingPanel` necesita `canBecomeKey` para escribir en él y `makeKey()` antes de enfocar un campo.
- Monitores globales: `NSEvent.addGlobalMonitorForEvents` de ratón no pide permisos; de teclado pide Accesibilidad. Atajos globales sin permisos: Carbon `RegisterEventHotKey`. ⌥⌘D está cogido (Dock).
- **Instalador con `curl | bash`**: con `set -u` y locale C, `"$NAME…"` hace que bash lea los bytes de «…» como parte del nombre → `unbound variable`. Usar siempre `${NAME}` pegado a texto no ASCII.
- **Abrir al iniciar sesión**: solo desde la copia de Aplicaciones (`LoginItem.enableOnceFromApplications`); desde `build/` registraría la de desarrollo. `open build/Chordy.app --args -unregisterLoginItem YES` lo quita.
- La app no está notarizada (firma ad-hoc): los permisos de privacidad (Descargas, Accesibilidad…) pueden volver a pedirse tras cada actualización.
- Builds universales (`--arch arm64 --arch x86_64`) necesitan Xcode completo; `build-app.sh` cae a la arquitectura nativa con solo CLT.
- **Runners de GitHub**: `macos-14` ya no existe. En `macos-15` el job puede quedarse en cola; relanzar con `gh run rerun <id>`.
- `main.swift` envuelve el arranque en `MainActor.assumeIsolated` porque `AppDelegate` es `@MainActor`.

- **Estado compartido entre entradas**: teclado del Mac, ratón y MIDI mueven las mismas direcciones/octava del `ChordEngine`. Al perder el foco, `KeyboardInput` solo suelta lo que pulsó él (si suelta todo, se cargaba los pads de color del MIDI, que deben seguir funcionando en segundo plano).
- **CoreMIDI**: la fuente virtual propia aparece entre las fuentes; excluirla al conectar (bucle). El refCon de `MIDIPortConnectSource` lleva el `uniqueID` para saber qué aparato envía. `kMIDIPropertyDisplayName` se libera con `takeRetainedValue`.
- **Launchkey 25 MK2**: puertos «Launchkey MK2 25 Launchkey MIDI» (teclas, pads canal 10 en modo básico) y «… InControl» (InControl: pads 96–103/112–119 canal 1, redondos 104/120, color = velocidad). Entrar en InControl: nota 12 vel 127 canal 1 al puerto InControl; salir con vel 0 (al cerrar la app). La zona de Teclas solo cubre notas 0–95 para no pisar los pads InControl, que también van por el canal 1.
- **Teclas = zona, no mapeos por nota**: el automapeo «Teclas» guarda solo el canal (`keysChannel`) y cada nota toca su grado **en su octava** (C4 = registro normal, `MidiPresets.octave(ofNote:)`). Así suenan las dos octavas de un teclado de 25 y los botones de octava del aparato (que transponen dentro del teclado, sin mandar MIDI) suben o bajan el acorde. Un mapeo explícito de una nota gana a la zona. La v1.0.0 guardaba 96 mapeos por nota sin octava: `migrateKeysPreset()` los convierte al cargar. Los acordes llevan octava (`HeldChord`, ids `user:<grado>:<octava>`) y los loops la guardan (`LoopEvent.octave`, opcional al leer).

## Pruebas manuales

- **Gancho de depuración** (solo debug): `.build/debug/Chordy` y `DistributedNotificationCenter` `com.egluu.chordy.debug` con objeto `main`, `settings`, `theme:<id>`, `shot:<carpeta>`, `press:<1-7>`, `release:<1-7>`, `dir:<dirección|none>`, `octave:<0|1>`, `sound:<id>`, `stop`, `midi:<status>,<d1>,<d2>` (simula un mensaje MIDI), `tab:<sound|midi>`, `map:<launchkey|keys|guided|clear>`. Añadir ahí los comandos que haga falta para llevar la app a cada estado sin ratón.
- **Capturas sin permisos**: el comando `shot:<carpeta>` del gancho guarda un PNG de cada ventana visible de la app (`cacheDisplay`). Es lo primero a usar: `screencapture -l` falla con «could not create image from window» si Terminal no tiene grabación de pantalla.
- **El sandbox de Bash** aísla el portapapeles y otras apps (`pbcopy`, `screencapture`, Chrome headless): esas pruebas, fuera del sandbox.
- **Capturas** (con permiso de grabación de pantalla): `screencapture -x -l <id de ventana>` saca solo la ventana, sin el escritorio. Los ids, con `CGWindowListCopyWindowInfo` filtrando por propietario `Chordy`.
- El binario de debug usa el dominio de `UserDefaults` `Chordy`, no `com.egluu.chordy`, pero comparte `~/Library/Application Support/Chordy`: hacer copia antes de probar y restaurarla después.

## Ideas para después

- Overdub en loops (grabar capas encima de un loop que suena).
- Inversiones automáticas (encadenar cada acorde con la inversión más cercana al anterior).
- Exportar un loop a `.mid` o audio.
- Arpegiador al tempo.
