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
| `Instruments.swift` | Catálogo de bancos SF2/DLS e instrumentos, descargas a `Application Support/Chordy/Instruments`, `SamplerPlayer` (AVAudioUnitSampler) y `SoundOutput` (sinte o sampler, velocidad, pedal de sustain) |
| `InstrumentPanel.swift` | Selector de instrumento y bancos (descargar, cancelar, quitar, créditos) en la pestaña Sonido |
| `Keyboards.swift` | Teclados MIDI por separado (`KeyboardConfig`: aparato, canal, sonido, modo, zona, octava, curva, volumen, color), alta automática, aprender zona, `keyboards.json` |
| `StudioView.swift` | Ventana principal (Estudio): cabecera de transporte, tarjetas de teclado, «Lo que suena», mezcla, pestañas y hoja de ajustes de teclado |
| `DrumMachine.swift` / `DrumPanel.swift` | Caja de ritmos: patrones A–H (`drums.json`), reloj propio en un hilo (`DrumClock`, temporizador de 1 ms), sampler propio, grabación en directo; panel con la cuadrícula 8 × 16 |
| `LoopStudio.swift` | Editor de loops: rollo para mover, alargar, añadir y borrar; tono, tempo, largo, transponer, cuantizar, fuerza, instrumento, duplicar y efectos |
| `DeviceDrawing.swift` | Dibujo en vivo del Launchkey 25 MK2, del Yamaha PSR-E453 o de un teclado genérico, con lo que hace cada tecla, pad, knob y botón |
| `DrumView.swift` | Vista de batería a pantalla completa (Estudio | Batería, ⌘B): patrones con nombre, cuadrícula grande con fuerza por arrastre, volumen/M/S por pista, cadena, pads 4 × 4 y herramientas de pista |
| `RemoteProtocol.swift` | Protocolo compartido con Chordy Pads (iPad): estado, ticks y órdenes en JSON por líneas |
| `RemoteServer.swift` | Servidor Bonjour `_chordypads._tcp` (Network.framework): manda el estado al cambiar y el compás en cada paso, ejecuta las órdenes del iPad |
| `Transport.swift` | Reloj común (beat = anchorBeat + (t − anchorTime)·bpm/60): loops, batería y grabador se apuntan (`join`/`leave`), lo que arranca con algo sonando entra en el siguiente compás; `AudioClock` programa notas con su tiempo de muestra |
| `LiveFastPath.swift` | Vía rápida del MIDI: las teclas de un teclado en modo Notas con sonido real suenan desde el hilo de CoreMIDI; el hilo principal solo actualiza el estado |
| `SynthStudio.swift` | Vista «Sintetizador»: biblioteca (tuyos y de fábrica: nuevo, duplicar, renombrar, borrar), editor a dos columnas, teclado para probar y «Usar en un teclado» |
| `Song.swift` / `SongView.swift` | Canción: pistas (batería + loops), clips en compases que repiten su loop o patrón; reproductor sobre `Transport` (batería por `DrumMachine.playSong`, notas de loop programadas por delante); vista con biblioteca arrastrable, mover/alargar clips, silenciar pistas |
| `Projects.swift` | Proyectos `.chordy` (JSON con canción, loops, batería, tono/tempo, teclados y sonidos propios): nuevo, abrir, recientes, guardar (⌘S), guardar como (⇧⌘S), autoguardado cada 30 s si hay cambios (sin archivo: `Autoguardado.chordy` en Application Support) |
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
- **Teclas cromático vs. grados** (`keysChromatic`, por defecto cromático): en cromático cada tecla toca el acorde mayor de su nota real y a su altura real; el color (pads, WASD) lo cambia. Una nota fuera de la escala se guarda como grado + `accidental` (+1 semitono: en estas escalas no hay saltos mayores de un tono, `Music.root(ofPitchClass:)`), así que pantalla, loops (`LoopEvent.accidental`, opcional al leer) e ids (`user:<grado>:<octava>:<alteración>`) siguen funcionando por grados. En modo grados las negras son modificadores de color y no suenan solas: el usuario creyó que «no funcionaban los sostenidos».
- **Instrumentos reales**: `AVAudioUnitSampler` en el mismo `AVAudioEngine` del sinte (`Synth.attach`), directo al mezclador. Bancos: Salamander (CC BY 3.0, se descarga en .tar.xz de 310 MB y ocupa **1,27 GB** descomprimido; carga en <1 s, ~350 MB de RAM), Upright KW (CC0), GeneralUser GS (GM + kits en `bankMSB 120`), MuldjordKit (CC BY 4.0) y el DLS de macOS (`gs_instruments.dls`, sin descarga). `/usr/bin/tar` abre .7z y .tar.xz. Los créditos de las licencias van en «Bancos». Un mismo `midi` lo pueden pedir dos acordes: el sampler cuenta referencias y solo para la nota cuando la suelta el último.
- **Teclas: notas / cromático / grados** (`keysLayout`; `keysMode` alterna notas ⇄ último modo de acordes, en el redondo de arriba del Launchkey en el preset). La velocidad de la tecla llega al sonido (sinte: volumen 35–100 %). CC64 en el canal de teclas = sustain (`SoundOutput` retiene los note-off).
- **Loops con notas e instrumento**: las notas del modo Notas se graban como `LoopEvent` con `midi` y `velocity` (así recorte y desplazamiento valen para todo) y el loop guarda `instrument`. Cada instrumento en uso tiene su propio `SamplerPlayer` (`InstrumentLibrary.player(for:)`), así un loop de piano suena mientras tocas otro instrumento. El pedal de sustain no retiene notas de loops (`noteOff(pedal: false)`).
- **Teclados por separado**: cada nota se enruta por su aparato (nombre de la fuente CoreMIDI), canal y zona (`Keyboards.match`), así dos teclados en el canal 1 suenan cada uno con lo suyo. Notas y acordes llevan `owner` (id del teclado) para colorear y `instrument` por evento en los loops. Las fuentes nuevas que no son InControl ni «Chordy» se añaden solas (`adopt`); la del Launchkey hereda el modo y sonido de antes. Canal nil = todos menos el 10 (pads en modo básico).
- **Pads en modos de batería** (`DrumMachine.padMode`, redondo de abajo): Pasos = los 16 pads son los pasos de la pista elegida (◀ ▶ cambian pista), Tocar = arriba tambores, abajo patrones A–H; ▶ y ● del transporte pasan a la batería. Luces propias en `drumLights`.
- **`AppButtonStyle` tenía 14 px de margen lateral fijo**: un `IconButton` más estrecho desbordaba y se montaba sobre lo de al lado. Ahora `padding: 0` en los de icono.
- **Nunca cargar un banco en un sampler que suena**: `loadSoundBankInstrument` con el `AVAudioUnitSampler` conectado al motor y renderizando cuelga CoreAudio (EXC_BAD_ACCESS en el hilo de audio: pasó al tocar mientras un cambio de programa cambiaba el sonido). `SamplerPlayer` y la batería desconectan el nodo, cargan en segundo plano y lo vuelven a conectar; las notas mientras tanto son silencio.
- **Cambiar de sonido rápido**: 8 favoritos por tarjeta (clic; clic derecho cambia la casilla), y para el teclado tocado el último (`Keyboards.active`): ◀ ▶ del Launchkey, teclas 1–8 del Mac y cambio de programa MIDI (botones de voz del Yamaha).
- **Efectos por bus**: cada loop (`loop:<id>`) y cada teclado (`kb:<id>`) tiene su propio sampler por instrumento con filtro → eco → reverb → limitador. El bus viaja dentro de la cadena del instrumento (`SoundRoute`, «salamander@loop:…») para no tocar toda la fontanería; al grabar se quita. El sintetizador no pasa por ellos.
- **Estado en vivo para los dibujos**: `MidiController.liveNotes/liveValues/livePressed` por aparato, y `keyWindow` sigue los botones de octava del Launchkey (la ventana de 25 teclas salta de octava cuando llega una nota fuera).
- **Batería: el reloj toca «compases» ya mezclados** (`DrumClock.Bar`: volumen por pista aplicado, pistas en silencio vacías, nota GM por pista). La cadena es una lista de compases; `refreshClock()` los rehace en cada cambio (mute, solo, edición, cadena) sin parar el tempo.
- **Chordy Pads (iPad)** vive en `iPad/` (XcodeGen: `cd iPad && xcodegen generate`; comparte `Sources/Chordy/RemoteProtocol.swift`). Instalar en el iPad: `xcodebuild -project iPad/ChordyPads.xcodeproj -scheme ChordyPads -destination 'id=<UDID>' -allowProvisioningUpdates build` y `xcrun devicectl device install app --device <UDID> "<…>/Debug-iphoneos/Chordy Pads.app"` (equipo 3HWTS4AVPU). El iPad es solo mando: suena el Mac. La app del Mac declara `NSLocalNetworkUsageDescription` y `NSBonjourServices` en `build-app.sh`. Probar sin iPad: resolver el puerto con `dns-sd -L "<nombre del Mac>" _chordypads._tcp local.` y mandar líneas JSON con `nc` (`{"togglePlay":{}}`).
- **Protocolo iPad compatible hacia atrás**: los campos nuevos de `RemoteState` (teclados, sonidos, favoritos) son opcionales, así un iPad o Mac viejo sigue decodificando. Las notas en vivo (`.notes`) van en un `LiveKeys` aparte en el cliente para que solo redibujen los teclados, no toda la vista. El sintetizador también pasa por los efectos: cada bus (`kb:<id>`, `loop:<id>`) con efectos tiene su propia salida (`Synth.slot(for:effects:)`: nodo fuente → EQ → eco → reverb → `synthMixer` → compresor). Todos los nodos fuente renderizan en el mismo hilo de audio con la misma marca de tiempo; el primero de cada ciclo vacía la cola de órdenes.
- **Tipo de acorde fijo**: `ChordEngine.chordType` (cabecera «Acorde», guardado en `chordType`) es el color cuando no se mantiene W A S D ni un pad de color; los colores mantenidos mandan mientras se pulsan. En el editor, el lápiz pinta notas o acordes (`editorPaintChords`/`editorPaintColor`): la fila pulsada es la nota base y se convierte en grado + alteración + octava con `Music.root(ofPitchClass:)`; ↑ ↓ y arrastrar en vertical mueven también los acordes. Gancho: `chordtype:<raw>`, `synthslots:<archivo>`.
- **Clics de ratón en pruebas**: `scratchpad/click x y` (CGEvent) funciona sobre la ventana de Chordy; `winpos` da su marco (coordenadas de la captura = puntos de ventana, global = y + 30 de la barra).
- **Canción**: secciones (`SongData.sections`) y pista/clip con volumen, solo y transporte opcionales; `songsections` en el gancho de depuración crea dos secciones de prueba. La línea de tiempo llena el ancho visible (GeometryReader), no solo `lengthBars + 8`.
- **Saturación**: un golpe de kit completo (bombo + caja + crash + charles a 127) llegaba a +0,9 dBFS y distorsionaba. Hay limitador en la batería y otro general entre el mezclador y la salida (`Synth.start`, −2 dB de pregain). Las notas al sampler de la batería salen siempre desde la cola del reloj (un solo hilo).
- **`TimelineView` + `.id(timeline.date)` re-maqueta toda la ventana cada fotograma**: el Canvas ya se redibuja solo dentro del `TimelineView`. Con el `.id` Chordy gastaba un 44 % de CPU en reposo y el hilo principal (MIDI, reproductor de loops) iba tarde: notas y loops con temblor. Ahora 3,5 %, y la vista se pausa (`paused:`) cuando no suena nada.
- **Latencia**: el `PeakLimiter` de Apple retrasa la señal su tiempo de ataque (12 ms por defecto) y en serie se suman; todos se crean con `Synth.limiter()` (1 ms). El motor pide un búfer de 128 muestras a la salida (`lowerLatency`). Una salida Bluetooth añade 150–250 ms que ninguna app puede quitar: para tocar, salida por cable o la del Yamaha por USB.
- **Observar poco**: una vista con `@ObservedObject engine/midi/drums` se reconstruye en cada nota o cada paso de la batería. Las tarjetas de teclado (con menús de 35 instrumentos) y la cabecera lo hacían en cada nota: retraso visible en los teclados dibujados. Ahora el estado en vivo va aparte (`MidiController.live: LiveMIDI`, `devices: DeviceList`), la cabecera son piezas pequeñas que observan solo lo suyo, y el dibujo del Yamaha no observa la batería. Perfilar: `swift build -c release -Xswiftc -DDEBUG --build-path .build-perf` (optimizado con gancho), notas con `mididev:` y `sample <pid> 3`.
- **Sincronía y calidad (auditoría con agentes, 15-11-2026)**: los loops iban con un `Timer` de 5 ms en el hilo principal (p95 22 ms tarde con la interfaz ocupada) y cada uno con su reloj; ahora todo cuelga de `Transport`, las notas se programan 25–60 ms por delante con su tiempo exacto (`scheduleMIDIEventBlock`, error 0 muestras) y el MIDI en vivo de los teclados en modo Notas suena desde el hilo de CoreMIDI. Niveles: samplers −6 dB (`SamplerPlayer.headroomDB`), sin limitador por sampler, solo el general sin pregain; el volumen de teclado y loops es ganancia, no fuerza; los loops guardan la fuerza de los acordes; la batería graba la fuerza que se oye; los platos suenan 2,5 s. Las notas inyectadas por el gancho llevan `time: now()` (con 0 el grabador se descuadraba).
- **Grabar lo que se toca**: por defecto la toma no se cuantiza (paso fino de 1/96 de tiempo; se puede elegir 1/16 o 1/8 en la barra de grabar, y cuantizar después en el editor). El largo son compases desde donde se pulsa parar, pero nunca menos que la última nota. Notas y acordes llevan la hora de llegada del MIDI. Probar con `testkeys` (fuente virtual con ritmo exacto) en vez de `mididev:`, que lanza un proceso por nota y desfasa.
- **Cargar bancos de uno en uno** (`SamplerPlayer.loadQueue`): varios `loadSoundBankInstrument` a la vez en samplers distintos cuelgan AUSampler (CAVerboseAbort en `AudioUnitSetProperty`).
- **Sonidos de sintetizador por teclado**: el instrumento puede ser `synth` (el sonido que se edita) o `synth:<patch id>` (`InstrumentLibrary.isSynth/synthPatchId/synth(_:)`); `SoundLibrary.patch(for:)` devuelve el borrador si es el seleccionado, así los teclados que lo usan oyen la edición en directo. Las voces del sinte llevan el hash del `Patch.id` y `updateLive` solo toca las de ese sonido.
- **Editor de loops como modo** (`mainMode = editor`, `Loops.studioId`): ventana propia con monitores locales de teclado y rueda que solo viven mientras está abierto; `KeyboardInput` se calla en ese modo para que espacio, flechas y borrar sean del editor. A–B = el borrador recortado a la región, reproducido con el id del loop (mismo bus de efectos).
- **⌘S es del proyecto**: el editor de loops y el sintetizador tienen su botón «Guardar» sin atajo (dos atajos iguales en la misma ventana no se sabe cuál gana). Borrar un loop pide confirmación y quita sus clips de la canción.
- **Realimentación MIDI entre dos Chordy**: la instalada y la de debug publican cada una una fuente virtual «Chordy» y cada una escuchaba la de la otra → bucle infinito de notas que disparó «grabar loop» cientos de veces y llenó `loops.json` (25 MB, 600 loops) en un minuto. `MidiIO.isChordyOutput` descarta cualquier fuente virtual llamada como la app. Antes de probar con la de debug, cerrar la instalada si su versión no lleva este arreglo.

