# Tanuki Flutter

Port Flutter de la shell Android TV nativa de Tanuki para Android, Windows y Linux.

Version actual: `0.8.11`.

## Que mantiene de la app Android

- Estetica TV oscura con rail lateral colapsado, hero, shelf de tendencias, detalle de serie en dos columnas, tarjetas de serie, chips de fuente y player full screen.
- Assets nativos `tanuki_*` reutilizados desde `android-tv-shell`.
- Biblioteca local por carpetas y escaneo recursivo de episodios.
- Playlist con series seleccionadas, progreso por serie, cola de proximos episodios y panel tipo Android con `Siguiente en la lista`/`Animes agregados`.
- Accion `Random` del rail como Android: intenta abrir un anime aleatorio de Jikan y usa catalogo/biblioteca local como fallback.
- Reanudacion de episodios con posicion/duracion persistida y completado automatico al 95%.
- Mi espacio con secciones horizontales tipo Android para `Favoritos`, `Quiero ver`, `Viendo`, `Abandonadas` y `Completadas`.
- Ajustes con fuente remota preferida persistida, tarjetas `Luego/Mas tarde`, saltos automaticos, conexion/sync MAL/SIMKL compatible en JSON y resumen local.
- MyAnimeList con OAuth PKCE desde Ajustes, retorno manual multiplataforma, deep link Android `toonamitvshell://mal-auth/callback`, refresh de token, push de estado/progreso/favoritos con tags, pull remoto hacia `Mi espacio`/biblioteca y mappings persistidos.
- Conexion SIMKL por PIN multiplataforma desde Ajustes, con Client ID editable, polling, cuenta por perfil, pull de listas remotas hacia `Mi espacio`/biblioteca, pull de progreso remoto por episodio, push basico de estado/progreso local y scrobble `start`/`pause`/`stop` desde el reproductor.
- Panel `Similares` desde el detalle, con recomendaciones Jikan por catalogo y fallback a busqueda remota.
- Trailers desde detalle, tendencias y resultados de busqueda: Jikan conserva `trailerUrl`, las series importadas lo persisten y Flutter abre una cola multiplataforma con controles anterior/siguiente usando el navegador o app externa del sistema.
- Selector y administracion de perfiles desde el rail, con crear, renombrar, avatar, perfil predeterminado, borrado, estado/listas/progreso separados por perfil y migracion desde el perfil unico anterior.
- Metadata de relleno desde AnimeFillerList con cache local, chips `canon`/`mixed`/`filler` y ajustes `Saltar relleno`/`Saltar mixtos` aplicados a playlist y reproduccion.
- Busqueda remota via catalogo Jikan, AnimeAV1, JKAnime y LatAnime con grilla de posters tipo Android TV y filtros funcionales de tipo, temporada y ano como la app Android.
- Fichas de catalogo enriquecidas con Jikan para cast y metadata basica por episodio, y opcionalmente con TMDB/Fanart para poster, fondo, logo, descripcion, rating, trailer y metadata visual cuando hay claves configuradas.
- Importacion AnimeAV1 con episodios reales desde la pagina de la serie.
- Importacion JKAnime y LatAnime con episodios reales cuando la pagina del proveedor expone el listado.
- Resolucion directa AnimeAV1 a HLS `player.zilla-networks.com/m3u8/...` para modos SUB/DUB cuando estan disponibles, incluyendo el payload Svelte actual `embeds:{SUB/DUB:[...]}` usado por paginas como Hunter x Hunter y el `iframe` Zilla visible usado por paginas como Rurouni Kenshin.
- Resolver HTTP para paginas/iframes remotos que exponen URLs directas HLS/DASH/MP4 sin WebView, incluyendo iframes `jkplayer` y payloads `var servers` de JKAnime con metadata real de servidor, orden automatico de hosts tipo Android, fallback directo de URL JKAnime cuando la busqueda no devuelve candidato, fallback por servidor cuando un host ya resuelto falla en reproduccion, endpoints `ajax/api/player` llamados desde HTML, asignados a variables JavaScript simples o armados por concatenacion JS con literales/variables string, payloads de texto plano con hosts/medios sin comillas, scripts JavaScript empacados tipo Dean Edwards, URLs armadas por concatenacion JS, hosts UpCloud/Vidstream/Megacloud/Vidoza/SBPlay, conversion Zilla `play` a HLS `m3u8`, `data-player` y wrappers `reproductor?url=` de LatAnime con etiqueta visible de servidor, priorizados sobre enlaces de descarga vencidos con fallback por servidor, `botlink`/`robotlink` de Streamtape, claves de player `manifest`/`playlist`/`playback_url`, Facebook `playable_url*`/`browser_native_*`, hosts codificados en base64, Doodstream `pass_md5` y endpoints de descarga reproducibles.
- Extraccion de subtitulos remotos VTT/SRT/ASS/TTML desde `<track>` y payloads `tracks`/`captions`/`subtitles` de hosts compatibles, cargados en el reproductor con el mismo control `SUB`/`OFF` y seleccion de pista en ajustes.
- Episodios de catalogo pueden resolver dinamicamente AnimeAV1, JKAnime o LatAnime segun la fuente preferida/automatica, sin exigir importar antes esa misma serie desde el proveedor.
- Reproductor con `media_kit` embebido en Android y Windows para archivos locales y URLs directas HLS/DASH/MP4.
- Si el resolver remoto no encuentra una URL directa en un proveedor activo, el player marca esa fuente como fallida y prueba otra fuente automatica antes de quedar en `Resolver remoto pendiente`. Ya no abre paginas HTML remotas con `media_kit`, porque la app Android antigua resolvia esos casos con WebView oculto y probes JavaScript. Para catalogo o fuentes fuera de alcance queda directamente pendiente. Si una fuente directa falla al abrir o durante reproduccion, prueba otra fuente automatica para el mismo episodio sin cambiar la preferencia guardada.
- Overlay del reproductor con controles tipo Android para `SUB`/`OFF`, seleccion de pista remota en ajustes, modo de vista `FIT`/`STR`, ajustes rapidos, fuente/modo/servidor remotos y preferencia de escala de video persistida por serie.
- La fuente preferida global puede usar modo automatico o forzar AnimeAV1, JKAnime o LatAnime. Facebook queda limitado a entradas Facebook directas o equivalentes ya guardadas porque el lookup WebView de Android no esta portado a Flutter. AnimeKai y AnimeFLV quedan fuera del flujo Flutter actual. AnimeFLV tampoco participa en busqueda agregada, importacion activa ni fallback automatico, aunque el parser legacy se conserva para compatibilidad de datos. AnimeAV1 respeta `SUB`/`DUB` y JKAnime prioriza el servidor guardado al resolver hosts HTTP por encima del orden automatico Android, incluyendo aliases como `sw`, `sfastwish`, `flaswish` y dominios familia `*wish` para StreamWish.
- AnimeAV1/Zilla tiene watchdog de video similar al Android antiguo: solo cambia de fuente si el HLS ya avanzo reproduccion real sin dimensiones de video, para evitar saltos prematuros mientras Zilla inicializa.
- En Linux el build detecta `mpv`/`epoxy`: si estan disponibles usa video embebido; si no, compila igual y el player abre el medio con el reproductor predeterminado del sistema.

