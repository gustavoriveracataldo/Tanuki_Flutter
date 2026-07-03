import 'package:flutter_test/flutter_test.dart';
import 'package:toonami_viernes_noche_flutter/src/app_controller.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/app_store.dart';
import 'package:toonami_viernes_noche_flutter/src/services/my_anime_list_service.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_catalog_service.dart';
import 'package:toonami_viernes_noche_flutter/src/services/simkl_service.dart';

void main() {
  test('serializes playback records in the active profile', () {
    const state = AppState(
      profiles: [
        UserProfileState(
          episodePlayback: {
            'demo|1': EpisodePlaybackRecord(
              positionMs: 60000,
              durationMs: 120000,
            ),
          },
        ),
      ],
    );

    final restored = AppState.fromJson(state.toJson());

    expect(restored.profile.episodePlayback['demo|1']?.positionMs, 60000);
    expect(restored.profile.episodePlayback['demo|1']?.durationMs, 120000);
    expect(restored.profile.episodePlayback['demo|1']?.completed, isFalse);
  });

  test('serializes series trailer url', () {
    const state = AppState(
      remoteLibrary: [
        SeriesItem(
          name: 'Demo',
          sourceType: SourceType.remote,
          episodeCount: 1,
          episodes: [
            EpisodeItem(
              seriesName: 'Demo',
              episodeIndex: 0,
              episodeNumber: 1,
              displayName: 'Demo - Capitulo 1',
              relativePath: 'Demo / Capitulo 1',
              filePath: 'https://example.test/demo/1',
              sourceType: SourceType.remote,
            ),
          ],
          trailerUrl: 'https://www.youtube.com/watch?v=demo123',
        ),
      ],
    );

    final restored = AppState.fromJson(state.toJson());

    expect(
      restored.remoteLibrary.single.trailerUrl,
      'https://www.youtube.com/watch?v=demo123',
    );
  });

  test('serializes MAL and SIMKL profile state', () {
    const state = AppState(
      myAnimeListClientId: 'mal-client',
      myAnimeListClientSecret: 'mal-secret',
      simklClientId: 'simkl-client',
      profiles: [
        UserProfileState(
          myAnimeListAuth: MyAnimeListAuthState(
            accessToken: 'mal-access',
            refreshToken: 'mal-refresh',
            expiresAtMs: 123,
            userId: 42,
            userName: 'MAL User',
            userPictureUrl: 'https://example.test/mal.jpg',
            connectedAtMs: 100,
            lastSyncAtMs: 200,
            lastSyncStatus: 'MAL ok',
          ),
          myAnimeListMappings: {'demo': 42},
          simklAuth: SimklAuthState(
            accessToken: 'simkl-access',
            userId: 99,
            userName: 'SIMKL User',
            userAvatarUrl: 'https://example.test/simkl.jpg',
            connectedAtMs: 300,
            lastSyncAtMs: 400,
            lastSyncError: 'SIMKL warn',
          ),
          simklMappings: {'demo': 99},
        ),
      ],
    );

    final restored = AppState.fromJson(state.toJson());

    expect(restored.myAnimeListClientId, 'mal-client');
    expect(restored.myAnimeListClientSecret, 'mal-secret');
    expect(restored.simklClientId, 'simkl-client');
    expect(restored.profile.myAnimeListAuth.isConnected, isTrue);
    expect(restored.profile.myAnimeListAuth.userName, 'MAL User');
    expect(restored.profile.myAnimeListMappings['demo'], 42);
    expect(restored.profile.simklAuth.isConnected, isTrue);
    expect(restored.profile.simklAuth.userName, 'SIMKL User');
    expect(restored.profile.simklMappings['demo'], 99);
  });

  test('updates MAL and SIMKL settings through controller', () async {
    final store = _MemoryAppStore(
      const AppState(
        profiles: [
          UserProfileState(
            myAnimeListAuth: MyAnimeListAuthState(
              accessToken: 'mal-access',
              refreshToken: 'mal-refresh',
              userId: 42,
            ),
            myAnimeListMappings: {'demo': 42},
            simklAuth: SimklAuthState(accessToken: 'simkl-access', userId: 99),
            simklMappings: {'demo': 99},
          ),
        ],
      ),
    );
    final controller = AppController(
      store: store,
      myAnimeListService: _FakeMyAnimeListService(),
      simklService: _FakeSimklService(),
    );
    await controller.initialize();

    await controller.setMyAnimeListClientId(' client ');
    await controller.setMyAnimeListClientSecret(' secret ');
    await controller.setSimklClientId(' simkl-client ');
    await controller.recordMyAnimeListSyncAttempt();
    await controller.recordSimklSyncAttempt();

    expect(store.state.myAnimeListClientId, 'client');
    expect(store.state.myAnimeListClientSecret, 'secret');
    expect(store.state.simklClientId, 'simkl-client');
    expect(
      store.state.profile.myAnimeListAuth.lastSyncStatus,
      'MAL actualizado: 1 series remotas importadas, 0 cambios locales enviados.',
    );
    expect(
      store.state.profile.simklAuth.lastSyncStatus,
      'SIMKL actualizado: 1 series remotas importadas, 1 cambios locales enviados.',
    );

    await controller.disconnectMyAnimeList();
    await controller.disconnectSimkl();

    expect(store.state.profile.myAnimeListAuth.isConnected, isFalse);
    expect(store.state.profile.myAnimeListMappings, isEmpty);
    expect(store.state.profile.simklAuth.isConnected, isFalse);
    expect(store.state.profile.simklMappings, isEmpty);
  });

  test('pushes local MAL status, favorite tag and watched progress', () async {
    final mal = _FakeMyAnimeListService(remoteEntries: const []);
    final store = _MemoryAppStore(
      const AppState(
        remoteLibrary: [
          SeriesItem(
            name: 'Demo',
            seriesStateKey: 'demo',
            sourceType: SourceType.remote,
            episodeCount: 12,
            catalogId: 321,
            releaseYear: 2024,
            format: 'TV',
            aliases: ['Demo Alt'],
            episodes: [
              EpisodeItem(
                seriesName: 'Demo',
                seriesStateKey: 'demo',
                episodeIndex: 0,
                episodeNumber: 1,
                displayName: 'Demo - Capitulo 1',
                relativePath: 'Demo / Capitulo 1',
                filePath: '',
                sourceType: SourceType.remote,
              ),
            ],
          ),
        ],
        profiles: [
          UserProfileState(
            playlists: [
              PlaylistState(
                id: 'default',
                name: 'Playlist principal',
                progress: {'demo': 2},
              ),
            ],
            activePlaylistId: 'default',
            favoriteSeries: {'demo'},
            watchingSeries: {'demo'},
            myAnimeListAuth: MyAnimeListAuthState(
              accessToken: 'mal-access',
              refreshToken: 'mal-refresh',
              userId: 42,
            ),
          ),
        ],
      ),
    );
    final controller = AppController(store: store, myAnimeListService: mal);
    await controller.initialize();

    await controller.recordMyAnimeListSyncAttempt();

    expect(mal.pushedUpdates, hasLength(1));
    expect(mal.pushedUpdates.single.title, 'Demo');
    expect(mal.pushedUpdates.single.malId, 321);
    expect(mal.pushedUpdates.single.favorite, isTrue);
    expect(mal.pushedUpdates.single.listStatus, 'watching');
    expect(mal.pushedUpdates.single.watchedEpisodes, 2);
    expect(store.state.profile.myAnimeListMappings['demo'], 321);
    expect(
      store.state.profile.myAnimeListAuth.lastSyncStatus,
      'MAL actualizado: 0 series remotas importadas, 1 cambios locales enviados.',
    );
  });

  test('connects MAL through OAuth redirect and imports remote list', () async {
    final mal = _FakeMyAnimeListService();
    final store = _MemoryAppStore(AppState.initial());
    final controller = AppController(store: store, myAnimeListService: mal);
    await controller.initialize();

    await controller.setMyAnimeListClientId('client');
    final url = await controller.beginMyAnimeListConnection();
    final pending = controller.myAnimeListPendingAuthorization;

    expect(url, 'https://myanimelist.test/authorize?state=state');
    expect(controller.isConnectingMyAnimeList, isTrue);
    expect(pending, isNotNull);

    await controller.completeMyAnimeListConnection(
      '${MyAnimeListService.redirectUri}?code=ok&state=${pending!.state}',
    );

    expect(store.state.profile.myAnimeListAuth.isConnected, isTrue);
    expect(store.state.profile.myAnimeListAuth.userName, 'MAL User');
    expect(store.state.profile.myAnimeListMappings['catalog:321'], 321);
    expect(store.state.profile.favoriteSeries, contains('catalog:321'));
    expect(store.state.profile.watchingSeries, contains('catalog:321'));
    expect(store.state.activePlaylist.progress['catalog:321'], 3);
    expect(store.state.remoteLibrary.single.name, 'Remote Demo');
    expect(controller.myAnimeListPendingAuthorization, isNull);
    expect(controller.isConnectingMyAnimeList, isFalse);
  });

  test('connects SIMKL with PIN and imports remote list', () async {
    final store = _MemoryAppStore(AppState.initial());
    final controller = AppController(
      store: store,
      simklService: _FakeSimklService(),
    );
    await controller.initialize();

    await controller.setSimklClientId('client');
    await controller.beginSimklConnection();

    expect(controller.simklPendingAuthorization?.userCode, 'ABCD');
    expect(controller.isConnectingSimkl, isTrue);

    await controller.pollSimklAuthorizationNow();

    expect(store.state.profile.simklAuth.isConnected, isTrue);
    expect(store.state.profile.simklAuth.userName, 'SIMKL User');
    expect(store.state.profile.simklMappings['catalog:321'], 654);
    expect(store.state.profile.watchingSeries, contains('catalog:321'));
    expect(store.state.activePlaylist.progress['catalog:321'], 3);
    expect(store.state.remoteLibrary.single.name, 'Remote Demo');
  });

  test('imports SIMKL remote episode progress into playback records', () async {
    final simkl = _FakeSimklService(
      progressEntries: const [
        SimklRemoteEpisodeProgress(
          simklId: 654,
          malId: 321,
          episodeNumber: 2,
          progressPercent: 50,
        ),
        SimklRemoteEpisodeProgress(
          simklId: 654,
          malId: 321,
          episodeNumber: 3,
          progressPercent: 100,
        ),
      ],
    );
    final store = _MemoryAppStore(
      const AppState(
        simklClientId: 'client',
        profiles: [
          UserProfileState(
            simklAuth: SimklAuthState(accessToken: 'simkl-access', userId: 99),
          ),
        ],
      ),
    );
    final controller = AppController(store: store, simklService: simkl);
    await controller.initialize();

    await controller.recordSimklSyncAttempt();

    final profile = store.state.profile;
    final episodeTwo = profile.episodePlayback['catalog:321|2'];
    final episodeThree = profile.episodePlayback['catalog:321|3'];
    expect(episodeTwo?.completed, isFalse);
    expect(episodeTwo?.durationMs, const Duration(minutes: 24).inMilliseconds);
    expect(episodeTwo?.positionMs, const Duration(minutes: 12).inMilliseconds);
    expect(episodeThree?.completed, isTrue);
    expect(episodeThree?.positionMs, episodeThree?.durationMs);
    expect(
      profile.simklAuth.lastSyncStatus,
      'SIMKL actualizado: 1 series remotas importadas, 0 cambios locales enviados, 2 progresos de episodios importados.',
    );
  });

  test('pushes local SIMKL status and watched progress', () async {
    final simkl = _FakeSimklService(remoteEntries: const []);
    final store = _MemoryAppStore(
      const AppState(
        simklClientId: 'client',
        remoteLibrary: [
          SeriesItem(
            name: 'Demo',
            seriesStateKey: 'demo',
            sourceType: SourceType.remote,
            episodeCount: 12,
            catalogId: 321,
            releaseYear: 2024,
            episodes: [
              EpisodeItem(
                seriesName: 'Demo',
                seriesStateKey: 'demo',
                episodeIndex: 0,
                episodeNumber: 1,
                displayName: 'Demo - Capitulo 1',
                relativePath: 'Demo / Capitulo 1',
                filePath: '',
                sourceType: SourceType.remote,
              ),
            ],
          ),
        ],
        profiles: [
          UserProfileState(
            playlists: [
              PlaylistState(
                id: 'default',
                name: 'Playlist principal',
                progress: {'demo': 2},
              ),
            ],
            activePlaylistId: 'default',
            watchingSeries: {'demo'},
            simklAuth: SimklAuthState(accessToken: 'simkl-access', userId: 99),
            simklMappings: {'demo': 654},
          ),
        ],
      ),
    );
    final controller = AppController(store: store, simklService: simkl);
    await controller.initialize();

    await controller.recordSimklSyncAttempt();

    expect(simkl.pushedUpdates, hasLength(1));
    expect(simkl.pushedUpdates.single.title, 'Demo');
    expect(simkl.pushedUpdates.single.simklId, 654);
    expect(simkl.pushedUpdates.single.malId, 321);
    expect(simkl.pushedUpdates.single.listStatus, 'watching');
    expect(simkl.pushedUpdates.single.watchedEpisodes, 2);
    expect(
      store.state.profile.simklAuth.lastSyncStatus,
      'SIMKL actualizado: 0 series remotas importadas, 1 cambios locales enviados.',
    );
  });

  test('sends SIMKL scrobble payload from current playback', () async {
    final simkl = _FakeSimklService(remoteEntries: const []);
    final store = _MemoryAppStore(
      const AppState(
        simklClientId: 'client',
        remoteLibrary: [
          SeriesItem(
            name: 'Demo',
            seriesStateKey: 'demo',
            sourceType: SourceType.remote,
            episodeCount: 12,
            catalogId: 321,
            releaseYear: 2024,
            episodes: [
              EpisodeItem(
                seriesName: 'Demo',
                seriesStateKey: 'demo',
                episodeIndex: 3,
                episodeNumber: 4,
                displayName: 'Demo - Capitulo 4',
                relativePath: 'Demo / Capitulo 4',
                filePath: '',
                sourceType: SourceType.remote,
              ),
            ],
          ),
        ],
        profiles: [
          UserProfileState(
            simklAuth: SimklAuthState(accessToken: 'simkl-access', userId: 99),
            simklMappings: {'demo': 654},
          ),
        ],
      ),
    );
    final controller = AppController(store: store, simklService: simkl);
    await controller.initialize();

    final sent = await controller.sendSimklScrobble(
      store.state.remoteLibrary.single.episodes.single,
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 24),
      action: 'start',
    );

    expect(sent, isTrue);
    expect(simkl.scrobbles, hasLength(1));
    expect(simkl.scrobbles.single.action, 'start');
    expect(simkl.scrobbles.single.update.title, 'Demo');
    expect(simkl.scrobbles.single.update.simklId, 654);
    expect(simkl.scrobbles.single.update.malId, 321);
    expect(simkl.scrobbles.single.update.episodeNumber, 4);
    expect(simkl.scrobbles.single.update.progressPercent, 50);
  });

  test(
    'persists partial progress and completes at the 95 percent threshold',
    () async {
      final store = _MemoryAppStore(
        const AppState(
          profiles: [
            UserProfileState(
              playlists: [
                PlaylistState(
                  id: 'default',
                  name: 'Playlist principal',
                  selectedSeries: {'demo'},
                ),
              ],
            ),
          ],
        ),
      );
      final controller = AppController(store: store);
      await controller.initialize();
      final episode = _episode();

      await controller.saveEpisodePlayback(
        episode,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 24),
      );

      expect(controller.activePlaylist.progress['demo'], isNull);
      expect(
        controller.resumePositionForEpisode(episode),
        const Duration(minutes: 10),
      );
      expect(controller.playbackForEpisode(episode)?.completed, isFalse);

      await controller.saveEpisodePlayback(
        episode,
        position: const Duration(minutes: 23),
        duration: const Duration(minutes: 24),
      );

      final record = controller.playbackForEpisode(episode);
      expect(record?.completed, isTrue);
      expect(record?.positionMs, const Duration(minutes: 24).inMilliseconds);
      expect(controller.resumePositionForEpisode(episode), isNull);
      expect(controller.activePlaylist.progress['demo'], 1);
      expect(
        controller.state.profile.episodePlayback['jkanime:demo|1']?.completed,
        isTrue,
      );
    },
  );

  test('persists per-series playback preferences', () async {
    final store = _MemoryAppStore(AppState.initial());
    final controller = AppController(store: store);
    await controller.initialize();
    final episode = _episode();

    await controller.setPlaybackProviderForEpisode(
      episode,
      RemoteProvider.jkAnime,
    );
    await controller.setAnimeAv1ModeForEpisode(
      episode,
      AnimeAv1PlaybackMode.dubHls,
    );
    await controller.setJkAnimeServerForEpisode(
      episode,
      JkAnimeServerPreference.mixDrop,
    );
    await controller.setFacebookModeForEpisode(
      episode,
      FacebookPlaybackMode.dub,
    );
    await controller.setFacebookOptionForEpisode(
      episode,
      FacebookPlaybackOption.second,
    );
    await controller.setVideoScaleModeForEpisode(
      episode,
      VideoScaleMode.stretch,
    );

    expect(
      controller.playbackProviderForEpisode(episode),
      RemoteProvider.jkAnime,
    );
    expect(
      controller.animeAv1ModeForEpisode(episode),
      AnimeAv1PlaybackMode.dubHls,
    );
    expect(
      controller.jkAnimeServerForEpisode(episode),
      JkAnimeServerPreference.mixDrop,
    );
    expect(
      controller.facebookModeForEpisode(episode),
      FacebookPlaybackMode.dub,
    );
    expect(
      controller.facebookOptionForEpisode(episode),
      FacebookPlaybackOption.second,
    );
    expect(
      controller.videoScaleModeForEpisode(episode),
      VideoScaleMode.stretch,
    );
    final stored = store.state.profile
        .seriesPlaybackPreferences[normalizeSeriesKey(episode.seriesName)];
    expect(stored?.provider, RemoteProvider.jkAnime);
    expect(stored?.animeAv1Mode, 'dub-hls');
    expect(stored?.jkAnimeServer, 'mixdrop');
    expect(stored?.facebookMode, 'dub');
    expect(stored?.facebookOption, 'option-2');
    expect(stored?.videoScaleMode, 'stretch');

    final restored = AppState.fromJson(store.state.toJson());

    final restoredPreference = restored.profile
        .seriesPlaybackPreferences[normalizeSeriesKey(episode.seriesName)];
    expect(restoredPreference?.provider, RemoteProvider.jkAnime);
    expect(restoredPreference?.animeAv1Mode, 'dub-hls');
    expect(restoredPreference?.jkAnimeServer, 'mixdrop');
    expect(restoredPreference?.facebookMode, 'dub');
    expect(restoredPreference?.facebookOption, 'option-2');
    expect(restoredPreference?.videoScaleMode, 'stretch');
  });

  test('normalizes disabled remote providers to automatic preferences',
      () async {
    final store = _MemoryAppStore(AppState.initial());
    final controller = AppController(store: store);
    await controller.initialize();
    final episode = _episode();

    await controller.setPreferredRemoteProvider(RemoteProvider.animeFlv);
    await controller.setPlaybackProviderForEpisode(
      episode,
      RemoteProvider.animeFlv,
    );

    expect(store.state.profile.preferredRemoteProvider, isNull);
    expect(
      store
          .state
          .profile
          .seriesPlaybackPreferences[normalizeSeriesKey(episode.seriesName)]
          ?.provider,
      isNull,
    );

    await controller.setPreferredRemoteProvider(RemoteProvider.animeKai);
    await controller.setPlaybackProviderForEpisode(
      episode,
      RemoteProvider.animeKai,
    );

    expect(store.state.profile.preferredRemoteProvider, isNull);
    expect(
      controller.playbackProviderForEpisode(
        episode.copyWith(provider: RemoteProvider.animeFlv),
      ),
      isNull,
    );
  });

  test('keeps Facebook direct-only instead of global preferred provider',
      () async {
    final store = _MemoryAppStore(AppState.initial());
    final controller = AppController(store: store);
    await controller.initialize();
    final catalogEpisode = _episode().copyWith(
      provider: RemoteProvider.catalog,
      filePath: 'https://myanimelist.net/anime/123',
      watchUrl: 'https://myanimelist.net/anime/123',
    );
    final facebookEpisode = _episode().copyWith(
      provider: RemoteProvider.facebook,
      slug: 'demo/videos/123',
      filePath: 'https://www.facebook.com/demo/videos/123/',
      watchUrl: 'https://www.facebook.com/demo/videos/123/',
    );

    await controller.setPreferredRemoteProvider(RemoteProvider.facebook);
    await controller.setPlaybackProviderForEpisode(
      catalogEpisode,
      RemoteProvider.facebook,
    );

    expect(store.state.profile.preferredRemoteProvider, isNull);
    expect(
      controller.canUsePlaybackProviderForEpisode(
        catalogEpisode,
        RemoteProvider.facebook,
      ),
      isFalse,
    );
    expect(controller.playbackProviderForEpisode(catalogEpisode), isNull);

    await controller.setPlaybackProviderForEpisode(
      facebookEpisode,
      RemoteProvider.facebook,
    );

    expect(
      controller.canUsePlaybackProviderForEpisode(
        facebookEpisode,
        RemoteProvider.facebook,
      ),
      isTrue,
    );
    expect(
      controller.playbackProviderForEpisode(facebookEpisode),
      RemoteProvider.facebook,
    );
  });

  test('filters and blocks disabled providers from active remote flows',
      () async {
    const animeFlvCandidate = RemoteSearchCandidate(
      provider: RemoteProvider.animeFlv,
      slug: 'flv-demo',
      title: 'FLV Demo',
    );
    const jkCandidate = RemoteSearchCandidate(
      provider: RemoteProvider.jkAnime,
      slug: 'jk-demo',
      title: 'JK Demo',
    );
    final store = _MemoryAppStore(AppState.initial());
    final controller = AppController(
      store: store,
      remoteCatalog: _FakeRemoteCatalog(const [
        animeFlvCandidate,
        jkCandidate,
      ]),
    );
    await controller.initialize();

    await controller.searchRemote('demo');

    expect(controller.remoteResults, [jkCandidate]);
    await expectLater(
      controller.importRemoteCandidate(animeFlvCandidate),
      throwsStateError,
    );
    expect(store.state.remoteLibrary, isEmpty);
    expect(controller.statusMessage, 'AnimeFLV esta fuera del flujo actual.');
  });

  test('persists preferred provider and prioritizes remote results', () async {
    final store = _MemoryAppStore(AppState.initial());
    final controller = AppController(
      store: store,
      remoteCatalog: _FakeRemoteCatalog(const [
        RemoteSearchCandidate(
          provider: RemoteProvider.animeAv1,
          slug: 'av1-demo',
          title: 'AV1 Demo',
        ),
        RemoteSearchCandidate(
          provider: RemoteProvider.jkAnime,
          slug: 'jk-demo',
          title: 'JK Demo',
        ),
      ]),
    );
    await controller.initialize();

    await controller.setPreferredRemoteProvider(RemoteProvider.jkAnime);
    await controller.searchRemote('demo');

    expect(store.state.profile.preferredRemoteProvider, RemoteProvider.jkAnime);
    expect(controller.remoteResults.first.provider, RemoteProvider.jkAnime);

    await controller.setPreferredRemoteProvider(null);

    expect(store.state.profile.preferredRemoteProvider, isNull);
  });

  test('resolves catalog playback through preferred remote provider', () async {
    const catalogEpisode = EpisodeItem(
      seriesName: 'Catalog Demo',
      seriesStateKey: 'catalog:222',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Catalog Demo - Capitulo 1',
      relativePath: 'Catalogo / Capitulo 1',
      filePath: 'https://myanimelist.net/anime/222',
      sourceType: SourceType.remote,
      provider: RemoteProvider.catalog,
      watchUrl: 'https://myanimelist.net/anime/222',
    );
    const providerEpisode = EpisodeItem(
      seriesName: 'Catalog Demo',
      seriesStateKey: 'jkanime:catalog-demo',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Catalog Demo - Capitulo 1',
      relativePath: 'JKAnime / Capitulo 1',
      filePath: 'https://jkanime.net/catalog-demo/1/',
      sourceType: SourceType.remote,
      provider: RemoteProvider.jkAnime,
      slug: 'catalog-demo',
      watchUrl: 'https://jkanime.net/catalog-demo/',
    );
    final fakeCatalog = _FakeRemoteCatalog(
      const [],
      providerEpisode: providerEpisode,
      directStream: const RemoteDirectStream(
        playbackUrl: 'https://cdn.example.test/catalog-demo.m3u8',
        playbackKind: 'hls',
        pageUrl: 'https://jkanime.net/catalog-demo/1/',
      ),
    );
    final store = _MemoryAppStore(
      const AppState(
        remoteLibrary: [
          SeriesItem(
            name: 'Catalog Demo',
            seriesStateKey: 'catalog:222',
            sourceType: SourceType.remote,
            provider: RemoteProvider.catalog,
            episodeCount: 1,
            catalogId: 222,
            episodes: [catalogEpisode],
          ),
        ],
      ),
    );
    final controller = AppController(
      store: store,
      remoteCatalog: fakeCatalog,
    );
    await controller.initialize();
    await controller.setPlaybackProviderForEpisode(
      catalogEpisode,
      RemoteProvider.jkAnime,
    );

    final stream = await controller.resolveRemoteDirectStream(catalogEpisode);

    expect(stream?.playbackUrl, 'https://cdn.example.test/catalog-demo.m3u8');
    expect(
        fakeCatalog.providerRequests.single.provider, RemoteProvider.jkAnime);
    expect(fakeCatalog.providerRequests.single.episode, catalogEpisode);
    expect(fakeCatalog.directStreamEpisodes.single, providerEpisode);
    expect(stream?.provider, RemoteProvider.jkAnime);
  });

  test('resolves fallback playback excluding failed remote providers',
      () async {
    const animeAv1Episode = EpisodeItem(
      seriesName: 'Fallback Demo',
      seriesStateKey: 'animeav1:fallback-demo',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Fallback Demo - Capitulo 1',
      relativePath: 'AnimeAV1 / Capitulo 1',
      filePath: 'https://animeav1.com/media/fallback-demo/1',
      sourceType: SourceType.remote,
      provider: RemoteProvider.animeAv1,
      slug: 'fallback-demo',
      watchUrl: 'https://animeav1.com/media/fallback-demo',
    );
    const jkEpisode = EpisodeItem(
      seriesName: 'Fallback Demo',
      seriesStateKey: 'jkanime:fallback-demo',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Fallback Demo - Capitulo 1',
      relativePath: 'JKAnime / Capitulo 1',
      filePath: 'https://jkanime.net/fallback-demo/1/',
      sourceType: SourceType.remote,
      provider: RemoteProvider.jkAnime,
      slug: 'fallback-demo',
      watchUrl: 'https://jkanime.net/fallback-demo/',
    );
    final fakeCatalog = _FakeRemoteCatalog(
      const [],
      providerEpisodesByProvider: const {
        RemoteProvider.jkAnime: jkEpisode,
      },
      directStreamsByProvider: const {
        RemoteProvider.jkAnime: RemoteDirectStream(
          playbackUrl: 'https://cdn.example.test/fallback-demo.m3u8',
          playbackKind: 'hls',
          pageUrl: 'https://jkanime.net/fallback-demo/1/',
        ),
      },
    );
    final store = _MemoryAppStore(
      const AppState(
        remoteLibrary: [
          SeriesItem(
            name: 'Fallback Demo',
            seriesStateKey: 'animeav1:fallback-demo',
            sourceType: SourceType.remote,
            provider: RemoteProvider.animeAv1,
            slug: 'fallback-demo',
            episodeCount: 1,
            episodes: [animeAv1Episode],
          ),
        ],
      ),
    );
    final controller = AppController(
      store: store,
      remoteCatalog: fakeCatalog,
    );
    await controller.initialize();

    final stream = await controller.resolveRemoteDirectStream(
      animeAv1Episode,
      excludedProviders: const {RemoteProvider.animeAv1},
    );

    expect(stream?.playbackUrl, 'https://cdn.example.test/fallback-demo.m3u8');
    expect(stream?.provider, RemoteProvider.jkAnime);
    expect(
      fakeCatalog.providerRequests.map((request) => request.provider),
      isNot(contains(RemoteProvider.animeAv1)),
    );
    expect(
        fakeCatalog.providerRequests.single.provider, RemoteProvider.jkAnime);
    expect(fakeCatalog.directStreamEpisodes, [jkEpisode]);
  });

  test('uses episode provider after preferred remote provider was excluded',
      () async {
    const animeAv1Episode = EpisodeItem(
      seriesName: 'Preferred Fallback Demo',
      seriesStateKey: 'animeav1:preferred-fallback-demo',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Preferred Fallback Demo - Capitulo 1',
      relativePath: 'AnimeAV1 / Capitulo 1',
      filePath: 'https://animeav1.com/media/preferred-fallback-demo/1',
      sourceType: SourceType.remote,
      provider: RemoteProvider.animeAv1,
      slug: 'preferred-fallback-demo',
      watchUrl: 'https://animeav1.com/media/preferred-fallback-demo',
    );
    final fakeCatalog = _FakeRemoteCatalog(
      const [],
      directStreamsByProvider: const {
        RemoteProvider.animeAv1: RemoteDirectStream(
          playbackUrl: 'https://cdn.example.test/animeav1/preferred.m3u8',
          playbackKind: 'hls',
          pageUrl: 'https://player.zilla-networks.com/play/preferred',
        ),
      },
    );
    final store = _MemoryAppStore(
      const AppState(
        profiles: [
          UserProfileState(
            preferredRemoteProvider: RemoteProvider.jkAnime,
          ),
        ],
        remoteLibrary: [
          SeriesItem(
            name: 'Preferred Fallback Demo',
            seriesStateKey: 'animeav1:preferred-fallback-demo',
            sourceType: SourceType.remote,
            provider: RemoteProvider.animeAv1,
            slug: 'preferred-fallback-demo',
            episodeCount: 1,
            episodes: [animeAv1Episode],
          ),
        ],
      ),
    );
    final controller = AppController(
      store: store,
      remoteCatalog: fakeCatalog,
    );
    await controller.initialize();

    final stream = await controller.resolveRemoteDirectStream(
      animeAv1Episode,
      excludedProviders: const {RemoteProvider.jkAnime},
    );

    expect(stream?.provider, RemoteProvider.animeAv1);
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/animeav1/preferred.m3u8',
    );
    expect(fakeCatalog.directStreamEpisodes, [animeAv1Episode]);
    expect(fakeCatalog.providerRequests, isEmpty);
  });

  test('skips disabled AnimeFLV during automatic provider fallback', () async {
    const catalogEpisode = EpisodeItem(
      seriesName: 'Disabled Provider Demo',
      seriesStateKey: 'catalog:333',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Disabled Provider Demo - Capitulo 1',
      relativePath: 'Catalogo / Capitulo 1',
      filePath: 'https://myanimelist.net/anime/333',
      sourceType: SourceType.remote,
      provider: RemoteProvider.catalog,
      watchUrl: 'https://myanimelist.net/anime/333',
    );
    const jkEpisode = EpisodeItem(
      seriesName: 'Disabled Provider Demo',
      seriesStateKey: 'jkanime:disabled-provider-demo',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Disabled Provider Demo - Capitulo 1',
      relativePath: 'JKAnime / Capitulo 1',
      filePath: 'https://jkanime.net/disabled-provider-demo/1/',
      sourceType: SourceType.remote,
      provider: RemoteProvider.jkAnime,
      slug: 'disabled-provider-demo',
      watchUrl: 'https://jkanime.net/disabled-provider-demo/',
    );
    final fakeCatalog = _FakeRemoteCatalog(
      const [],
      providerEpisodesByProvider: const {
        RemoteProvider.jkAnime: jkEpisode,
      },
      directStreamsByProvider: const {
        RemoteProvider.jkAnime: RemoteDirectStream(
          playbackUrl: 'https://cdn.example.test/disabled-demo.m3u8',
          playbackKind: 'hls',
          pageUrl: 'https://jkanime.net/disabled-provider-demo/1/',
        ),
      },
    );
    final store = _MemoryAppStore(
      const AppState(
        profiles: [
          UserProfileState(
            preferredRemoteProvider: RemoteProvider.animeFlv,
          ),
        ],
        remoteLibrary: [
          SeriesItem(
            name: 'Disabled Provider Demo',
            seriesStateKey: 'catalog:333',
            sourceType: SourceType.remote,
            provider: RemoteProvider.catalog,
            episodeCount: 1,
            catalogId: 333,
            episodes: [catalogEpisode],
          ),
        ],
      ),
    );
    final controller = AppController(
      store: store,
      remoteCatalog: fakeCatalog,
    );
    await controller.initialize();

    final stream = await controller.resolveRemoteDirectStream(catalogEpisode);

    expect(stream?.provider, RemoteProvider.jkAnime);
    expect(stream?.playbackUrl, 'https://cdn.example.test/disabled-demo.m3u8');
    expect(
      fakeCatalog.providerRequests.map((request) => request.provider),
      isNot(contains(RemoteProvider.animeFlv)),
    );
  });

  test('retries same provider while excluding failed remote servers', () async {
    const latEpisode = EpisodeItem(
      seriesName: 'Server Fallback Demo',
      seriesStateKey: 'latanime:server-fallback-demo',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Server Fallback Demo - Capitulo 1',
      relativePath: 'LatAnime / Capitulo 1',
      filePath: 'https://latanime.org/ver/server-fallback-demo-episodio-1',
      sourceType: SourceType.remote,
      provider: RemoteProvider.latAnime,
      slug: 'server-fallback-demo',
      watchUrl: 'https://latanime.org/anime/server-fallback-demo',
    );
    final fakeCatalog = _FakeRemoteCatalog(
      const [],
      directStreamsByProvider: const {
        RemoteProvider.latAnime: RemoteDirectStream(
          playbackUrl: 'https://cdn.example.test/latanime/uqload.m3u8',
          playbackKind: 'hls',
          pageUrl: 'https://latanime.org/ver/server-fallback-demo-episodio-1',
          server: 'uqload',
        ),
      },
    );
    final store = _MemoryAppStore(
      const AppState(
        remoteLibrary: [
          SeriesItem(
            name: 'Server Fallback Demo',
            seriesStateKey: 'latanime:server-fallback-demo',
            sourceType: SourceType.remote,
            provider: RemoteProvider.latAnime,
            slug: 'server-fallback-demo',
            episodeCount: 1,
            episodes: [latEpisode],
          ),
        ],
      ),
    );
    final controller = AppController(
      store: store,
      remoteCatalog: fakeCatalog,
    );
    await controller.initialize();

    final stream = await controller.resolveRemoteDirectStream(
      latEpisode,
      excludedRemoteServers: const {'yourupload'},
      excludedRemoteServersProvider: RemoteProvider.latAnime,
    );

    expect(stream?.provider, RemoteProvider.latAnime);
    expect(stream?.server, 'uqload');
    expect(fakeCatalog.directStreamEpisodes, [latEpisode]);
    expect(fakeCatalog.excludedServerRequests.single, {'yourupload'});
  });

  test('selects profiles independently', () async {
    final store = _MemoryAppStore(
      const AppState(
        profiles: [
          UserProfileState(id: 'principal', name: 'Principal'),
          UserProfileState(id: 'kids', name: 'Kids'),
        ],
      ),
    );
    final controller = AppController(store: store);
    await controller.initialize();

    await controller.selectProfile('kids');

    expect(controller.activeProfileId, 'kids');
    expect(controller.state.profile.name, 'Kids');

    await controller.createProfile('Invitado');

    expect(controller.state.profile.name, 'Invitado');
    expect(controller.profiles, hasLength(3));
  });

  test('manages profile metadata and default profile', () async {
    final store = _MemoryAppStore(
      const AppState(
        profiles: [
          UserProfileState(id: 'principal', name: 'Principal'),
          UserProfileState(id: 'kids', name: 'Kids'),
        ],
      ),
    );
    final controller = AppController(store: store);
    await controller.initialize();

    await controller.renameProfile('kids', 'Ninos');
    await controller.updateProfileAvatarPreset('kids', 'lagoon');
    await controller.setDefaultProfile('kids');

    final kids = store.state.profiles.firstWhere(
      (profile) => profile.id == 'kids',
    );
    expect(kids.name, 'Ninos');
    expect(kids.avatarPresetId, 'lagoon');
    expect(store.state.defaultProfileId, 'kids');

    await controller.setDefaultProfile(null);

    expect(store.state.defaultProfileId, isEmpty);

    await controller.deleteProfile('principal');

    expect(store.state.profiles.map((profile) => profile.id), ['kids']);
  });

  test('applies catalog search filters and browses by season', () async {
    final fakeCatalog = _FakeRemoteCatalog(const [
      RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: 'tv-demo',
        title: 'TV Demo',
        format: 'TV',
        releaseYear: 2024,
      ),
      RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: 'movie-demo',
        title: 'Movie Demo',
        format: 'Movie',
        releaseYear: 2024,
      ),
    ]);
    final controller = AppController(
      store: _MemoryAppStore(AppState.initial()),
      remoteCatalog: fakeCatalog,
    );
    await controller.initialize();

    await controller.cycleSearchFormatFilter('demo');

    expect(controller.searchFormatFilter, SearchFormatFilter.tv);
    expect(controller.remoteResults.map((candidate) => candidate.title), [
      'TV Demo',
    ]);

    await controller.clearSearchFilters('demo');
    await controller.cycleSearchSeasonFilter('');

    expect(fakeCatalog.lastSeason, controller.searchSeasonFilter.season);
    expect(fakeCatalog.lastSeasonYear, controller.searchSeasonFilter.year);
    expect(controller.remoteResults.single.title, 'Season Demo');
  });
}

