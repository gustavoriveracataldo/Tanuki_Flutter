# Analisis y estado de migracion

## App Android original

La app nativa `android-tv-shell` esta organizada en:

- `MainActivity.kt`: navegacion TV, busqueda, biblioteca, detalle de serie, perfiles, playlists y ajustes.
- `PlayerActivity.kt`: reproductor local/remoto, cola, progreso, resolucion de fuentes remotas y fallbacks.
- `data/*`: modelos, persistencia, scanner local, catalogo remoto, servicios MAL/SIMKL/TMDB/Fanart/Filler.
- `res/layout/*` y `res/drawable/*`: estetica TV oscura, rail lateral, hero de anime, tarjetas, chips y overlay del player.

El port Flutter replica la estructura visual principal y los flujos de uso que no dependen de WebView Android.

## Portado en Flutter

- Rail lateral con secciones `Buscar`, `Anime`, `Random`, `Mi espacio`, `Playlist`, `Ajustes`.
- Selector y administracion de perfiles desde el rail con overlay tipo Android, perfiles persistidos, crear/renombrar/avatar/predeterminado/borrado y listas/progreso por perfil.
- Hero visual con fondo/poster/logo y composicion tipo Android: portada, rail colapsado, badge dinamico, logo o titulo alternativo, metadata/rating visible, shelf horizontal de `Tendencias` y shelf `Proximos estrenos` cuando hay fechas futuras.
- Inicio con hero de composicion antigua tipo Android: bloque logo/titulo/meta/sinopsis a la izquierda, acciones compactas a la derecha y rating en panel pequeno; shelf horizontal `Continuar viendo` como primera fila, usando varias series con progreso/current entry en vez de un unico strip, sin duplicar una misma serie importada desde distintas fuentes.
- `Continuar viendo` permite presion larga sobre una tarjeta para `Ir a serie` o `Dejar de ver`, limpiando estado/progreso de esa serie sin borrar la biblioteca.
- Inicio sin seccion `Biblioteca` en el panel principal y con `Tendencias` congeladas para que no cambien al buscar en el panel `Buscar`.
- Rail lateral sobre el contenido en escritorio para que las tarjetas no lo tapen; en portrait/celular cambia a barra inferior y el avatar se redujo.
- Inicio con hero fijo en capa superior; las filas pasan por debajo con fade gradual para que las tarjetas no tapen el hero. Las tarjetas remotas ya no muestran el icono visual de trailer.
- Detalle de serie con dos columnas como Android: informacion/acciones a la izquierda, logo o titulo alternativo como la app nativa, panel glass de episodios a la derecha y feedback TV de foco en filas de episodio.
- Detalle refresca visuales faltantes de series remotas ya importadas al abrir la ficha: logo, fondo, poster y miniaturas de episodio se reintentan con el mismo flujo TMDB/Fanart del importador, sin duplicar la serie.
- Panel `Similares` desde el detalle, con titulo/estado y grilla de resultados remotos usando recomendaciones Jikan o busqueda fallback.
- Trailers desde detalle, tendencias y busqueda: `trailerUrl` de Jikan se conserva en candidatos/series importadas y se abre una cola Flutter multiplataforma con controles anterior/siguiente; ahora intenta reproducir primero dentro de la app con `media_kit` y deja `Abrir externo` solo como fallback manual.
- Biblioteca local por carpetas con escaneo recursivo de videos.
- Catalogo remoto via Jikan con poster, descripcion, ano, fecha de estreno, formato, rating y cantidad de episodios.
- Busqueda AnimeAV1 por `catalogo?search=...`.
- Busqueda JKAnime y LatAnime usando los directorios HTML de cada proveedor.
- Pantalla de busqueda con composicion TV del Android original: texto de ayuda, filtros compactos funcionales (`Tipo`, `Temporada`, `Ano`), estado de busqueda/filtros tipo `search_status_text`, exploracion Jikan por temporada/ano, grilla de posters con overlay, skeleton de carga, chip de calendario cuando hay fecha futura y feedback TV de foco con borde naranja/elevacion/escala como Android.
- Buscador con consolidacion de tarjetas repetidas por identidad de serie entre catalogo, AnimeAV1, JKAnime y LatAnime; la tarjeta resultante conserva el mejor visual disponible, aliases y el mayor conteo de episodios encontrado.
- Buscador filtra resultados LatAnime `castellano` y normaliza `latino/castellano` en la clave de dedupe para evitar duplicar variantes como `Hunter x Hunter (2011)` y `Hunter x Hunter (2011) latino`.
- Accion `Random` del rail como Android, con Jikan `/random/anime` y fallback a resultados/biblioteca local.
- Importacion AnimeAV1 leyendo episodios desde `/media/<slug>`.
- Importacion JKAnime y LatAnime creando episodios reales cuando el proveedor expone conteo/listado.
- Resolucion AnimeAV1 directa a HLS `player.zilla-networks.com/m3u8/<id>` desde los modos `SUB` y `DUB`, incluyendo el payload Svelte actual `embeds:{SUB/DUB:[...]}` usado por paginas como Hunter x Hunter y el `iframe` Zilla visible usado por paginas como Rurouni Kenshin.
- Resolucion HTTP para paginas/iframes y payloads de proveedor que exponen directamente HLS, DASH o MP4, incluyendo iframes `jkplayer` y payloads `var servers`/`window.servers` de JKAnime con metadata real de servidor y orden automatico de hosts tipo Android antes del iframe nativo, fallback directo de URL JKAnime cuando la busqueda no devuelve candidato, fallback por servidor cuando un host ya resuelto falla en reproduccion, endpoints `ajax/api/player` llamados desde HTML, asignados a variables JavaScript simples o armados por concatenacion JS con literales/variables string, payloads de texto plano con hosts/medios sin comillas, scripts JavaScript empacados tipo Dean Edwards, URLs armadas por concatenacion JS, hosts UpCloud/Vidstream/Megacloud/Vidoza/SBPlay, conversion Zilla `play` a HLS `m3u8`, `data-player` y wrappers `reproductor?url=` de LatAnime con etiqueta visible de servidor aun cuando el nodo no use `class="play-video"`, priorizados sobre enlaces de descarga vencidos con fallback por servidor, `botlink`/`robotlink` de Streamtape, `botlink`/`bot_link` global de Netu/HQQ con `stream=1`, claves de player `manifest`/`playlist`/`playback_url`, Facebook `playable_url*`/`browser_native_*`, URLs codificadas en base64, Doodstream/`myvidplay` `pass_md5` y endpoints de descarga reproducibles.
- Fallback Android con WebView nativo oculto via MethodChannel cuando el resolver HTTP no encuentra HLS/DASH/MP4 en AnimeAV1/Zilla, JKAnime, LatAnime o Facebook: ejecuta JS, hace clicks de servidor/play, intercepta requests, lee fetch/XHR/video/jwplayer/videojs/dsplayer/olplayer, convierte enlaces Zilla `play` a HLS `m3u8`, respeta orden Android de servidores para JKAnime/LatAnime y devuelve headers/cookies/subtitulos remotos al player Flutter.
- Extraccion de subtitulos remotos VTT/SRT/ASS/TTML desde `<track>` y payloads `tracks`/`captions`/`subtitles` de hosts compatibles, con entrega a `media_kit`, control `SUB`/`OFF` y seleccion de pista en ajustes.
- Resolucion dinamica de episodios de catalogo hacia AnimeAV1, JKAnime o LatAnime segun la fuente preferida/automatica, sin requerir importacion previa de esa fuente.
- Importacion de series remotas al estado local.
- Playlist con progreso y cola de siguientes episodios.
- Panel Playlist/Player con cabecera de episodio actual, acciones `Reproducir siguiente`/`Listas` y columnas `Siguiente en la lista`/`Animes agregados` como Android.
- Progreso temporal por episodio con reanudacion y completado automatico al 95%, usando claves compatibles por serie/proveedor.
- Mi espacio con cabecera, resumen, textos de estado y secciones horizontales `Favoritos`, `Quiero ver`, `Viendo`, `Abandonadas` y `Completadas`.
- Ajustes con composicion vertical tipo Android, fuente remota preferida persistida, checkboxes `Luego/Mas tarde`, saltos automaticos, conexion/sync MAL/SIMKL compatible en JSON y resumen local.
- MyAnimeList con OAuth PKCE desde Ajustes, retorno manual multiplataforma, deep link Android `toonamitvshell://mal-auth/callback`, refresh de token, push de estado/progreso/favoritos con tags, pull de lista remota hacia `Mi espacio`/biblioteca y mappings persistidos.
- Conexion SIMKL por PIN multiplataforma, con Client ID por ajustes o `--dart-define`, polling, cuenta por perfil, pull de listas remotas hacia `Mi espacio`/biblioteca, pull de progreso remoto por episodio, push basico de estado/progreso local y scrobble `start`/`pause`/`stop` desde el reproductor.
- Metadata de relleno desde AnimeFillerList con cache persistente y aplicacion de tags `canon`, `mixed` y `filler` sobre episodios locales/remotos.
- Enriquecimiento de fichas de catalogo con Jikan para cast y metadata basica por episodio, y enriquecimiento opcional con TMDB/Fanart usando claves por `--dart-define` para poster, fondo, logo, descripcion, rating, trailer y metadata visual.
- Selector de arte TMDB alineado con Android antiguo: logos en `original`, posters/fondos desde `/images` por votos/tamano cuando existen, Fanart por temporada y fallback a poster/backdrop del detalle.
- Selector de arte TMDB/Fanart sensible al ano como Android antiguo: cuando el candidato trae ano, la busqueda prueba parametros de ano de TV/pelicula, descarta matches con diferencia mayor a 2 anos y cachea visuales con clave titulo/catalogo+ano para no mezclar series antiguas con remakes.
- Override TMDB para falsos positivos de remakes confirmados: Saint Seiya clasico/Caballeros del Zodiaco con ano 1985-1990 fuerza `tv/42444` en lugar de `tv/90855`; los logos TMDB ahora priorizan idioma japones por grupo antes de votos/tamano. La cache visual paso a prefijo `visual-v2` para no reutilizar arte resuelto antes de este ajuste.
- Persistencia JSON multiplataforma en application support.
- Player Android/Windows con `media_kit` para archivos locales, URLs directas y AnimeAV1 HLS resuelto. Si el resolver remoto no encuentra una URL directa en un proveedor activo, marca esa fuente como fallida y prueba otra fuente automatica antes de dejar el estado como `Resolver remoto pendiente`; catalogo y fuentes fuera de alcance quedan pendientes sin abrir paginas no reproducibles. No abre paginas HTML remotas con `media_kit`, porque esos casos en Android dependian de WebView oculto y probes JavaScript. Si un proveedor remoto directo falla antes de iniciar, reintenta el mismo episodio con otra fuente automatica sin cambiar la preferencia persistida; si la fuente ya avanzo o entrego frame de video, se mantiene en esa fuente y no salta a otro proveedor. Para trailers, la app intenta reproducir en pantalla propia antes de ofrecer fallback externo.
- Player con overlays propios auto-ocultables por inactividad, barra de progreso de `media_kit_video` en naranja Tanuki, panel de configuracion sin seccion redundante `Vista`, reanudacion con aliases expandidos por episodio equivalente y apertura con `Media.start` para AnimeAV1/Zilla cuando hay posicion guardada.
- Overlay del player con controles tipo Android para subtitulos `SUB`/`OFF`, seleccion de pista remota en ajustes, modo de vista `FIT`/`STR`, dialogo de ajustes, fuente/modo/servidor remotos y preferencia de escala persistida por serie.
- Top bar del player muestra siempre estado con icono y fuente/modo/servidor: por ejemplo `AnimeAV1 / DUB`, `JKAnime / Desu`, `LatAnime / MP4Upload`, mas estado de carga/play/error.
- Preferencias por serie compatibles con Android para fuente remota, modo AnimeAV1, servidor JKAnime, modo/opcion Facebook directo y escala de video. AnimeAV1 usa `SUB`/`DUB`; JKAnime prioriza el servidor guardado al ordenar hosts HTTP por encima del orden automatico, conserva la etiqueta de servidor del payload `var servers` y usa el orden recomendado actual `Desu`, `StreamWish`, `VidHide`, `MixDrop`, `Doodstream`, incluyendo aliases `sw`/`sfastwish`/`flaswish` y dominios familia `*wish`; ademas normaliza peliculas JKAnime a la ruta `/pelicula/` para evitar forzar `/1/` en titulos como Pokemon Movie 03. LatAnime usa la etiqueta visible de `data-player` para fallback por servidor y respeta el orden Android `Uqload`, `YourUpload`, `Doodstream`, `MP4Upload`. Facebook no se ofrece como fuente preferida global porque su lookup WebView Android no esta portado.
- Player Linux con autodeteccion de backend: usa video embebido si el build tiene `mpv`/`epoxy`, o fallback externo si no estan disponibles.
- Build Android, Windows y Linux con carpetas nativas incluidas.
- Empaquetado release simple en `dist/` con `scripts/build_release.sh` para Android/Linux y `scripts/build_release_windows.ps1` para Windows.
- Versionado Flutter en `pubspec.yaml`; version actual `0.8.7+87`.
- GitHub Actions de release: compila Android, Linux y Windows en jobs paralelos y junta APK/TAR.GZ/ZIP en un unico GitHub Release.
- GitHub Actions valida secrets obligatorios antes del release: TMDB (`TMDB_API_KEY` o `TMDB_BEARER_TOKEN`), Fanart, MAL Client ID y SIMKL Client ID.
- Scroll global con mouse/trackpad en desktop para filas horizontales y scrollables, usando `MaterialScrollBehavior` con `PointerDeviceKind.mouse`.
- Detalle de serie muestra poster dedicado ademas de logo/fondo.
- Buscador remoto con paginacion incremental de catalogo Jikan y accion `Cargar mas` al llegar al final.
- Player remoto recupera seeks grandes fuera del buffer reabriendo el mismo stream cerca de la posicion solicitada, no solo AnimeAV1.