## Pendiente respecto a la app Android

La app Android nativa tiene resolvers WebView especificos para AnimeKai, JKAnime, LatAnime, AnimeFLV y Facebook dentro de `PlayerActivity.kt`. AnimeKai y AnimeFLV quedan excluidos del flujo Flutter por decision de alcance actual. En Flutter ya estan portadas la busqueda e importacion HTML de JKAnime y LatAnime, hay resolucion dinamica de episodios de catalogo hacia proveedores activos, y hay resolucion HTTP directa para fuentes que publican HLS/DASH/MP4 en HTML, iframes, payloads de proveedor con etiquetas de servidor JKAnime/LatAnime, endpoints XHR detectables, payloads de texto plano, wrappers con query base64, campos base64, claves comunes de player, scripts JavaScript empacados, URLs concatenadas por JS, hosts comunes del resolver Android, enlaces Zilla `play`, enlaces especiales de Streamtape, Doodstream `pass_md5` o endpoints de descarga directa. El codigo legacy de AnimeFLV se conserva para compatibilidad de datos/pruebas, pero no aparece en busqueda agregada, preferencias, importacion activa ni fallback automatico. Facebook detecta URLs progresivas/HLS/DASH expuestas en HTML o JSON de pagina cuando la entrada ya apunta a Facebook; el lookup WebView de Facebook de Android no esta portado a Flutter y no se ofrece como fuente preferida global. Los flujos que dependen de automatizacion WebView completa todavia no estan portados a Dart. AnimeAV1 ya esta portado por ruta directa HLS. Cuando una entrada remota de proveedor activo no entrega una URL directa, Flutter prueba otra fuente automatica antes de quedar en `Resolver remoto pendiente`; catalogo y fuentes fuera de alcance quedan pendientes sin abrir paginas no reproducibles. Cuando una fuente directa falla, Flutter intenta otro proveedor disponible; para AnimeAV1/Zilla evita cambiar de fuente hasta confirmar avance de reproduccion sin frames de video.