EpisodeItem _episode() {
  return const EpisodeItem(
    seriesName: 'Demo',
    seriesStateKey: 'demo',
    episodeIndex: 0,
    episodeNumber: 1,
    displayName: 'Demo - Capitulo 1',
    relativePath: 'Demo / Capitulo 1',
    filePath: '/tmp/demo.mp4',
    sourceType: SourceType.remote,
    provider: RemoteProvider.jkAnime,
    slug: 'demo',
    watchUrl: 'https://jkanime.net/demo/',
  );
}

class _MemoryAppStore extends AppStore {
  _MemoryAppStore(this.state);

  AppState state;

  @override
  Future<AppState> load() async => state;

  @override
  Future<void> save(AppState state) async {
    this.state = state;
  }

  @override
  Future<String> storagePath() async => 'memory://tanuki_state.json';
}

class _FakeRemoteCatalog extends RemoteCatalogService {
  _FakeRemoteCatalog(
    this.results, {
    this.providerEpisode,
    this.directStream,
    this.providerEpisodesByProvider = const {},
    this.directStreamsByProvider = const {},
  });

  final List<RemoteSearchCandidate> results;
  final EpisodeItem? providerEpisode;
  final RemoteDirectStream? directStream;
  final Map<RemoteProvider, EpisodeItem?> providerEpisodesByProvider;
  final Map<RemoteProvider, RemoteDirectStream?> directStreamsByProvider;
  final providerRequests =
      <({SeriesItem series, EpisodeItem episode, RemoteProvider provider})>[];
  final directStreamEpisodes = <EpisodeItem>[];
  final excludedServerRequests = <Set<String>>[];
  String lastSeason = '';
  int lastSeasonYear = 0;