## Pendiente para 1:1 con Android

Esta lista queda como guia de trabajo. No se deben seguir agregando casos pequenos del resolver si no cierran un punto de esta lista o una reproduccion real reportada.

### Metodo de avance

- Trabajar por hitos, no por microparches sueltos. Cada cambio debe cerrar o avanzar un item P0/P1/P2 de esta lista.
- Para el resolver remoto, agrupar familias de problemas similares en un solo cambio cuando sea posible: auditoria contra Android antiguo, ajuste Flutter/Android nativo, verificacion puntual y nota de estado.
- No correr builds, `flutter analyze` ni suites amplias durante esta fase salvo solicitud explicita o cierre de hito. Usar pruebas puntuales solo cuando validen el cambio hecho.
- Proveedores activos para paridad: AnimeAV1, JKAnime y LatAnime. AnimeKai y AnimeFLV quedan fuera del flujo activo por decision de alcance.
- Foco actual: cambios visuales y funcionales de `Inicio`, `Buscador` y `Detalle de serie`, comparando contra Android antiguo.
- Reproductor remoto pausado temporalmente por instruccion del usuario. Mantener lo ya portado, pero no guiar nuevos cambios hacia resolver/player hasta que se retome explicitamente.
- Orden recomendado mientras dure esta pausa: primero auditoria visual/navegacion TV de inicio/busqueda/detalle, despues catalogo/datos visibles en esas pantallas y al final distribucion.
- Resolucion remota en serie: aunque Android viejo usaba WebViews auxiliares/paralelos en algunos caminos de LatAnime, Flutter debe mantener el flujo serial con reintentos por servidor. No portar paralelismo salvo solicitud explicita.
- Linux queda pausado temporalmente por instruccion del usuario. Mantener el soporte/scaffold existente, pero no guiar cambios, pruebas ni builds hacia Linux hasta que se retome explicitamente.