## Pruebas manuales

- **Gancho de depuración** (solo debug): `.build/debug/Chordy` y `DistributedNotificationCenter` `com.egluu.chordy.debug` con objeto `main`, `settings`, `theme:<id>`, `shot:<carpeta>`, `press:<1-7>`, `release:<1-7>`, `dir:<dirección|none>`, `octave:<0|1>`, `sound:<id>`, `stop`, `midi:<status>,<d1>,<d2>` (simula un mensaje MIDI), `tab:<loops|chords|sound|midi>`, `mididev:<aparato>|s,d1,d2` (MIDI como si viniera de ese aparato), `layout:<notes|chromatic|degrees>`, `instrument:<id>`, `download:<pack>`, `state:<archivo>`, `drums`, `pads:<chords|steps|play>`, `configure:<n|none>`, `devices` (dibujo de los aparatos en las tarjetas), `editloop` (abre el editor del primer loop), `mode:<studio|song|drums|synth|editor>`, `songdemo`, `songplay`, `map:<launchkey|keys|guided|clear>`. Añadir ahí los comandos que haga falta para llevar la app a cada estado sin ratón.
- **Capturas sin permisos**: el comando `shot:<carpeta>` del gancho guarda un PNG de cada ventana visible de la app (`cacheDisplay`). Es lo primero a usar: `screencapture -l` falla con «could not create image from window» si Terminal no tiene grabación de pantalla.
- **El sandbox de Bash** aísla el portapapeles y otras apps (`pbcopy`, `screencapture`, Chrome headless): esas pruebas, fuera del sandbox.
- **Capturas** (con permiso de grabación de pantalla): `screencapture -x -l <id de ventana>` saca solo la ventana, sin el escritorio. Los ids, con `CGWindowListCopyWindowInfo` filtrando por propietario `Chordy`.
- El binario de debug usa el dominio de `UserDefaults` `Chordy`, no `com.egluu.chordy`, pero comparte `~/Library/Application Support/Chordy`: hacer copia antes de probar y restaurarla después.

## Ideas para después

- Overdub en loops (grabar capas encima de un loop que suena).
- Inversiones automáticas (encadenar cada acorde con la inversión más cercana al anterior).
- Exportar un loop a `.mid` o audio.
- Arpegiador al tempo.