MAL ya tiene estado, mappings, configuracion visible en ajustes, OAuth PKCE externo, retorno manual para Windows/Linux, deep link Android preparado, persistencia compatible con el JSON de la app y sincronizacion basica contra su API. SIMKL ya conecta por PIN, trae listas remotas al perfil, importa progreso remoto por episodio hacia `episodePlayback`, empuja estado/progreso local basico y envia scrobble durante la reproduccion. Jikan ya aporta cast/metadata por episodio para catalogo, y TMDB/Fanart enriquecen visuales cuando existen claves.

## Primer arranque

Desde esta carpeta:

```sh
flutter pub get
```

Las carpetas `android/`, `windows/` y `linux/` ya estan incluidas. Si necesitas regenerarlas por algun motivo:

```sh
flutter create --platforms=android,windows,linux .
```

## Generar dist

Ejecuta los scripts siempre desde la carpeta Flutter, no desde `android-tv-shell`:

```sh
cd /ruta/a/Tanuki
flutter pub get
```

Las advertencias de `flutter pub get` sobre paquetes con versiones nuevas no bloquean el build; solo indican que existen updates fuera de los constraints actuales.

Si `flutter` no esta en tu `PATH`, puedes usar:

```sh
export FLUTTER_BIN="$HOME/.codex/sdks/flutter/bin/flutter"
```

### Chequeo rapido antes del dist

Antes de esperar un build completo, puedes validar configuracion Android/Linux sin generar APK ni paquete Linux:

```sh
sh scripts/check_build_config.sh
```

Para revisar solo Android:

```sh
sh scripts/check_build_config.sh --skip-linux
```

Para revisar solo Linux:

```sh
sh scripts/check_build_config.sh --skip-android
```

Este script corre `flutter pub get`, configura Gradle en una copia temporal para evitar problemas de permisos con `android/gradlew`, ejecuta `:app:assembleRelease --dry-run` y configura CMake Linux. Si esto pasa, recien ahi conviene lanzar el build real.

### Obligatorio para releases CI: TMDB/Fanart/MAL/SIMKL

Los releases de GitHub Actions validan estas claves antes de compilar. Si falta alguna, el workflow falla para evitar publicar builds sin metadata visual/sync:

```sh
TMDB_API_KEY
# o, alternativamente:
TMDB_BEARER_TOKEN
FANART_API_KEY
MYANIMELIST_CLIENT_ID
SIMKL_CLIENT_ID
```

`MYANIMELIST_CLIENT_SECRET` tambien se pasa al build si existe, pero no se exige porque el flujo actual usa OAuth PKCE y puede funcionar solo con Client ID.

Para cargarlas en GitHub:

```sh
gh secret set TMDB_API_KEY
gh secret set TMDB_BEARER_TOKEN
gh secret set FANART_API_KEY
gh secret set MYANIMELIST_CLIENT_ID
gh secret set SIMKL_CLIENT_ID
gh secret set MYANIMELIST_CLIENT_SECRET
```

Si tienes `lib/src/local_secrets.dart` en tu maquina, copia desde ahi los valores a GitHub Secrets. Ese archivo esta en `.gitignore` y no debe subirse al repositorio.

Los scripts `scripts/build_android.sh`, `scripts/build_linux.sh` y `scripts/build_windows.ps1` pasan esas variables automaticamente como `--dart-define`. Primero leen variables de entorno y, si no existen, usan `lib/src/local_secrets.dart`.

Para correr local con las mismas claves, usa el wrapper:

```sh
sh scripts/flutter_with_secrets.sh run -d linux
sh scripts/flutter_with_secrets.sh run -d d28624c3
```