### P0 - Reproductor remoto

- [ ] Replicar o reemplazar el comportamiento WebView oculto de `PlayerActivity.kt` para JKAnime y LatAnime. Avance actual: Android Flutter ya tiene fallback WebView nativo oculto cuando HTTP no resuelve; ahora tambien espera una ventana corta antes de devolver el primer candidato, como Android viejo, inspecciona reproductores JS usados por hosts (`jwplayer`, `dsplayer`, `olplayer`, `videojs`), captura subtitulos remotos desde DOM/payloads/red y conserva el servidor intentado en timeout para probar otro servidor del mismo proveedor antes de saltar de fuente. Falta validarlo con reproducciones reales y cubrir lo que dependa de POST/estado complejo, cookies/challenges y redirects creados por JS.
- [ ] Auditar JKAnime contra Android con ejemplos reales por servidor (`Desu`, `Magi`, `Desuka`, `Mega`, `Streamwish`, `Vidhide`, `Mixdrop`, `MP4Upload`, `Streamtape`, `Doodstream`). Ya hay resolucion de `var servers`/`window.servers`, endpoints XHR detectables, aliases `sw`/`flaswish`, orden recomendado `Desu` primero y normalizacion de peliculas a `/pelicula/`; faltan los casos que solo funcionan dentro del WebView antiguo.
- [ ] Auditar LatAnime contra Android con ejemplos reales por servidor (`Uqload`, `YourUpload`, `Doodstream`, `MP4Upload` y wrappers `reproductor?url=`). Ya se leen `data-player` y etiquetas visibles; la resolucion se mantiene en serie por decision de diseno, con reintentos por servidor en vez de WebViews paralelos.
- [ ] Validar AnimeAV1/Zilla en reproduccion real Android. La extraccion directa HLS `player.zilla-networks.com/m3u8/<id>` esta portada, incluyendo `SUB`/`DUB` y `iframe` visible; Android Flutter ademas cae al WebView nativo si la extraccion directa no entrega stream. Si sigue fallando, el pendiente probable queda en headers/runtime/player o compatibilidad del stream.
- [ ] Definir la estrategia para Facebook. Las entradas con URL directa progresiva/HLS se leen; el lookup WebView de Android no esta portado y no se ofrece como fuente preferida global.
- [ ] Mantener AnimeKai y AnimeFLV fuera del flujo activo por decision de alcance actual. El codigo legacy puede quedarse para compatibilidad de datos/pruebas, pero no debe guiar nuevos cambios.