  @override
  Future<List<RemoteSearchCandidate>> search(String query) async => results;

  @override
  Future<EpisodeItem?> resolveProviderEpisode({
    required SeriesItem series,
    required EpisodeItem episode,
    required RemoteProvider provider,
  }) async {
    providerRequests.add((
      series: series,
      episode: episode,
      provider: provider,
    ));
    if (providerEpisodesByProvider.containsKey(provider)) {
      return providerEpisodesByProvider[provider];
    }
    return providerEpisode;
  }

  @override
  Future<RemoteDirectStream?> resolveDirectStream(
    EpisodeItem entry, {
    String preferredMode = 'sub-hls',
    String preferredFacebookMode = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
  }) async {
    directStreamEpisodes.add(entry);
    excludedServerRequests.add(excludedServers);
    final provider = entry.provider;
    if (provider != null && directStreamsByProvider.containsKey(provider)) {
      return directStreamsByProvider[provider];
    }
    return directStream;
  }

  @override
  Future<List<RemoteSearchCandidate>> discoverCatalogBySeason({
    required String season,
    required int year,
    String type = '',
    int limit = 25,
    int page = 1,
  }) async {
    lastSeason = season;
    lastSeasonYear = year;
    return [
      RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: 'season-demo',
        title: 'Season Demo',
        format: type.isEmpty ? 'TV' : type.toUpperCase(),
        releaseYear: year,
        airDateIso: '$year-${_monthForSeason(season)}-05T00:00:00+00:00',
      ),
    ];
  }

  @override
  void close() {}
}