Si usas `flutter run ...` o `flutter build ...` directo, Flutter no lee `local_secrets.dart`; en ese caso agrega manualmente los `--dart-define`.

### Android + Linux

Genera el APK de Android y el paquete Linux en `dist/` con un solo comando:

```sh
sh scripts/build_release.sh
```

Salidas esperadas:

- `dist/tanuki-android-release.apk`
- `dist/tanuki-linux-x64-release.tar.gz`

### Solo Android

Para probar primero el APK sin compilar Linux:

```sh
sh scripts/build_release.sh --skip-linux
```

Salida:

- `dist/tanuki-android-release.apk`

### Solo Linux

Para generar solo el paquete Linux:

```sh
sh scripts/build_release.sh --skip-android
```

Salida:

- `dist/tanuki-linux-x64-release.tar.gz`

### Windows

Windows debe compilarse en Windows, desde PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_release_windows.ps1
```

Salida:

- `dist\tanuki-windows-x64-release.zip`

El `.zip` de Windows incluye `Tanuki.exe` junto a las DLLs y assets necesarios.

### Notas Android

En algunos volumenes Linux el archivo `android/gradlew` no conserva permiso ejecutable. El script `scripts/build_android.sh` ya maneja ese caso copiando el proyecto a `~/.codex/build-work/tanuki_android_build`, aplicando `chmod +x` y copiando el APK final de vuelta a `build/app/outputs/flutter-apk/`.

El archivo `android/local.properties` contiene rutas locales de Flutter y Android SDK. Los scripts Android lo regeneran dentro de la copia temporal usando `FLUTTER_BIN`, `ANDROID_HOME`/`ANDROID_SDK_ROOT` o los defaults disponibles, para evitar que Gradle use rutas absolutas antiguas de otra maquina o instalacion.

El error:

```text
None of the following candidates is applicable ... kotlin
Unresolved reference 'compilerOptions'
Unresolved reference 'jvmTarget'
```

ocurria porque `android/app/build.gradle.kts` usaba un bloque top-level `kotlin { compilerOptions { ... } }` que este modulo Gradle no resolvia. Ya quedo corregido en este repo configurando directamente las tareas `KotlinCompile` con `compilerOptions.jvmTarget.set(JvmTarget.JVM_17)`, que es compatible con el template Flutter/Gradle usado aqui.

Si el error cambia a:

```text
'fun kotlinOptions(...)' is deprecated
'var jvmTarget: String' is deprecated
```

tambien queda cubierto: Gradle/Kotlin 2.3 ya trata esa deprecacion como error de script, por eso la configuracion actual usa `KotlinCompile.compilerOptions.jvmTarget.set(JvmTarget.JVM_17)` tanto en `android/app/build.gradle.kts` como en el workaround Android de `file_picker`.

Despues de actualizar el repo, limpia la copia temporal y reintenta:

```sh
rm -rf "$HOME/.codex/build-work/tanuki_android_build"
sh scripts/build_release.sh --skip-linux
```

Si aparece un warning de Flutter sobre migrar a Built-in Kotlin/Kotlin Gradle Plugin, es una advertencia de compatibilidad futura y no el fallo de build mostrado arriba.

### Comandos por plataforma

Android APK:

```sh
sh scripts/build_android.sh
```

Linux:

```sh
sh scripts/build_linux.sh
```

Si moviste el proyecto de disco/carpeta y Linux falla con un error como
`CMakeCache.txt ... is different than the directory ... where CMakeCache.txt was created`,
es una cache absoluta vieja de CMake. `scripts/build_linux.sh` la detecta y borra
automaticamente desde ahora. Si quieres limpiarlo manualmente:

```sh
rm -rf build/linux
sh scripts/build_linux.sh
```

Si durante Linux aparece `media_kit: WARNING: package:media_kit_libs_*** not found.`,
la cache de CMake puede haber quedado con `MEDIA_KIT_LIBS_AVAILABLE=OFF` despues
de mover el proyecto o cambiar dependencias. El script tambien limpia esa cache.
Despues de actualizar dependencias, corre:

```sh
flutter pub get
sh scripts/build_linux.sh
```

En este proyecto conviene usar los scripts con `sh` porque la carpeta esta en un volumen que puede no conservar permisos ejecutables (`android/gradlew` queda sin `+x`). El script Android copia el proyecto a `~/.codex/build-work/tanuki_android_build`, corrige permisos ahi y copia el APK de vuelta.

Si aun quieres usar comandos directos, hazlo solo desde un filesystem que conserve permisos ejecutables:

```sh
flutter build apk --release
flutter build linux --release
```

El build Linux no exige `libmpv-dev` para correr, pero si quieres que el reproductor se abra dentro de la app en Linux debes contar con los paquetes de desarrollo de `mpv` y `epoxy`. El script de build intenta instalarlos automaticamente en Debian/Ubuntu cuando faltan (`libmpv-dev`, `libepoxy-dev`, `libgtk-3-dev`, `cmake`, `ninja-build`); si no puedes instalarlos, el binario sigue funcionando con fallback externo.

## Releases con GitHub Actions

El repo incluye `.github/workflows/release.yml`. Al subir un tag `v*`, GitHub Actions compila en paralelo:

- Android: `tanuki-android-v0.8.11.apk`
- Linux x64: `tanuki-linux-x64-v0.8.11.tar.gz`
- Windows x64: `tanuki-windows-x64-v0.8.11.zip`

Despues, el job `GitHub Release` descarga los tres artefactos y los adjunta al release del tag.

Los artefactos temporales de Actions se guardan solo 1 dia (`retention-days: 1`) porque solo sirven para pasar APK/TAR.GZ/ZIP entre jobs. Los assets finales quedan en GitHub Releases.

Para publicar esta version:

```sh
git tag v0.8.11
git push origin main
git push origin v0.8.11
```

Tambien puede ejecutarse manualmente desde la pestana Actions usando `workflow_dispatch`; en ese caso usara la version de `pubspec.yaml`.

### Secrets obligatorios para Actions

Para que los builds de release incluyan integraciones de metadata/sync, agrega estos secrets en GitHub. El workflow falla si faltan `TMDB_API_KEY`/`TMDB_BEARER_TOKEN`, `FANART_API_KEY`, `MYANIMELIST_CLIENT_ID` o `SIMKL_CLIENT_ID`:

- `TMDB_BEARER_TOKEN`
- `TMDB_API_KEY`
- `FANART_API_KEY`
- `MYANIMELIST_CLIENT_ID`
- `MYANIMELIST_CLIENT_SECRET`
- `SIMKL_CLIENT_ID`

Windows PowerShell:

```powershell
.\scripts\build_windows.ps1
```

Comandos directos equivalentes para Windows:

```powershell
flutter build windows --release
```

`flutter build windows` debe ejecutarse en Windows con soporte desktop habilitado.

## Verificacion actual

La configuracion de build se reviso sin generar artefactos finales:

```sh
flutter pub get
sh -n scripts/build_release.sh scripts/build_android.sh scripts/build_linux.sh
sh scripts/check_build_config.sh
cmake -S linux -B /tmp/tanuki_linux_cmake_check -DCMAKE_BUILD_TYPE=Release
./gradlew help
./gradlew :app:assembleRelease --dry-run
```

`./gradlew` se ejecuto desde una copia temporal en `~/.codex/build-work/` para evitar el problema de permisos del volumen montado. Android configura y arma el grafo de `assembleRelease`; Linux configura CMake correctamente. No se generaron APK, bundle Linux ni zip Windows en esta verificacion.

En esta iteracion se quito el intento de reproducir paginas HTML remotas con `media_kit`. Cuando el resolver HTTP no entrega HLS/DASH/MP4, el player marca la fuente activa como fallida y prueba otra fuente automatica antes de quedar en `Resolver remoto pendiente`:

```sh
dart format lib/src/ui/player_screen.dart test/player_screen_test.dart
flutter test test/player_screen_test.dart --name "excludes active playback provider after remote resolve miss|does not exclude catalog or disabled providers after resolve miss"
flutter test test/playback_state_test.dart --plain-name "resolves fallback playback excluding failed remote providers"
flutter test test/playback_state_test.dart --plain-name "uses episode provider after preferred remote provider was excluded"
```

No se generaron builds en la ultima verificacion por instruccion del usuario. Los ultimos artefactos generados previamente siguen siendo:

- `dist/tanuki-android-release.apk` (93 MB)
- `dist/tanuki-linux-x64-release.tar.gz` (11 MB)