### P0 - Player multiplataforma

- [ ] Verificar paridad de reproduccion en Android con fuentes reales de AnimeAV1, JKAnime y LatAnime. La app Flutter usa `media_kit`; Android antiguo usaba WebView/ExoPlayer en varios caminos.
- [ ] Linux pausado por ahora. No revisar fallback Linux, `mpv`/`epoxy` ni reproductor externo hasta nueva instruccion.
- [ ] Revisar tiempos de espera y cambio automatico de fuente para evitar saltos prematuros cuando el host todavia esta inicializando. Avance: el fallback WebView Android de Flutter ya no cierra instantaneamente con el primer HLS/MP4; usa espera de candidato de 420 ms general y 1050 ms en LatAnime, alineado con `PlayerActivity.kt`. AnimeAV1/Zilla ahora usa `Media.start` al reanudar y un watchdog post-seek para reabrir el HLS cerca de la posicion si un salto grande queda congelado, pendiente de prueba real.

### P1 - Auditoria visual y navegacion TV

- [ ] Auditar y ajustar `Inicio`: hero, rail, shelves, progreso/continuar viendo, acciones y densidad visual contra Android. Avance actual: se retiro la seccion `Biblioteca`, `Continuar viendo` deduplica por titulo normalizado, es la primera fila, admite `Ir a serie` y `Dejar de ver`, `Tendencias` ya no depende de la ultima busqueda, el hero volvio a la composicion antigua, queda fijo arriba, las tarjetas se desvanecen al pasar por debajo, el icono de trailer se retiro de tarjetas y el rail se adapta a portrait. Para TV se redujo la altura del hero, se reforzo la mascara superior para que las tarjetas no se vean por los bordes, el foco de tarjetas fuerza scroll por shelf para que se vea el titulo de la fila enfocada y el hero se actualiza con la tarjeta enfocada. Headers de filas mas compactos y sin subtitulos bajo la fila.
- [ ] Auditar y ajustar `Buscador`: campo, filtros, resultados remotos/locales, estados vacios/carga, foco y acciones rapidas. Avance actual: resultados remotos deduplicados por serie, conteo de episodios consolidado, tarjetas sin chip visual de servidor/fuente ni icono de trailer, variantes LatAnime `latino/castellano` normalizadas/filtradas y grilla portrait a 3 columnas.
- [ ] Auditar y ajustar `Detalle de serie`: poster/fondo/logo, acciones, metadata, lista de episodios, estado/progreso y paneles secundarios. Avance actual: las filas de episodio ya usan la imagen del episodio cuando existe y caen al poster de la serie cuando la metadata remota no trae miniatura; al abrir detalle se refrescan visuales faltantes de series remotas ya importadas. El control `Mi espacio` del detalle replica el patron Android con boton de icono y dialogo de estados, en vez de dropdown visible.
- [ ] Comparar pantalla por pantalla contra Android con capturas: rail, busqueda, detalle, episodios, playlist/player, `Mi espacio`, `Ajustes`, dialogos y overlays.
- [ ] Revisar foco con control remoto/teclado: orden de foco, estados seleccionados, scroll, retorno/back y acciones principales. Avance actual: tarjetas de inicio llaman `ensureVisible` al recibir foco, rail lateral/barra inferior tienen borde naranja visible y el top bar del player mantiene overlay visible mientras un control tiene foco.
- [ ] Ajustar solo diferencias visuales o de flujo que afecten el 1:1; evitar redisenos.