class _FakeMyAnimeListService extends MyAnimeListService {
  _FakeMyAnimeListService({
    this.remoteEntries = const [
      MyAnimeListRemoteAnimeEntry(
        malId: 321,
        title: 'Remote Demo',
        imageUrl: 'https://example.test/mal.jpg',
        year: 2024,
        mediaType: 'tv',
        episodeCount: 12,
        status: MyAnimeListRemoteStatus(
          status: 'watching',
          watchedEpisodes: 3,
          tags: [MyAnimeListService.favoriteTag],
        ),
      ),
    ],
  });

  final List<MyAnimeListRemoteAnimeEntry> remoteEntries;
  List<MyAnimeListLocalAnimeUpdate> pushedUpdates = const [];

  @override
  String resolveClientId(String configuredClientId) {
    return configuredClientId.trim();
  }

  @override
  String resolveClientSecret(String configuredClientSecret) {
    return configuredClientSecret.trim();
  }

  @override
  bool hasConfiguredClientId(String configuredClientId) {
    return configuredClientId.trim().isNotEmpty;
  }

  @override
  MyAnimeListPendingAuthorization buildAuthorizationRequest({
    required String clientId,
  }) {
    return const MyAnimeListPendingAuthorization(
      clientId: 'client',
      state: 'state',
      codeVerifier: 'verifier',
      authorizationUrl: 'https://myanimelist.test/authorize?state=state',
      requestedAtMs: 1000,
    );
  }