### P1 - Catalogo, importacion y datos

- [ ] Revisar busqueda/importacion por proveedor activo: aliases, ano, formato, conteo de episodios, duplicados y fallback de catalogo.
- [ ] Revisar que las preferencias por serie (`fuente`, `modo`, `servidor`, escala, subtitulos) se apliquen igual que Android.
- [ ] Completar auditoria MAL/SIMKL: errores, conflictos, mappings faltantes, multiples perfiles y estados no felices.
- [ ] Completar auditoria de metadata Jikan/TMDB/Fanart/Filler contra las vistas Android equivalentes. Avance actual: candidatos de Inicio/Buscador aplican cache visual persistente y lanzan enriquecimiento diferido TMDB/Fanart para logos/fondos como Android; en desktop tambien se leen claves desde variables de entorno si no vienen por `--dart-define`. TMDB ahora filtra visuales por ano cuando existe `releaseYear`, evitando que series antiguas como Samurai X o Saint Seiya tomen logos/fondos/episodios de remakes con el mismo nombre. Saint Seiya clasico queda cubierto con override explicito a TMDB `42444` y preferencia estricta de logo japones.

### P2 - Distribucion y verificacion final

- [ ] Dejar el flujo simple para generar APK, Windows EXE y paquete Linux cuando la paridad funcional este cerrada.
- [ ] Validar scripts de build al final. Por instruccion del usuario, no generar builds durante esta fase salvo que se pida explicitamente.
- [ ] Reducir pruebas durante cambios pequenos: usar una prueba puntual o verificacion manual por item de esta lista, y reservar `flutter analyze`/suites amplias para hitos.