  @override
  bool looksLikeAuthorizationRedirect(String value) {
    return value.startsWith(MyAnimeListService.redirectUri);
  }

  @override
  Future<MyAnimeListAuthState> completeAuthorization({
    required MyAnimeListPendingAuthorization request,
    required String redirectUrl,
    required String clientSecret,
  }) async {
    final uri = Uri.parse(redirectUrl);
    if (uri.queryParameters['state'] != request.state) {
      throw const MyAnimeListException('state invalido');
    }
    return const MyAnimeListAuthState(
      accessToken: 'mal-access',
      refreshToken: 'mal-refresh',
      expiresAtMs: 9999999999999,
      userId: 42,
      userName: 'MAL User',
      userPictureUrl: 'https://example.test/mal.jpg',
      connectedAtMs: 1000,
      lastSyncStatus: 'Cuenta MyAnimeList conectada.',
    );
  }

  @override
  Future<MyAnimeListAuthState> ensureFreshAuth({
    required MyAnimeListAuthState auth,
    required String clientId,
    required String clientSecret,
  }) async {
    return auth;
  }

  @override
  Future<MyAnimeListPushResult> pushLocalAnimeState({
    required String accessToken,
    required List<MyAnimeListLocalAnimeUpdate> updates,
  }) async {
    pushedUpdates = updates;
    return MyAnimeListPushResult(
      pushedCount: updates.length,
      mappings: {
        for (final update in updates)
          update.seriesKey: update.malId > 0 ? update.malId : 777,
      },
    );
  }