## Verificacion reciente

Ultima actualizacion: se reforzo el release `0.8.7` con secrets obligatorios en GitHub Actions, scroll desktop con mouse/trackpad, poster en detalle, paginacion del buscador y recuperacion generica de seek remoto fuera de buffer.

Verificacion puntual de cambios visuales recientes:

- Revision sin build contra `activity_main.xml`, `item_remote_result_poster.xml`, `item_series_episode.xml` y `RemoteSearchAdapter.kt`.
- Revision estatica de `home_screen.dart` en las secciones editadas.
- Revision puntual del comportamiento de foco de `RemoteSearchAdapter.kt`: borde `#F47521`, elevacion 12 y escala `1.015`.
- Revision puntual del hero de Inicio contra `anime_hero_badge`, `anime_hero_meta`, `anime_hero_rating`, `anime_hero_logo_image` y `anime_hero_logo` de `activity_main.xml`.
- Revision puntual del encabezado de detalle contra `detail_logo_image`, `detail_plain_title` y `detail_title` de `activity_main.xml`/`MainActivity.kt`.
- Revision puntual del foco de episodios contra `SeriesEpisodeAdapter.kt`: borde `#F47521`, elevacion 9 y escala `1.004`.
- Revision puntual de `Proximos estrenos` contra `anime_upcoming_section`, `anime_upcoming_status` y `anime_upcoming_list` de `activity_main.xml`.
- Revision puntual del estado de Buscador contra `search_status_text` y `renderSearchPanel()` de `MainActivity.kt`.
- Revision estatica del snapshot de `Tendencias`, dedupe de `Continuar viendo`, dedupe de resultados remotos por identidad de serie y remocion de chips visuales de servidor/fuente en tarjetas.
- Revision estatica de `player_screen.dart` para fallback posterior a playback aceptado y etiqueta fuente/modo/servidor del top bar.
- Revision estatica de `home_screen.dart` para hero antiguo, barra inferior portrait, z-order del rail y accion `Dejar de ver`.
- Revision estatica de `remote_catalog_service.dart`/`app_controller.dart` para logos TMDB/Fanart y dedupe LatAnime `latino/castellano`.
- Revision estatica de `trailer_queue_screen.dart` para reproduccion embebida de trailers con `media_kit` y fallback externo manual.
- Revision estatica de `home_screen.dart` para hero fijo, menu de presion larga `Ir a serie`/`Dejar de ver` y fallback de imagen de episodio a poster de serie.
- Revision estatica de `models.dart`, `remote_catalog_service.dart` y `app_controller.dart` para orden JKAnime `Desu`, `StreamWish`, `VidHide`, `MixDrop`, `Doodstream` y normalizacion de peliculas a `/pelicula/`.
- Revision web puntual de `https://jkanime.net/pokemon-movie-03-kesshoutou-no-teiou-entei/pelicula/`: el sitio publica la pelicula como una pagina `/pelicula/`, no como `/1/`.
- Revision estatica de `home_screen.dart` para capa/fade del hero, remocion de icono trailer en tarjetas, grilla portrait de 3 columnas, skeleton Random, boton Inicio limpiando detalle y Ajustes sin fuente preferida/biblioteca/build.
- Revision estatica de `remote_catalog_service.dart` contra `RemoteCatalogService.kt` antiguo para selector de logo/poster/fondo TMDB/Fanart y metadata de episodios.
- Revision estatica de `home_screen.dart` para hero dinamico por foco, mascara superior del hero, scroll al foco de tarjetas y foco visible en rail lateral/barra inferior.
- Revision estatica de `player_screen.dart` para foco visible en controles del top bar y bloqueo del auto-hide mientras se navega con control remoto.
- Revision estatica de `home_screen.dart` para filas compactas sin subtitulos, scroll de shelf enfocado, rail con foco naranja de icono y control `Mi espacio` tipo Android.
- Revision estatica de `models.dart`, `app_controller.dart` y `remote_catalog_service.dart` para cache visual persistente, refresh diferido de candidatos y lectura runtime de claves TMDB/Fanart en desktop.
- Revision estatica de `remote_catalog_service.dart` y `app_controller.dart` para match TMDB por ano, descarte de remakes fuera de rango y cache visual diferenciada por ano.
- `dart format lib/src/services/remote_catalog_service.dart lib/src/app_controller.dart`
- `dart analyze lib/src/services/remote_catalog_service.dart lib/src/app_controller.dart` (sin issues).
- Revision estatica de `remote_catalog_service.dart` para override Saint Seiya clasico -> TMDB `42444`, rechazo de detalle TMDB con ano incompatible y selector de logo por prioridad de idioma japones.
- Revision estatica de `app_controller.dart` para prefijo `visual-v2` en cache de candidatos.
- `dart format lib/src/services/remote_catalog_service.dart lib/src/app_controller.dart`
- `dart analyze lib/src/services/remote_catalog_service.dart lib/src/app_controller.dart` (sin issues).
- Revision estatica de `pubspec.yaml`, `.github/workflows/release.yml`, `.gitignore`, `README.md` y servicios de configuracion para version `0.8.7` y release CI sin secretos locales.
- Revision estatica de `toonami_app.dart` para drag de scroll con mouse/trackpad.
- Revision estatica de `home_screen.dart` para poster en detalle y carga incremental de resultados.
- Revision estatica de `app_controller.dart`/`remote_catalog_service.dart` para paginacion Jikan.
- Revision estatica de `player_screen.dart` para recuperacion de seek remoto fuera de buffer.
- Revision estatica de `app_controller.dart` para refresco de visuales al abrir detalle y aliases expandidos de progreso/reanudacion.
- Revision estatica de `player_screen.dart` para auto-hide de overlays, tema naranja de controles `media_kit_video`, panel sin `Vista`, `Media.start` en AnimeAV1/Zilla y watchdog de seek grande.
- No se pudo correr `dart format` porque `dart`/`flutter` no estan disponibles en el PATH de esta sesion.