  @override
  Future<MyAnimeListRemoteSyncResult> fetchRemoteAnimeState({
    required String accessToken,
  }) async {
    return MyAnimeListRemoteSyncResult(remoteEntries: remoteEntries);
  }

  @override
  void close() {}
}

class _FakeSimklService extends SimklService {
  _FakeSimklService({
    this.remoteEntries = const [
      SimklRemoteAnimeEntry(
        simklId: 654,
        malId: 321,
        title: 'Remote Demo',
        year: 2024,
        status: 'watching',
        watchedEpisodes: 3,
        episodesTotal: 12,
        animeType: 'tv',
      ),
    ],
    this.progressEntries = const [],
  });

  final List<SimklRemoteAnimeEntry> remoteEntries;
  final List<SimklRemoteEpisodeProgress> progressEntries;
  List<SimklLocalAnimeUpdate> pushedUpdates = const [];
  List<({String action, SimklEpisodeScrobbleUpdate update})> scrobbles =
      const [];

  @override
  String resolveClientId(String configuredClientId) {
    return configuredClientId.trim();
  }

  @override
  bool hasConfiguredClientId(String configuredClientId) {
    return configuredClientId.trim().isNotEmpty;
  }

  @override
  Future<SimklPendingAuthorization> requestPinAuthorization({
    required String clientId,
  }) async {
    return const SimklPendingAuthorization(
      clientId: 'client',
      deviceCode: 'device',
      userCode: 'ABCD',
      verificationUrl: 'https://simkl.com/pin/',
      expiresInSeconds: 900,
      intervalSeconds: 5,
      requestedAtMs: 1000,
    );
  }

  @override
  Future<SimklPinPollResult> pollPinAuthorization(
    SimklPendingAuthorization request,
  ) async {
    return const SimklPinPollSuccess('simkl-token');
  }

  @override
  Future<SimklAuthenticatedUser> fetchAuthenticatedUser({
    required String accessToken,
    required String clientId,
  }) async {
    return const SimklAuthenticatedUser(
      userId: 99,
      userName: 'SIMKL User',
      avatarUrl: 'https://example.test/avatar.jpg',
    );
  }

  @override
  Future<SimklSyncResult> fetchRemoteAnimeState({
    required String accessToken,
    required String clientId,
  }) async {
    return SimklSyncResult(remoteEntries: remoteEntries);
  }

  @override
  Future<List<SimklRemoteEpisodeProgress>> fetchRemoteEpisodeProgress({
    required String accessToken,
    required String clientId,
  }) async {
    return progressEntries;
  }

  @override
  Future<SimklPushResult> pushLocalAnimeState({
    required String accessToken,
    required String clientId,
    required List<SimklLocalAnimeUpdate> updates,
  }) async {
    pushedUpdates = updates;
    return SimklPushResult(pushedCount: updates.length);
  }

  @override
  Future<void> scrobbleEpisode({
    required String accessToken,
    required String clientId,
    required String action,
    required SimklEpisodeScrobbleUpdate update,
  }) async {
    scrobbles = [...scrobbles, (action: action, update: update)];
  }

  @override
  void close() {}
}

String _monthForSeason(String season) {
  return switch (season) {
    'winter' => '01',
    'spring' => '04',
    'summer' => '07',
    _ => '10',
  };
}