Verificacion puntual de cambios recientes del WebView nativo:

- Revision sin build del settle delay del WebView nativo Android (`420 ms` general, `1050 ms` LatAnime) contra `PlayerActivity.kt`.
- Revision sin build de probes JS del WebView nativo contra rutas equivalentes en `PlayerActivity.kt` (`jwplayer`, `dsplayer`, `olplayer`, `videojs`).
- Revision sin build de captura de subtitulos remotos del WebView nativo contra `extractSubtitleTracks` y `extractSubtitleTrackFromNetworkRequest` de `PlayerActivity.kt`.
- Revision sin build del fallback por timeout de servidor contra `handleJkAnimeServerResolutionTimeout` y `handleLatAnimeServerPlaybackError` de `PlayerActivity.kt`.

Verificaciones puntuales anteriores:

- `dart format lib/src/models.dart lib/src/services/remote_catalog_service.dart lib/src/services/remote_web_resolver.dart lib/src/ui/player_screen.dart test/remote_catalog_service_test.dart`
- Revision sin build del puente Kotlin para evitar overload ambiguo en `JSONArray`.
- Revision sin build del orden automatico de servidores en el WebView nativo (`JKAnime` y `LatAnime`).
- `flutter test test/remote_catalog_service_test.dart --plain-name "uses Android WebView resolver fallback after HTTP resolver misses"`
- `flutter test test/remote_catalog_service_test.dart --plain-name "uses Android WebView resolver fallback after AnimeAV1 direct miss"`

No se corrio `flutter analyze`, suites amplias ni builds. Por instruccion del usuario, los builds Android/Linux/Windows quedan para cuando se pidan explicitamente.

Windows queda con scaffold y script listo para compilarse en Windows cuando se habiliten builds:

```powershell
.\scripts\build_release_windows.ps1
```
