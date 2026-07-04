import 'dart:async';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'services/app_store.dart';
import 'services/filler_metadata_service.dart';
import 'services/local_library_scanner.dart';
import 'services/my_anime_list_service.dart';
import 'services/playlist_engine.dart';
import 'services/remote_catalog_service.dart';
import 'services/simkl_service.dart';

enum SearchFormatFilter {
  all('Tipo: Todos', ''),
  tv('Tipo: TV', 'tipo TV', 'tv'),
  movie('Tipo: Pelicula', 'tipo pelicula', 'movie'),
  ova('Tipo: OVA', 'tipo OVA', 'ova'),
  ona('Tipo: ONA', 'tipo ONA', 'ona');

  const SearchFormatFilter(
    this.label,
    this.summaryLabel, [
    this.catalogType = '',
  ]);

  final String label;
  final String summaryLabel;
  final String catalogType;

  SearchFormatFilter get next {
    final values = SearchFormatFilter.values;
    return values[(index + 1) % values.length];
  }

  bool matches(RemoteSearchCandidate candidate) {
    if (this == SearchFormatFilter.all) {
      return true;
    }
    final format = candidate.format.trim().toLowerCase();
    return format.isNotEmpty && format.contains(catalogType);
  }
}

class SearchSeasonFilter {
  const SearchSeasonFilter({
    this.season = '',
    this.year = 0,
    this.label = 'Temporada: Todas',
    this.summaryLabel = '',
  });

  final String season;
  final int year;
  final String label;
  final String summaryLabel;

  bool get isAll => season.trim().isEmpty || year <= 0;

  static List<SearchSeasonFilter> options({DateTime? now}) {
    final today = now ?? DateTime.now();
    final filters = <SearchSeasonFilter>[const SearchSeasonFilter()];
    var season = _seasonForMonth(today.month);
    var year = today.year;
    for (var index = 0; index < 10; index += 1) {
      final label = _seasonDisplayName(season);
      filters.add(
        SearchSeasonFilter(
          season: season,
          year: year,
          label: 'Temporada: $label $year',
          summaryLabel: '$label $year',
        ),
      );
      final previous = _previousSeason(season, year);
      season = previous.season;
      year = previous.year;
    }
    return filters;
  }

  SearchSeasonFilter get next {
    final filters = options();
    final currentIndex = filters.indexWhere(
      (filter) => filter.season == season && filter.year == year,
    );
    return filters[
        ((currentIndex < 0 ? 0 : currentIndex) + 1) % filters.length];
  }
}

enum SearchYearFilter {
  all('Ano: Todos', ''),
  modern('Ano: 2020+', 'ano 2020 o mas reciente', startYear: 2020),
  recent(
    'Ano: 2010-2019',
    'ano entre 2010 y 2019',
    startYear: 2010,
    endYear: 2019,
  ),
  y2k(
    'Ano: 2000-2009',
    'ano entre 2000 y 2009',
    startYear: 2000,
    endYear: 2009,
  ),
  retro(
    'Ano: 1990-2000',
    'ano entre 1990 y 2000',
    startYear: 1990,
    endYear: 2000,
  ),
  classic('Ano: <=1989', 'ano 1989 o anterior', endYear: 1989);

  const SearchYearFilter(
    this.label,
    this.summaryLabel, {
    this.startYear = 0,
    this.endYear = 0,
  });

  final String label;
  final String summaryLabel;
  final int startYear;
  final int endYear;

  SearchYearFilter get next {
    final values = SearchYearFilter.values;
    return values[(index + 1) % values.length];
  }

  ({int startYear, int endYear})? get yearRange {
    if (startYear > 0 || endYear > 0) {
      return (startYear: startYear, endYear: endYear);
    }
    return null;
  }

  bool matches(RemoteSearchCandidate candidate) {
    if (this == SearchYearFilter.all) {
      return true;
    }
    final year = candidate.releaseYear;
    if (year <= 0) {
      return false;
    }
    if (startYear > 0 && endYear > 0) {
      return year >= startYear && year <= endYear;
    }
    if (startYear > 0) {
      return year >= startYear;
    }
    if (endYear > 0) {
      return year <= endYear;
    }
    return true;
  }
}

String _seasonForMonth(int month) {
  return switch (month) {
    >= 1 && <= 3 => 'winter',
    >= 4 && <= 6 => 'spring',
    >= 7 && <= 9 => 'summer',
    _ => 'fall',
  };
}

({String season, int year}) _previousSeason(String season, int year) {
  return switch (season) {
    'winter' => (season: 'fall', year: year - 1),
    'spring' => (season: 'winter', year: year),
    'summer' => (season: 'spring', year: year),
    _ => (season: 'summer', year: year),
  };
}

String _seasonDisplayName(String season) {
  return switch (season.trim().toLowerCase()) {
    'winter' => 'Invierno',
    'spring' => 'Primavera',
    'summer' => 'Verano',
    _ => 'Otono',
  };
}

class AppController extends ChangeNotifier {
  static const MethodChannel _deepLinkChannel = MethodChannel(
    'tanuki/deep_links',
  );

  AppController({
    AppStore? store,
    LocalLibraryScanner? scanner,
    PlaylistEngine? playlistEngine,
    RemoteCatalogService? remoteCatalog,
    FillerMetadataService? fillerMetadata,
    MyAnimeListService? myAnimeListService,
    SimklService? simklService,
  })  : _store = store ?? const AppStore(),
        _scanner = scanner ?? const LocalLibraryScanner(),
        _playlistEngine = playlistEngine ?? const PlaylistEngine(),
        _remoteCatalog = remoteCatalog ?? RemoteCatalogService(),
        _fillerMetadata = fillerMetadata ?? FillerMetadataService(),
        _myAnimeListService = myAnimeListService ?? MyAnimeListService(),
        _simklService = simklService ?? SimklService() {
    _registerNativeDeepLinkHandler();
  }

  final AppStore _store;
  final LocalLibraryScanner _scanner;
  final PlaylistEngine _playlistEngine;
  final RemoteCatalogService _remoteCatalog;
  final FillerMetadataService _fillerMetadata;
  final MyAnimeListService _myAnimeListService;
  final SimklService _simklService;

  AppState _state = AppState.initial();
  List<SeriesItem> _localLibrary = const [];
  List<RemoteSearchCandidate> _remoteBaseResults = const [];
  List<RemoteSearchCandidate> _remoteResults = const [];
  SearchFormatFilter _searchFormatFilter = SearchFormatFilter.all;
  SearchSeasonFilter _searchSeasonFilter = const SearchSeasonFilter();
  SearchYearFilter _searchYearFilter = SearchYearFilter.all;
  bool _isScanning = false;
  bool _isSearching = false;
  bool _isLoadingMoreSearchResults = false;
  bool _hasMoreSearchResults = false;
  bool _isSaving = false;
  bool _isRefreshingFillerMetadata = false;
  bool _isConnectingMyAnimeList = false;
  bool _isSyncingMyAnimeList = false;
  bool _isConnectingSimkl = false;
  bool _isSyncingSimkl = false;
  MyAnimeListPendingAuthorization? _myAnimeListPendingAuthorization;
  SimklPendingAuthorization? _simklPendingAuthorization;
  Timer? _simklPollTimer;
  String _statusMessage = '';
  String _storePath = '';
  String _lastSearchQuery = '';
  int _searchPage = 1;

  AppState get state => _state;
  List<SeriesItem> get localLibrary => _localLibrary;
  List<SeriesItem> get remoteLibrary => _state.remoteLibrary;
  List<SeriesItem> get library => [..._localLibrary, ..._state.remoteLibrary];
  List<UserProfileState> get profiles => _state.profiles;
  List<RemoteSearchCandidate> get remoteResults => _remoteResults;
  SearchFormatFilter get searchFormatFilter => _searchFormatFilter;
  SearchSeasonFilter get searchSeasonFilter => _searchSeasonFilter;
  SearchYearFilter get searchYearFilter => _searchYearFilter;
  bool get hasActiveSearchFilters =>
      _searchFormatFilter != SearchFormatFilter.all ||
      !_searchSeasonFilter.isAll ||
      _searchYearFilter != SearchYearFilter.all;
  String get activeSearchFilterSummary {
    return [
      if (_searchFormatFilter != SearchFormatFilter.all)
        _searchFormatFilter.summaryLabel,
      if (!_searchSeasonFilter.isAll) _searchSeasonFilter.summaryLabel,
      if (_searchYearFilter != SearchYearFilter.all)
        _searchYearFilter.summaryLabel,
    ].where((entry) => entry.isNotEmpty).join(' y ');
  }

  bool get isScanning => _isScanning;
  bool get isSearching => _isSearching;
  bool get isLoadingMoreSearchResults => _isLoadingMoreSearchResults;
  bool get hasMoreSearchResults => _hasMoreSearchResults;
  bool get isSaving => _isSaving;
  bool get isRefreshingFillerMetadata => _isRefreshingFillerMetadata;
  bool get isConnectingMyAnimeList => _isConnectingMyAnimeList;
  bool get isSyncingMyAnimeList => _isSyncingMyAnimeList;
  bool get isConnectingSimkl => _isConnectingSimkl;
  bool get isSyncingSimkl => _isSyncingSimkl;
  SimklPendingAuthorization? get simklPendingAuthorization =>
      _simklPendingAuthorization;
  MyAnimeListPendingAuthorization? get myAnimeListPendingAuthorization =>
      _myAnimeListPendingAuthorization;
  bool get hasConfiguredMyAnimeListClientId =>
      _myAnimeListService.hasConfiguredClientId(_state.myAnimeListClientId);
  bool get hasConfiguredSimklClientId =>
      _simklService.hasConfiguredClientId(_state.simklClientId);
  String get statusMessage => _statusMessage;
  String get storePath => _storePath;
  PlaylistState get activePlaylist => _state.activePlaylist;
  String get activeProfileId => _state.profile.id;
  String get defaultProfileId => _state.defaultProfileId;
  RemoteProvider? get preferredRemoteProvider {
    final provider = _state.profile.preferredRemoteProvider;
    return _isSelectablePreferredRemoteProvider(provider) ? provider : null;
  }

  EpisodeItem? get currentEntry => _state.profile.currentEntry;
  SeriesPlaybackPreference playbackPreferenceForEpisode(EpisodeItem episode) {
    return _state.profile.seriesPlaybackPreferences[normalizeSeriesKey(
          episode.seriesName,
        )] ??
        const SeriesPlaybackPreference();
  }

  VideoScaleMode videoScaleModeForEpisode(EpisodeItem episode) {
    return videoScaleModeFromId(
      playbackPreferenceForEpisode(episode).videoScaleMode,
    );
  }

  RemoteProvider? playbackProviderForEpisode(EpisodeItem episode) {
    for (final provider in [
      playbackPreferenceForEpisode(episode).provider,
      preferredRemoteProvider,
      episode.provider,
    ]) {
      if (provider != null &&
          canUsePlaybackProviderForEpisode(episode, provider)) {
        return provider;
      }
    }
    return null;
  }

  bool canUsePlaybackProviderForEpisode(
    EpisodeItem episode,
    RemoteProvider provider,
  ) {
    if (_isDisabledRemoteProvider(provider) ||
        provider == RemoteProvider.catalog) {
      return false;
    }
    if (provider == RemoteProvider.facebook) {
      return episode.provider == RemoteProvider.facebook ||
          _findEquivalentRemoteEpisode(episode, provider) != null;
    }
    return true;
  }

  AnimeAv1PlaybackMode animeAv1ModeForEpisode(EpisodeItem episode) {
    final value = playbackPreferenceForEpisode(episode).animeAv1Mode;
    return animeAv1PlaybackModeFromId(value);
  }

  JkAnimeServerPreference jkAnimeServerForEpisode(EpisodeItem episode) {
    final value = playbackPreferenceForEpisode(episode).jkAnimeServer;
    return jkAnimeServerPreferenceFromId(value);
  }

  FacebookPlaybackMode facebookModeForEpisode(EpisodeItem episode) {
    final value = playbackPreferenceForEpisode(episode).facebookMode;
    return facebookPlaybackModeFromId(value);
  }

  FacebookPlaybackOption facebookOptionForEpisode(EpisodeItem episode) {
    final value = playbackPreferenceForEpisode(episode).facebookOption;
    return facebookPlaybackOptionFromId(value);
  }

  void setStatusMessage(String message) {
    _statusMessage = message.trim();
    notifyListeners();
  }

  Future<void> setMyAnimeListClientId(String clientId) async {
    _state = _state.copyWith(myAnimeListClientId: clientId.trim());
    await _save();
    _statusMessage = _state.myAnimeListClientId.isEmpty
        ? 'Client ID de MyAnimeList eliminado.'
        : 'Client ID de MyAnimeList guardado.';
    notifyListeners();
  }

  Future<void> setMyAnimeListClientSecret(String clientSecret) async {
    _state = _state.copyWith(myAnimeListClientSecret: clientSecret.trim());
    await _save();
    _statusMessage = _state.myAnimeListClientSecret.isEmpty
        ? 'Client Secret de MyAnimeList eliminado.'
        : 'Client Secret de MyAnimeList guardado.';
    notifyListeners();
  }

  Future<String> beginMyAnimeListConnection() async {
    if (_state.profile.myAnimeListAuth.isConnected) {
      _statusMessage = 'Este perfil ya esta conectado a MyAnimeList.';
      notifyListeners();
      return '';
    }
    if (_myAnimeListPendingAuthorization != null) {
      _statusMessage = 'Ya hay una autorizacion de MyAnimeList en progreso.';
      notifyListeners();
      return _myAnimeListPendingAuthorization!.authorizationUrl;
    }
    final clientId = _myAnimeListService.resolveClientId(
      _state.myAnimeListClientId,
    );
    if (clientId.isEmpty) {
      _statusMessage = 'Falta configurar el Client ID de MyAnimeList.';
      notifyListeners();
      return '';
    }
    try {
      final request = _myAnimeListService.buildAuthorizationRequest(
        clientId: clientId,
      );
      _myAnimeListPendingAuthorization = request;
      _isConnectingMyAnimeList = true;
      _statusMessage =
          'Autoriza MyAnimeList en el navegador y pega la URL de retorno.';
      notifyListeners();
      return request.authorizationUrl;
    } catch (error) {
      _statusMessage = 'No pude preparar MyAnimeList: $error';
      notifyListeners();
      return '';
    }
  }

  Future<void> completeMyAnimeListConnection(String redirectUrl) async {
    final request = _myAnimeListPendingAuthorization;
    if (request == null) {
      _statusMessage = 'No habia una autorizacion de MyAnimeList pendiente.';
      notifyListeners();
      return;
    }
    _statusMessage = 'Conectando la cuenta de MyAnimeList...';
    notifyListeners();
    try {
      final auth = await _myAnimeListService.completeAuthorization(
        request: request,
        redirectUrl: redirectUrl,
        clientSecret: _myAnimeListService.resolveClientSecret(
          _state.myAnimeListClientSecret,
        ),
      );
      _myAnimeListPendingAuthorization = null;
      _isConnectingMyAnimeList = false;
      _state = _state.copyWith(
        profile: _state.profile.copyWith(myAnimeListAuth: auth),
      );
      await _save();
      _statusMessage = 'Cuenta MyAnimeList conectada: ${auth.userName}.';
      notifyListeners();
      await recordMyAnimeListSyncAttempt();
    } catch (error) {
      await _updateMyAnimeListSyncStatus(
        lastSyncError: 'No pude conectar MyAnimeList: $error',
        notify: false,
      );
      _statusMessage = 'No pude conectar MyAnimeList: $error';
      notifyListeners();
    }
  }

  Future<void> cancelMyAnimeListConnection() async {
    _myAnimeListPendingAuthorization = null;
    _isConnectingMyAnimeList = false;
    _statusMessage = 'Autorizacion de MyAnimeList cancelada.';
    notifyListeners();
  }

  Future<void> recordMyAnimeListSyncAttempt() async {
    if (!_state.profile.myAnimeListAuth.isConnected) {
      _statusMessage = 'Este perfil todavia no esta conectado a MyAnimeList.';
      notifyListeners();
      return;
    }
    if (_isSyncingMyAnimeList) {
      _statusMessage = 'Ya hay una sincronizacion de MyAnimeList en progreso.';
      notifyListeners();
      return;
    }

    _isSyncingMyAnimeList = true;
    _statusMessage = 'Sincronizando con MyAnimeList...';
    notifyListeners();
    try {
      final auth = await _myAnimeListService.ensureFreshAuth(
        auth: _state.profile.myAnimeListAuth,
        clientId: _myAnimeListService.resolveClientId(
          _state.myAnimeListClientId,
        ),
        clientSecret: _myAnimeListService.resolveClientSecret(
          _state.myAnimeListClientSecret,
        ),
      );
      if (auth.accessToken != _state.profile.myAnimeListAuth.accessToken ||
          auth.refreshToken != _state.profile.myAnimeListAuth.refreshToken ||
          auth.expiresAtMs != _state.profile.myAnimeListAuth.expiresAtMs) {
        _state = _state.copyWith(
          profile: _state.profile.copyWith(myAnimeListAuth: auth),
        );
      }

      final pushResult = await _myAnimeListService.pushLocalAnimeState(
        accessToken: auth.accessToken,
        updates: _buildMyAnimeListLocalUpdates(_state),
      );
      if (pushResult.mappings.isNotEmpty) {
        _state = _state.copyWith(
          profile: _state.profile.copyWith(
            myAnimeListMappings: {
              ..._state.profile.myAnimeListMappings,
              ...pushResult.mappings,
            },
          ),
        );
      }

      final result = await _myAnimeListService.fetchRemoteAnimeState(
        accessToken: _state.profile.myAnimeListAuth.accessToken,
      );
      _state = _applyMyAnimeListRemoteEntries(_state, result.remoteEntries);
      final status = pushResult.unresolvedKeys.isEmpty
          ? 'MAL actualizado: ${result.remoteEntries.length} series remotas importadas, ${pushResult.pushedCount} cambios locales enviados.'
          : 'MAL actualizado parcialmente: ${result.remoteEntries.length} series remotas importadas, ${pushResult.pushedCount} cambios locales enviados y ${pushResult.unresolvedKeys.length} series sin resolver.';
      _state = _state.copyWith(
        profile: _state.profile.copyWith(
          myAnimeListAuth: _state.profile.myAnimeListAuth.copyWith(
            accessToken: auth.accessToken,
            refreshToken: auth.refreshToken,
            expiresAtMs: auth.expiresAtMs,
            lastSyncAtMs: DateTime.now().millisecondsSinceEpoch,
            lastSyncStatus: status,
            lastSyncError: '',
          ),
        ),
      );
      await _save();
      _statusMessage = status;
    } catch (error) {
      await _updateMyAnimeListSyncStatus(
        lastSyncError: 'No pude sincronizar MyAnimeList: $error',
        notify: false,
      );
    } finally {
      _isSyncingMyAnimeList = false;
      notifyListeners();
    }
  }

  Future<void> disconnectMyAnimeList() async {
    _state = _state.copyWith(
      profile: _state.profile.copyWith(clearMyAnimeList: true),
    );
    await _save();
    _statusMessage = 'MyAnimeList desconectado para este perfil.';
    notifyListeners();
  }

  Future<void> _updateMyAnimeListSyncStatus({
    String lastSyncStatus = '',
    String lastSyncError = '',
    bool notify = true,
  }) async {
    final auth = _state.profile.myAnimeListAuth.copyWith(
      lastSyncAtMs: DateTime.now().millisecondsSinceEpoch,
      lastSyncStatus: lastSyncStatus,
      lastSyncError: lastSyncError,
    );
    _state = _state.copyWith(
      profile: _state.profile.copyWith(myAnimeListAuth: auth),
    );
    await _save();
    _statusMessage = lastSyncError.isNotEmpty ? lastSyncError : lastSyncStatus;
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> setSimklClientId(String clientId) async {
    _state = _state.copyWith(simklClientId: clientId.trim());
    await _save();
    _statusMessage = _state.simklClientId.isEmpty
        ? 'Client ID de SIMKL eliminado.'
        : 'Client ID de SIMKL guardado.';
    notifyListeners();
  }

  Future<void> beginSimklConnection() async {
    if (_state.profile.simklAuth.isConnected) {
      _statusMessage = 'Este perfil ya esta conectado a SIMKL.';
      notifyListeners();
      return;
    }
    if (_isConnectingSimkl || _simklPendingAuthorization != null) {
      _statusMessage = 'Ya hay una autorizacion de SIMKL en progreso.';
      notifyListeners();
      return;
    }
    final clientId = _simklService.resolveClientId(_state.simklClientId);
    if (clientId.isEmpty) {
      _statusMessage = 'Falta configurar el Client ID de SIMKL.';
      notifyListeners();
      return;
    }

    _isConnectingSimkl = true;
    _statusMessage = 'Solicitando codigo PIN de SIMKL...';
    notifyListeners();
    try {
      final request = await _simklService.requestPinAuthorization(
        clientId: clientId,
      );
      _simklPendingAuthorization = request;
      _statusMessage =
          'Autoriza SIMKL en ${request.verificationUrl} con el codigo ${request.userCode}.';
      _scheduleNextSimklPoll(request.intervalSeconds);
    } catch (error) {
      _isConnectingSimkl = false;
      await _updateSimklSyncStatus(
        lastSyncError: 'No pude iniciar SIMKL: $error',
        notify: false,
      );
    }
    notifyListeners();
  }

  Future<void> pollSimklAuthorizationNow() async {
    final request = _simklPendingAuthorization;
    if (request == null) {
      return;
    }
    _simklPollTimer?.cancel();
    final result = await _simklService.pollPinAuthorization(request);
    switch (result) {
      case SimklPinPollSuccess(:final accessToken):
        await _handleSimklAuthorized(accessToken, request.clientId);
      case SimklPinPollPending(:final nextIntervalSeconds):
        _statusMessage =
            'Esperando autorizacion de SIMKL con codigo ${request.userCode}.';
        _scheduleNextSimklPoll(nextIntervalSeconds);
        notifyListeners();
      case SimklPinPollExpired(:final message):
        await _cancelSimklAuthorization(status: message, error: message);
      case SimklPinPollFailed(:final message):
        await _cancelSimklAuthorization(
          status: 'No pude conectar SIMKL: $message',
          error: message,
        );
    }
  }

  Future<void> recordSimklSyncAttempt() async {
    if (!_state.profile.simklAuth.isConnected) {
      _statusMessage = 'Este perfil todavia no esta conectado a SIMKL.';
      notifyListeners();
      return;
    }
    final clientId = _simklService.resolveClientId(_state.simklClientId);
    if (clientId.isEmpty) {
      await _updateSimklSyncStatus(
        lastSyncError: 'Falta configurar el Client ID de SIMKL.',
      );
      return;
    }
    if (_isSyncingSimkl) {
      _statusMessage = 'Ya hay una sincronizacion de SIMKL en progreso.';
      notifyListeners();
      return;
    }

    _isSyncingSimkl = true;
    _statusMessage = 'Sincronizando con SIMKL...';
    notifyListeners();
    try {
      final pushResult = await _simklService.pushLocalAnimeState(
        accessToken: _state.profile.simklAuth.accessToken,
        clientId: clientId,
        updates: _buildSimklLocalUpdates(_state),
      );
      final result = await _simklService.fetchRemoteAnimeState(
        accessToken: _state.profile.simklAuth.accessToken,
        clientId: clientId,
      );
      _state = _applySimklRemoteEntries(_state, result.remoteEntries);
      var remoteEpisodeProgressCount = 0;
      try {
        final remoteEpisodeProgress =
            await _simklService.fetchRemoteEpisodeProgress(
          accessToken: _state.profile.simklAuth.accessToken,
          clientId: clientId,
        );
        final applied = _applySimklRemoteEpisodeProgress(
          _state,
          remoteEpisodeProgress,
        );
        _state = applied.state;
        remoteEpisodeProgressCount = applied.appliedCount;
      } catch (_) {
        remoteEpisodeProgressCount = 0;
      }
      final progressText = remoteEpisodeProgressCount > 0
          ? ', $remoteEpisodeProgressCount progresos de episodios importados'
          : '';
      final status =
          'SIMKL actualizado: ${result.remoteEntries.length} series remotas importadas, ${pushResult.pushedCount} cambios locales enviados$progressText.';
      _state = _state.copyWith(
        profile: _state.profile.copyWith(
          simklAuth: _state.profile.simklAuth.copyWith(
            lastSyncAtMs: DateTime.now().millisecondsSinceEpoch,
            lastSyncStatus: status,
            lastSyncError: '',
          ),
        ),
      );
      await _save();
      _statusMessage = status;
    } catch (error) {
      await _updateSimklSyncStatus(
        lastSyncError: 'No pude sincronizar SIMKL: $error',
        notify: false,
      );
    } finally {
      _isSyncingSimkl = false;
      notifyListeners();
    }
  }

  Future<void> disconnectSimkl() async {
    _simklPollTimer?.cancel();
    _simklPendingAuthorization = null;
    _isConnectingSimkl = false;
    _state = _state.copyWith(
      profile: _state.profile.copyWith(clearSimkl: true),
    );
    await _save();
    _statusMessage = 'SIMKL desconectado para este perfil.';
    notifyListeners();
  }

  void _scheduleNextSimklPoll(int intervalSeconds) {
    _simklPollTimer?.cancel();
    final seconds = intervalSeconds < 3 ? 3 : intervalSeconds;
    _simklPollTimer = Timer(Duration(seconds: seconds), () {
      unawaited(pollSimklAuthorizationNow());
    });
  }

  Future<void> _handleSimklAuthorized(
    String accessToken,
    String clientId,
  ) async {
    _simklPollTimer?.cancel();
    _simklPendingAuthorization = null;
    _statusMessage = 'Conectando cuenta SIMKL...';
    notifyListeners();
    try {
      final user = await _simklService.fetchAuthenticatedUser(
        accessToken: accessToken,
        clientId: clientId,
      );
      final auth = SimklAuthState(
        accessToken: accessToken,
        userId: user.userId,
        userName: user.userName,
        userAvatarUrl: user.avatarUrl,
        connectedAtMs: DateTime.now().millisecondsSinceEpoch,
        lastSyncStatus: 'Cuenta SIMKL conectada.',
      );
      _state = _state.copyWith(
        profile: _state.profile.copyWith(simklAuth: auth),
      );
      await _save();
      _isConnectingSimkl = false;
      _statusMessage = 'Cuenta SIMKL conectada: ${user.userName}.';
      notifyListeners();
      await recordSimklSyncAttempt();
    } catch (error) {
      await _cancelSimklAuthorization(
        status: 'No pude completar SIMKL: $error',
        error: '$error',
      );
    }
  }

  Future<void> _cancelSimklAuthorization({
    required String status,
    String error = '',
  }) async {
    _simklPollTimer?.cancel();
    _simklPendingAuthorization = null;
    _isConnectingSimkl = false;
    _statusMessage = status;
    if (error.isNotEmpty) {
      await _updateSimklSyncStatus(lastSyncError: error, notify: false);
    }
    notifyListeners();
  }

  Future<void> _updateSimklSyncStatus({
    String lastSyncStatus = '',
    String lastSyncError = '',
    bool notify = true,
  }) async {
    final auth = _state.profile.simklAuth.copyWith(
      lastSyncAtMs: DateTime.now().millisecondsSinceEpoch,
      lastSyncStatus: lastSyncStatus,
      lastSyncError: lastSyncError,
    );
    _state = _state.copyWith(profile: _state.profile.copyWith(simklAuth: auth));
    await _save();
    _statusMessage = lastSyncError.isNotEmpty ? lastSyncError : lastSyncStatus;
    if (notify) {
      notifyListeners();
    }
  }

  EpisodePlaybackRecord? playbackForEpisode(EpisodeItem episode) {
    final aliases = _expandedEpisodePlaybackAliases(episode);
    for (final key in aliases) {
      final record = _state.profile.episodePlayback[key];
      if (record != null) {
        return record;
      }
    }

    final current = _state.profile.currentEntry;
    if (current != null &&
        current.episodeNumber == episode.episodeNumber &&
        normalizeSeriesKey(current.seriesName) ==
            normalizeSeriesKey(episode.seriesName)) {
      for (final key in _expandedEpisodePlaybackAliases(current)) {
        final record = _state.profile.episodePlayback[key];
        if (record != null) {
          return record;
        }
      }
    }
    return null;
  }

  Duration? resumePositionForEpisode(EpisodeItem episode) {
    final record = playbackForEpisode(episode);
    if (record == null || record.completed || record.positionMs <= 1000) {
      return null;
    }
    return Duration(milliseconds: record.positionMs);
  }

  Future<void> initialize() async {
    _state = await _store.load();
    _state = _state.copyWith(
      remoteLibrary: _applyFillerCacheToLibrary(_state.remoteLibrary),
    );
    _storePath = await _store.storagePath();
    notifyListeners();
    unawaited(_consumeInitialNativeDeepLink());
    if (_state.rootPaths.isNotEmpty) {
      await rescanLibrary();
    } else if (_state.remoteLibrary.isNotEmpty) {
      unawaited(refreshFillerMetadata());
    }
  }

  @override
  void dispose() {
    _simklPollTimer?.cancel();
    _remoteCatalog.close();
    _fillerMetadata.close();
    _myAnimeListService.close();
    _simklService.close();
    super.dispose();
  }

  Future<dynamic> _handleNativeDeepLinkCall(MethodCall call) async {
    if (call.method != 'link') {
      return null;
    }
    final link = '${call.arguments ?? ''}'.trim();
    await _handleNativeDeepLink(link);
    return null;
  }

  void _registerNativeDeepLinkHandler() {
    try {
      _deepLinkChannel.setMethodCallHandler(_handleNativeDeepLinkCall);
    } catch (_) {
      return;
    }
  }

  Future<void> _consumeInitialNativeDeepLink() async {
    try {
      final link = await _deepLinkChannel.invokeMethod<String>('initialLink');
      await _handleNativeDeepLink(link ?? '');
    } on MissingPluginException {
      return;
    } catch (_) {
      return;
    }
  }

  Future<void> _handleNativeDeepLink(String link) async {
    if (link.trim().isEmpty ||
        !_myAnimeListService.looksLikeAuthorizationRedirect(link)) {
      return;
    }
    await completeMyAnimeListConnection(link);
  }

  Future<void> chooseLibraryRoot() async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: 'Seleccionar carpeta de biblioteca',
      lockParentWindow: true,
    );
    if (selected == null || selected.trim().isEmpty) {
      return;
    }
    final roots = {..._state.rootPaths, selected.trim()}.toList()..sort();
    _state = _state.copyWith(rootPaths: roots);
    await _save();
    await rescanLibrary();
  }

  Future<void> removeLibraryRoot(String rootPath) async {
    final roots = _state.rootPaths.where((root) => root != rootPath).toList();
    _state = _state.copyWith(rootPaths: roots);
    await _save();
    await rescanLibrary();
  }

  Future<void> cycleSearchFormatFilter(String query) async {
    _searchFormatFilter = _searchFormatFilter.next;
    await searchRemote(query);
  }

  Future<void> cycleSearchSeasonFilter(String query) async {
    _searchSeasonFilter = _searchSeasonFilter.next;
    await searchRemote(query);
  }

  Future<void> cycleSearchYearFilter(String query) async {
    _searchYearFilter = _searchYearFilter.next;
    await searchRemote(query);
  }

  Future<void> clearSearchFilters(String query) async {
    if (!hasActiveSearchFilters) {
      return;
    }
    _searchFormatFilter = SearchFormatFilter.all;
    _searchSeasonFilter = const SearchSeasonFilter();
    _searchYearFilter = SearchYearFilter.all;
    await searchRemote(query);
  }

  Future<void> selectProfile(String profileId) async {
    if (!_state.profiles.any((profile) => profile.id == profileId)) {
      return;
    }
    _state = _state.copyWith(activeProfileId: profileId);
    await _save();
    _statusMessage = 'Perfil activo: ${_state.profile.name}.';
    notifyListeners();
  }

  Future<void> createProfile([String rawName = '']) async {
    final name = rawName.trim().isEmpty
        ? 'Perfil ${_state.profiles.length + 1}'
        : rawName.trim();
    final existingIds = _state.profiles.map((profile) => profile.id).toSet();
    final id = _createProfileId(name, existingIds);
    final profile = UserProfileState(
      id: id,
      name: name,
      avatarPresetId: _nextAvatarPresetId(
        _state.profiles.map((profile) => profile.avatarPresetId),
      ),
    );
    _state = _state.copyWith(
      profiles: [..._state.profiles, profile],
      activeProfileId: id,
    );
    await _save();
    _statusMessage = 'Perfil creado: $name.';
    notifyListeners();
  }

  Future<void> renameActiveProfile(String rawName) async {
    await renameProfile(_state.profile.id, rawName);
  }

  Future<void> renameProfile(String profileId, String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) {
      return;
    }
    final targetId = profileId.trim();
    var updated = false;
    final profiles = _state.profiles.map((profile) {
      if (profile.id != targetId) {
        return profile;
      }
      updated = true;
      return profile.copyWith(name: name);
    }).toList();
    if (!updated) {
      return;
    }
    _state = _state.copyWith(profiles: profiles);
    await _save();
    _statusMessage = 'Perfil renombrado: $name.';
    notifyListeners();
  }

  Future<void> updateProfileAvatarPreset(
    String profileId,
    String avatarPresetId,
  ) async {
    final targetId = profileId.trim();
    final nextAvatarPresetId = avatarPresetId.trim();
    if (targetId.isEmpty || nextAvatarPresetId.isEmpty) {
      return;
    }
    var updated = false;
    final profiles = _state.profiles.map((profile) {
      if (profile.id != targetId) {
        return profile;
      }
      updated = true;
      return profile.copyWith(avatarPresetId: nextAvatarPresetId);
    }).toList();
    if (!updated) {
      return;
    }
    _state = _state.copyWith(profiles: profiles);
    await _save();
    _statusMessage = 'Avatar de perfil actualizado.';
    notifyListeners();
  }

  Future<void> setDefaultProfile(String? profileId) async {
    final targetId = profileId?.trim() ?? '';
    if (targetId.isNotEmpty &&
        !_state.profiles.any((profile) => profile.id == targetId)) {
      return;
    }
    _state = _state.copyWith(defaultProfileId: targetId);
    await _save();
    _statusMessage = targetId.isEmpty
        ? 'Perfil predeterminado desactivado.'
        : 'Perfil predeterminado actualizado.';
    notifyListeners();
  }

  Future<void> deleteProfile(String profileId) async {
    if (_state.profiles.length <= 1) {
      return;
    }
    final remaining =
        _state.profiles.where((profile) => profile.id != profileId).toList();
    if (remaining.length == _state.profiles.length) {
      return;
    }
    _state = _state.copyWith(
      profiles: remaining,
      activeProfileId: remaining.first.id,
      defaultProfileId:
          _state.defaultProfileId == profileId ? '' : _state.defaultProfileId,
    );
    await _save();
    _statusMessage = 'Perfil eliminado.';
    notifyListeners();
  }

  Future<void> rescanLibrary() async {
    _isScanning = true;
    _statusMessage = 'Escaneando biblioteca local...';
    notifyListeners();
    try {
      _localLibrary = _applyFillerCacheToLibrary(
        await _scanner.scan(_state.rootPaths),
      );
      _statusMessage = _localLibrary.isEmpty
          ? 'No se encontraron episodios locales.'
          : 'Biblioteca actualizada: ${_localLibrary.length} series locales.';
      if (_localLibrary.isNotEmpty || _state.remoteLibrary.isNotEmpty) {
        unawaited(refreshFillerMetadata());
      }
    } catch (error) {
      _statusMessage = 'No se pudo escanear la biblioteca: $error';
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  Future<void> searchRemote(String query) async {
    final normalizedQuery = query.trim();
    final explicitYearRange = _parseSearchYearRangeQuery(normalizedQuery);
    final selectedYearRange = _searchYearFilter.yearRange;
    final blankSeasonBrowse =
        normalizedQuery.isEmpty && !_searchSeasonFilter.isAll;
    final blankYearBrowse = normalizedQuery.isEmpty &&
        !blankSeasonBrowse &&
        selectedYearRange != null;
    final requestLabel = _searchRequestLabel(
      query: normalizedQuery,
      explicitYearRange: explicitYearRange,
      selectedYearRange: selectedYearRange,
      blankSeasonBrowse: blankSeasonBrowse,
      blankYearBrowse: blankYearBrowse,
    );
    _isSearching = true;
    _isLoadingMoreSearchResults = false;
    _hasMoreSearchResults = false;
    _searchPage = 1;
    _lastSearchQuery = normalizedQuery;
    _statusMessage = requestLabel.isEmpty
        ? 'Cargando temporada actual...'
        : 'Buscando $requestLabel...';
    notifyListeners();
    try {
      final results = await _loadSearchResults(
        query: normalizedQuery,
        explicitYearRange: explicitYearRange,
        selectedYearRange: selectedYearRange,
        blankSeasonBrowse: blankSeasonBrowse,
        blankYearBrowse: blankYearBrowse,
        page: _searchPage,
      );
      _remoteBaseResults = _dedupeCandidates(
        _applyVisualCacheToCandidates(
          _sortByPreferredProvider(_activeRemoteCandidates(results)),
        ),
      );
      _remoteResults = _filterSearchResults(_remoteBaseResults);
      final filterSummary = activeSearchFilterSummary;
      final filteredSuffix = filterSummary.isEmpty ? '' : ' ($filterSummary)';
      _statusMessage = _remoteResults.isEmpty
          ? 'No se encontraron resultados remotos.'
          : '${_remoteResults.length} resultados encontrados$filteredSuffix.';
      _hasMoreSearchResults = _canLoadMoreSearchResults(
            query: normalizedQuery,
            explicitYearRange: explicitYearRange,
            selectedYearRange: selectedYearRange,
            blankSeasonBrowse: blankSeasonBrowse,
            blankYearBrowse: blankYearBrowse,
          ) &&
          results.length >= 20;
      if (normalizedQuery.isNotEmpty ||
          blankSeasonBrowse ||
          blankYearBrowse ||
          explicitYearRange != null ||
          selectedYearRange != null) {
        unawaited(_refreshRemoteResultVisuals());
      }
    } catch (error) {
      _remoteBaseResults = const [];
      _remoteResults = const [];
      _hasMoreSearchResults = false;
      _statusMessage = 'No se pudo cargar el catalogo remoto: $error';
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreSearchResults(String query) async {
    final normalizedQuery = query.trim();
    if (_isSearching ||
        _isLoadingMoreSearchResults ||
        !_hasMoreSearchResults ||
        normalizedQuery != _lastSearchQuery) {
      return;
    }
    final explicitYearRange = _parseSearchYearRangeQuery(normalizedQuery);
    final selectedYearRange = _searchYearFilter.yearRange;
    final blankSeasonBrowse =
        normalizedQuery.isEmpty && !_searchSeasonFilter.isAll;
    final blankYearBrowse = normalizedQuery.isEmpty &&
        !blankSeasonBrowse &&
        selectedYearRange != null;
    final nextPage = _searchPage + 1;
    _isLoadingMoreSearchResults = true;
    notifyListeners();
    try {
      final results = await _loadSearchResults(
        query: normalizedQuery,
        explicitYearRange: explicitYearRange,
        selectedYearRange: selectedYearRange,
        blankSeasonBrowse: blankSeasonBrowse,
        blankYearBrowse: blankYearBrowse,
        page: nextPage,
      );
      if (results.isEmpty) {
        _hasMoreSearchResults = false;
        return;
      }
      _searchPage = nextPage;
      _remoteBaseResults = _dedupeCandidates(
        _applyVisualCacheToCandidates(
          _sortByPreferredProvider(
            _activeRemoteCandidates([..._remoteBaseResults, ...results]),
          ),
        ),
      );
      _remoteResults = _filterSearchResults(_remoteBaseResults);
      _hasMoreSearchResults = results.length >= 20;
      final filterSummary = activeSearchFilterSummary;
      final filteredSuffix = filterSummary.isEmpty ? '' : ' ($filterSummary)';
      _statusMessage =
          '${_remoteResults.length} resultados encontrados$filteredSuffix.';
      unawaited(_refreshRemoteResultVisuals());
    } catch (error) {
      _statusMessage = 'No se pudo cargar mas catalogo remoto: $error';
    } finally {
      _isLoadingMoreSearchResults = false;
      notifyListeners();
    }
  }

  Future<List<RemoteSearchCandidate>> _loadSearchResults({
    required String query,
    required ({int startYear, int endYear})? explicitYearRange,
    required ({int startYear, int endYear})? selectedYearRange,
    required bool blankSeasonBrowse,
    required bool blankYearBrowse,
    required int page,
  }) {
    if (blankSeasonBrowse) {
      return _remoteCatalog.discoverCatalogBySeason(
        season: _searchSeasonFilter.season,
        year: _searchSeasonFilter.year,
        type: _searchFormatFilter.catalogType,
        page: page,
      );
    }
    if (explicitYearRange != null || blankYearBrowse) {
      final range = explicitYearRange ?? selectedYearRange!;
      return _remoteCatalog.discoverCatalogByYearRange(
        startYear: range.startYear,
        endYear: range.endYear,
        type: _searchFormatFilter.catalogType,
        page: page,
      );
    }
    if (page > 1) {
      return _remoteCatalog.searchCatalog(query, page: page);
    }
    return _remoteCatalog.search(query);
  }

  bool _canLoadMoreSearchResults({
    required String query,
    required ({int startYear, int endYear})? explicitYearRange,
    required ({int startYear, int endYear})? selectedYearRange,
    required bool blankSeasonBrowse,
    required bool blankYearBrowse,
  }) {
    return query.isNotEmpty ||
        blankSeasonBrowse ||
        blankYearBrowse ||
        explicitYearRange != null ||
        selectedYearRange != null ||
        query.isEmpty;
  }

  Future<List<RemoteSearchCandidate>> refreshCandidateVisuals(
    List<RemoteSearchCandidate> candidates, {
    int limit = 12,
  }) async {
    final cached = _applyVisualCacheToCandidates(candidates);
    final targets = cached
        .where(_candidateNeedsVisualRefresh)
        .where((candidate) => _visualCacheKeyForCandidate(candidate).isNotEmpty)
        .take(limit)
        .toList(growable: false);
    if (targets.isEmpty) {
      return cached;
    }

    var cacheChanged = false;
    final nextCache = Map<String, CandidateVisualCacheEntry>.from(
      _state.visualCache,
    );
    for (final candidate in targets) {
      try {
        final enriched = await _remoteCatalog.enrichCandidateVisuals(candidate);
        final key = _visualCacheKeyForCandidate(enriched);
        final entry = _visualCacheEntryForCandidate(enriched);
        if (key.isNotEmpty &&
            entry.hasMeaningfulContent &&
            _candidateVisualsChanged(candidate, enriched)) {
          nextCache[key] = entry;
          cacheChanged = true;
        }
      } catch (_) {
        // Visual refresh is opportunistic; base catalog data remains usable.
      }
    }

    if (cacheChanged) {
      _state = _state.copyWith(visualCache: nextCache);
      await _save();
      notifyListeners();
    }
    return _applyVisualCacheToCandidates(cached);
  }

  Future<void> _refreshRemoteResultVisuals() async {
    final source = _remoteBaseResults;
    if (source.isEmpty) {
      return;
    }
    final refreshed = await refreshCandidateVisuals(source, limit: 10);
    if (_remoteBaseResults != source) {
      return;
    }
    _remoteBaseResults = refreshed;
    _remoteResults = _filterSearchResults(_remoteBaseResults);
    notifyListeners();
  }

  Future<SeriesItem?> openRandomSeries() async {
    _statusMessage = 'Buscando un anime random...';
    notifyListeners();

    try {
      final randomCandidate = await _remoteCatalog.fetchCatalogRandomFallback();
      if (randomCandidate != null) {
        return await importRemoteCandidate(randomCandidate);
      }
    } catch (_) {
      // Fall back to cached candidates and imported series below.
    }

    final random = Random();
    final candidatePool =
        _remoteResults.where(_isSupportedRandomCandidate).toList();
    if (candidatePool.isNotEmpty) {
      _statusMessage = 'Jikan no respondio; usando catalogo local random.';
      notifyListeners();
      try {
        return await importRemoteCandidate(
          candidatePool[random.nextInt(candidatePool.length)],
        );
      } catch (_) {
        // Continue with the imported/local library fallback.
      }
    }

    final supportedLibraryPool =
        library.where(_isSupportedRandomSeries).toList();
    final libraryPool =
        supportedLibraryPool.isNotEmpty ? supportedLibraryPool : library;
    if (libraryPool.isNotEmpty) {
      _statusMessage = 'Jikan no respondio; usando catalogo local random.';
      notifyListeners();
      return libraryPool[random.nextInt(libraryPool.length)];
    }

    _statusMessage = 'No pude conseguir un anime random en este momento.';
    notifyListeners();
    return null;
  }

  Future<({List<RemoteSearchCandidate> candidates, String status})>
      loadSimilarCandidates(SeriesItem series) async {
    final related = <RemoteSearchCandidate>[];
    var usedRecommendations = false;

    if (series.catalogId > 0) {
      try {
        final recommendations =
            await _remoteCatalog.fetchCatalogRecommendations(series.catalogId);
        if (recommendations.isNotEmpty) {
          related.addAll(recommendations);
          usedRecommendations = true;
        }
      } catch (_) {
        // Search fallback below keeps the panel useful offline from Jikan recs.
      }
    }

    if (related.isEmpty) {
      final query = _stripProviderSuffix(series.name);
      if (query.isNotEmpty) {
        try {
          related.addAll(await _remoteCatalog.search(query));
        } catch (_) {
          // Return the empty-state message below.
        }
      }
    }

    final normalizedTitle = normalizeSeriesKey(
      _stripProviderSuffix(series.name),
    );
    final candidates = _dedupeCandidates(
      _sortByPreferredProvider(_activeRemoteCandidates(related)),
    )
        .where((candidate) {
          if (series.catalogId > 0 && candidate.catalogId == series.catalogId) {
            return false;
          }
          return normalizeSeriesKey(candidate.title) != normalizedTitle;
        })
        .take(15)
        .toList();

    final status = switch ((candidates.isEmpty, usedRecommendations)) {
      (true, _) => 'No encontre series similares para esta ficha todavia.',
      (false, true) =>
        'Basado en recomendaciones de anime similares y afinidad del catalogo.',
      _ => 'Series cercanas a esta para seguir explorando.',
    };
    return (candidates: candidates, status: status);
  }

  Future<SeriesItem> importRemoteCandidate(
    RemoteSearchCandidate candidate,
  ) async {
    final existing = findRemoteSeriesForCandidate(candidate);
    if (existing != null) {
      _statusMessage = '${existing.name} ya esta en la biblioteca.';
      notifyListeners();
      return existing;
    }
    if (_isDisabledRemoteProvider(candidate.provider)) {
      _statusMessage =
          '${candidate.provider.label} esta fuera del flujo actual.';
      notifyListeners();
      throw StateError(_statusMessage);
    }

    final existingNames = library.map((series) => series.name);
    final imported = await _remoteCatalog.buildImportSeries(
      candidate,
      existingNames: existingNames,
    );
    final importedWithFiller = _applyFillerCacheToSeries(imported);
    _state = _state.copyWith(
      remoteLibrary: [..._state.remoteLibrary, importedWithFiller],
    );
    await _save();
    _statusMessage = '${imported.name} importada a la biblioteca.';
    notifyListeners();
    unawaited(refreshFillerMetadata());
    return importedWithFiller;
  }

  Future<SeriesItem> refreshRemoteSeriesVisuals(SeriesItem series) async {
    final provider = series.provider;
    if (!series.isRemote ||
        provider == null ||
        provider == RemoteProvider.animeKai ||
        !_seriesNeedsVisualRefresh(series)) {
      return series;
    }
    final candidate = RemoteSearchCandidate(
      provider: provider,
      slug: series.slug,
      title: series.name,
      watchUrl: series.watchUrl,
      seriesUrl: series.watchUrl,
      imageUrl: series.imageUrl,
      backgroundUrl: series.backgroundUrl,
      logoUrl: series.logoUrl,
      trailerUrl: series.trailerUrl,
      description: series.description,
      rating: series.rating,
      episodeCount: series.episodeCount,
      format: series.format,
      japaneseTitle: series.japaneseTitle,
      aliases: series.aliases,
      releaseYear: series.releaseYear,
      catalogId: series.catalogId,
      cast: series.cast,
    );
    try {
      final refreshed = await _remoteCatalog.buildImportSeries(
        candidate,
        existingNames: const [],
      );
      final merged = _mergeSeriesVisuals(series, refreshed);
      if (merged == series) {
        return series;
      }
      _state = _state.copyWith(
        remoteLibrary: [
          for (final entry in _state.remoteLibrary)
            entry.stableKey == series.stableKey ? merged : entry,
        ],
      );
      await _save();
      notifyListeners();
      return merged;
    } catch (_) {
      return series;
    }
  }

  Future<void> setPreferredRemoteProvider(RemoteProvider? provider) async {
    final normalized =
        _isSelectablePreferredRemoteProvider(provider) ? provider : null;
    _state = _state.copyWith(
      profile: _state.profile.copyWith(
        preferredRemoteProvider: normalized,
        clearPreferredRemoteProvider: normalized == null,
      ),
    );
    await _save();
    _statusMessage = normalized == null
        ? 'Modo automatico para fuentes remotas.'
        : 'Fuente preferida: ${normalized.label}.';
    notifyListeners();
  }

  Future<RemoteDirectStream?> resolveRemoteDirectStream(
    EpisodeItem episode, {
    Set<RemoteProvider> excludedProviders = const {},
    Set<String> excludedRemoteServers = const {},
    RemoteProvider? excludedRemoteServersProvider,
  }) async {
    final excluded = {
      RemoteProvider.animeKai,
      RemoteProvider.animeFlv,
      ...excludedProviders.where(
        (provider) => provider != RemoteProvider.catalog,
      ),
    };
    final preference = playbackPreferenceForEpisode(episode);
    final requestedPreferredProvider = excludedRemoteServersProvider ??
        preference.provider ??
        preferredRemoteProvider;
    final usablePreferredProvider = requestedPreferredProvider != null &&
            canUsePlaybackProviderForEpisode(
              episode,
              requestedPreferredProvider,
            )
        ? requestedPreferredProvider
        : null;
    final preferredProvider = excluded.contains(usablePreferredProvider)
        ? null
        : usablePreferredProvider;
    final effectiveEpisode = _resolvePreferredRemoteEpisode(
      episode,
      preferredProvider,
    );
    final preferredEpisodeResolved = preferredProvider != null &&
        effectiveEpisode != episode &&
        effectiveEpisode.provider == preferredProvider;
    Future<RemoteDirectStream?> resolve(EpisodeItem target) async {
      final playbackTarget = _normalizeRemoteEpisodeForPlayback(target);
      final provider = playbackTarget.provider;
      if (provider != null && excluded.contains(provider)) {
        return null;
      }
      final stream = await _remoteCatalog.resolveDirectStream(
        playbackTarget,
        preferredMode: animeAv1PlaybackModeFromId(preference.animeAv1Mode).id,
        preferredFacebookMode: facebookPlaybackModeFromId(
          preference.facebookMode,
        ).id,
        preferredServer: playbackTarget.provider == RemoteProvider.jkAnime &&
                preference.jkAnimeServer.trim().isNotEmpty
            ? jkAnimeServerPreferenceFromId(preference.jkAnimeServer).id
            : '',
        excludedServers:
            playbackTarget.provider == excludedRemoteServersProvider
                ? excludedRemoteServers
                : const {},
      );
      return _tagDirectStreamProvider(stream, provider);
    }

    final shouldLookupProvider = episode.isRemote &&
        !preferredEpisodeResolved &&
        (episode.provider == null ||
            episode.provider == RemoteProvider.catalog ||
            (preferredProvider != null &&
                preferredProvider != episode.provider) ||
            (episode.provider != null && excluded.contains(episode.provider)));
    if (shouldLookupProvider) {
      final series = findSeriesForEpisode(episode);
      if (series != null) {
        for (final provider in _dynamicRemoteProviderOrder(preferredProvider)
            .where((provider) => !excluded.contains(provider))) {
          final libraryEpisode = _resolvePreferredRemoteEpisode(
            episode,
            provider,
          );
          final providerEpisode = libraryEpisode != episode
              ? libraryEpisode
              : await _remoteCatalog.resolveProviderEpisode(
                  series: series,
                  episode: episode,
                  provider: provider,
                );
          if (providerEpisode == null) {
            continue;
          }
          final stream = await resolve(providerEpisode);
          if (stream != null) {
            return _tagDirectStreamProvider(stream, provider);
          }
        }
      }
    }
    return resolve(effectiveEpisode);
  }

  EpisodeItem _normalizeRemoteEpisodeForPlayback(EpisodeItem episode) {
    if (episode.provider != RemoteProvider.jkAnime) {
      return episode;
    }
    final series = findSeriesForEpisode(episode);
    if (series == null) {
      return episode;
    }
    final format = series.format.trim().toLowerCase();
    final title =
        '${series.name} ${episode.displayName} ${episode.relativePath}'
            .trim()
            .toLowerCase();
    final movieLike = format.contains('movie') ||
        format.contains('pelicula') ||
        title.contains('movie') ||
        title.contains('pelicula');
    if (!movieLike || episode.filePath.toLowerCase().contains('/pelicula/')) {
      return episode;
    }
    final normalizedSlug =
        episode.slug.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalizedSlug.isEmpty) {
      return episode;
    }
    return episode.copyWith(
      relativePath: 'JKAnime / Pelicula',
      filePath: 'https://jkanime.net/$normalizedSlug/pelicula/',
    );
  }

  RemoteDirectStream? _tagDirectStreamProvider(
    RemoteDirectStream? stream,
    RemoteProvider? provider,
  ) {
    if (stream == null || provider == null || stream.provider == provider) {
      return stream;
    }
    return stream.copyWith(provider: provider);
  }

  List<RemoteProvider> _dynamicRemoteProviderOrder(
    RemoteProvider? preferredProvider,
  ) {
    const providers = [
      RemoteProvider.animeAv1,
      RemoteProvider.jkAnime,
      RemoteProvider.latAnime,
    ];
    if (preferredProvider == null ||
        _isDisabledRemoteProvider(preferredProvider) ||
        preferredProvider == RemoteProvider.catalog ||
        preferredProvider == RemoteProvider.facebook) {
      return providers;
    }
    return [
      preferredProvider,
      ...providers.where((provider) => provider != preferredProvider),
    ];
  }

  SeriesItem? findRemoteSeriesForCandidate(RemoteSearchCandidate candidate) {
    for (final series in _state.remoteLibrary) {
      if (candidate.catalogId > 0 && series.catalogId == candidate.catalogId) {
        return series;
      }
      if (candidate.slug.isNotEmpty &&
          series.provider == candidate.provider &&
          series.slug == candidate.slug) {
        return series;
      }
      if (series.provider == candidate.provider &&
          normalizeSeriesKey(_stripProviderSuffix(series.name)) ==
              normalizeSeriesKey(candidate.title)) {
        return series;
      }
    }
    return null;
  }

  EpisodeItem _resolvePreferredRemoteEpisode(
    EpisodeItem episode,
    RemoteProvider? provider,
  ) {
    if (!episode.isRemote ||
        provider == null ||
        _isDisabledRemoteProvider(provider) ||
        provider == RemoteProvider.catalog ||
        provider == episode.provider) {
      return episode;
    }
    return _findEquivalentRemoteEpisode(episode, provider) ?? episode;
  }

  EpisodeItem? _findEquivalentRemoteEpisode(
    EpisodeItem episode,
    RemoteProvider provider,
  ) {
    final episodeKeys = _seriesIdentityKeys(
      name: episode.seriesName,
      stateKey: episode.seriesStateKey,
    );
    for (final series in _state.remoteLibrary) {
      if (series.provider != provider ||
          !_seriesIdentityKeys(
            name: series.name,
            stateKey: series.seriesStateKey,
            japaneseTitle: series.japaneseTitle,
            aliases: series.aliases,
          ).any(episodeKeys.contains)) {
        continue;
      }
      final replacement = _findEquivalentEpisode(series, episode);
      if (replacement != null) {
        return replacement;
      }
    }
    return null;
  }

  EpisodeItem? _findEquivalentEpisode(SeriesItem series, EpisodeItem episode) {
    for (final candidate in series.episodes) {
      if (candidate.episodeNumber == episode.episodeNumber) {
        return candidate;
      }
    }
    if (episode.episodeIndex >= 0 &&
        episode.episodeIndex < series.episodes.length) {
      return series.episodes[episode.episodeIndex];
    }
    return null;
  }

  Set<String> _seriesIdentityKeys({
    required String name,
    String stateKey = '',
    String japaneseTitle = '',
    List<String> aliases = const [],
  }) {
    return {
      name,
      _stripProviderSuffix(name),
      stateKey,
      japaneseTitle,
      ...aliases,
    }.map(normalizeSeriesKey).where((entry) => entry.isNotEmpty).toSet();
  }

  bool _isSupportedRandomCandidate(RemoteSearchCandidate candidate) {
    return _isSupportedRandomFormat(candidate.format);
  }

  bool _isSupportedRandomSeries(SeriesItem series) {
    return series.format.trim().isEmpty ||
        _isSupportedRandomFormat(series.format);
  }

  bool _isSupportedRandomFormat(String format) {
    return switch (format.trim().toLowerCase()) {
      'tv' || 'movie' || 'ova' || 'ona' => true,
      _ => false,
    };
  }

  List<RemoteSearchCandidate> _filterSearchResults(
    List<RemoteSearchCandidate> candidates,
  ) {
    return candidates
        .where(_searchFormatFilter.matches)
        .where(_searchYearFilter.matches)
        .where(_matchesSearchSeasonFilter)
        .toList();
  }

  bool _matchesSearchSeasonFilter(RemoteSearchCandidate candidate) {
    if (_searchSeasonFilter.isAll) {
      return true;
    }
    final airDate = _parseCandidateAirDate(candidate.airDateIso);
    if (airDate == null) {
      return false;
    }
    return airDate.year == _searchSeasonFilter.year &&
        _seasonForMonth(airDate.month) == _searchSeasonFilter.season;
  }

  List<RemoteSearchCandidate> _activeRemoteCandidates(
    Iterable<RemoteSearchCandidate> candidates,
  ) {
    return candidates
        .where((candidate) => !_isDisabledRemoteProvider(candidate.provider))
        .toList();
  }

  DateTime? _parseCandidateAirDate(String value) {
    final trimmed = value.trim();
    if (trimmed.length < 10) {
      return null;
    }
    return DateTime.tryParse(trimmed.substring(0, 10));
  }

  ({int startYear, int endYear})? _parseSearchYearRangeQuery(String query) {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final exact = RegExp(r'^\d{4}$').firstMatch(normalized);
    if (exact != null) {
      final year = int.tryParse(normalized) ?? 0;
      return year >= 1900 && year <= 2100
          ? (startYear: year, endYear: year)
          : null;
    }
    final range = RegExp(r'^(\d{4})\s*[-–]\s*(\d{4})$').firstMatch(normalized);
    if (range == null) {
      return null;
    }
    final first = int.tryParse(range.group(1) ?? '') ?? 0;
    final second = int.tryParse(range.group(2) ?? '') ?? 0;
    if (first < 1900 || first > 2100 || second < 1900 || second > 2100) {
      return null;
    }
    return first <= second
        ? (startYear: first, endYear: second)
        : (startYear: second, endYear: first);
  }

  String _searchRequestLabel({
    required String query,
    required ({int startYear, int endYear})? explicitYearRange,
    required ({int startYear, int endYear})? selectedYearRange,
    required bool blankSeasonBrowse,
    required bool blankYearBrowse,
  }) {
    if (blankSeasonBrowse) {
      return _searchSeasonFilter.summaryLabel.isEmpty
          ? 'la temporada seleccionada'
          : 'la temporada ${_searchSeasonFilter.summaryLabel}';
    }
    if (explicitYearRange != null) {
      return _describeYearRange(explicitYearRange);
    }
    if (blankYearBrowse && selectedYearRange != null) {
      return _describeYearRange(selectedYearRange);
    }
    return query.isEmpty ? '' : '"$query"';
  }

  String _describeYearRange(({int startYear, int endYear}) range) {
    final startYear = range.startYear;
    final endYear = range.endYear;
    if (startYear > 0 && endYear > 0 && startYear == endYear) {
      return 'el ano $startYear';
    }
    if (startYear > 0 && endYear > 0) {
      return 'el periodo $startYear-$endYear';
    }
    if (startYear > 0) {
      return 'el ano $startYear en adelante';
    }
    if (endYear > 0) {
      return 'los anos hasta $endYear';
    }
    return 'el periodo seleccionado';
  }

  List<RemoteSearchCandidate> _sortByPreferredProvider(
    List<RemoteSearchCandidate> candidates,
  ) {
    final preferred = preferredRemoteProvider;
    if (preferred == null) {
      return candidates;
    }
    final indexed = candidates.indexed.toList()
      ..sort((left, right) {
        final leftScore = left.$2.provider == preferred ? 0 : 1;
        final rightScore = right.$2.provider == preferred ? 0 : 1;
        final scoreComparison = leftScore.compareTo(rightScore);
        return scoreComparison != 0
            ? scoreComparison
            : left.$1.compareTo(right.$1);
      });
    return indexed.map((entry) => entry.$2).toList();
  }

  List<RemoteSearchCandidate> _dedupeCandidates(
    Iterable<RemoteSearchCandidate> candidates,
  ) {
    final groups =
        <({Set<String> keys, List<RemoteSearchCandidate> candidates})>[];
    for (final candidate in candidates) {
      final keys = _candidateIdentityKeys(candidate);
      var added = false;
      for (final group in groups) {
        if (group.keys.any(keys.contains) &&
            _candidateGroupCanAccept(group.candidates, candidate)) {
          group.keys.addAll(keys);
          group.candidates.add(candidate);
          added = true;
          break;
        }
      }
      if (!added) {
        groups.add((keys: {...keys}, candidates: [candidate]));
      }
    }
    return [
      for (final group in groups) _mergeCandidateGroup(group.candidates),
    ];
  }

  Set<String> _candidateIdentityKeys(RemoteSearchCandidate candidate) {
    return {
      if (candidate.catalogId > 0) 'catalog:${candidate.catalogId}',
      candidate.title,
      _stripProviderSuffix(candidate.title),
      candidate.japaneseTitle,
      ...candidate.aliases,
    }
        .map(_stripProviderSuffix)
        .map(_stripLanguageEditionSuffix)
        .map(
          normalizeSeriesKey,
        )
        .where((entry) {
      return entry.isNotEmpty;
    }).toSet();
  }

  String _stripLanguageEditionSuffix(String value) {
    return value
        .replaceAll(
          RegExp(
            r'\b(?:audio\s+)?(?:latino|castellano)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _candidateGroupCanAccept(
    List<RemoteSearchCandidate> group,
    RemoteSearchCandidate candidate,
  ) {
    for (final existing in group) {
      if (existing.catalogId > 0 &&
          candidate.catalogId > 0 &&
          existing.catalogId != candidate.catalogId) {
        return false;
      }
      if (existing.releaseYear > 0 &&
          candidate.releaseYear > 0 &&
          existing.releaseYear != candidate.releaseYear) {
        return false;
      }
    }
    return true;
  }

  RemoteSearchCandidate _mergeCandidateGroup(
    List<RemoteSearchCandidate> candidates,
  ) {
    if (candidates.length == 1) {
      return candidates.first;
    }
    final primary = candidates.first;
    final aliases = <String>{
      ...primary.aliases,
      for (final candidate in candidates) ...[
        _stripProviderSuffix(candidate.title),
        candidate.japaneseTitle,
        ...candidate.aliases,
      ],
    }..removeWhere((value) {
        final key = normalizeSeriesKey(value);
        return key.isEmpty ||
            key == normalizeSeriesKey(primary.title) ||
            key == normalizeSeriesKey(primary.japaneseTitle);
      });
    return RemoteSearchCandidate(
      provider: primary.provider,
      slug: primary.slug,
      title: primary.title,
      watchUrl: primary.watchUrl,
      seriesUrl: _firstCandidateText(
        candidates,
        (candidate) => candidate.seriesUrl,
      ),
      imageUrl: _firstCandidateText(
        candidates,
        (candidate) => candidate.imageUrl,
      ),
      backgroundUrl: _firstCandidateText(
        candidates,
        (candidate) => candidate.backgroundUrl,
      ),
      logoUrl: _firstCandidateText(
        candidates,
        (candidate) => candidate.logoUrl,
      ),
      trailerUrl: _firstCandidateText(
        candidates,
        (candidate) => candidate.trailerUrl,
      ),
      description: _longestCandidateText(
        candidates,
        (candidate) => candidate.description,
      ),
      rating: _firstCandidateText(
        candidates,
        (candidate) => candidate.rating,
      ),
      episodeCount: candidates.fold<int>(
        primary.episodeCount,
        (best, candidate) => max(best, candidate.episodeCount),
      ),
      format: _firstCandidateText(
        candidates,
        (candidate) => candidate.format,
      ),
      japaneseTitle: _firstCandidateText(
        candidates,
        (candidate) => candidate.japaneseTitle,
      ),
      aliases: aliases.toList(growable: false),
      releaseYear: _firstPositiveCandidateInt(
        candidates,
        (candidate) => candidate.releaseYear,
      ),
      airDateIso: _firstCandidateText(
        candidates,
        (candidate) => candidate.airDateIso,
      ),
      catalogId: _firstPositiveCandidateInt(
        candidates,
        (candidate) => candidate.catalogId,
      ),
      cast: _longestCandidateList(
        candidates,
        (candidate) => candidate.cast,
      ),
      episodeDetails: _longestCandidateList(
        candidates,
        (candidate) => candidate.episodeDetails,
      ),
    );
  }

  List<RemoteSearchCandidate> _applyVisualCacheToCandidates(
    List<RemoteSearchCandidate> candidates,
  ) {
    return candidates.map(_applyVisualCacheToCandidate).toList(growable: false);
  }

  RemoteSearchCandidate _applyVisualCacheToCandidate(
      RemoteSearchCandidate candidate) {
    final key = _visualCacheKeyForCandidate(candidate);
    final cached = _state.visualCache[key];
    if (cached == null || !cached.hasMeaningfulContent) {
      return candidate;
    }
    return RemoteSearchCandidate(
      provider: candidate.provider,
      slug: candidate.slug,
      title: candidate.title,
      watchUrl: candidate.watchUrl,
      seriesUrl: candidate.seriesUrl,
      imageUrl:
          cached.imageUrl.isNotEmpty ? cached.imageUrl : candidate.imageUrl,
      backgroundUrl: cached.backgroundUrl.isNotEmpty
          ? cached.backgroundUrl
          : candidate.backgroundUrl,
      logoUrl: cached.logoUrl.isNotEmpty ? cached.logoUrl : candidate.logoUrl,
      trailerUrl: candidate.trailerUrl.isNotEmpty
          ? candidate.trailerUrl
          : cached.trailerUrl,
      description: cached.description.isNotEmpty
          ? cached.description
          : candidate.description,
      rating: candidate.rating.isNotEmpty ? candidate.rating : cached.rating,
      episodeCount: candidate.episodeCount,
      format: candidate.format,
      japaneseTitle: candidate.japaneseTitle.isNotEmpty
          ? candidate.japaneseTitle
          : cached.japaneseTitle,
      aliases: {
        ...candidate.aliases,
        ...cached.aliases,
      }.where((entry) => entry.trim().isNotEmpty).toList(growable: false),
      releaseYear: candidate.releaseYear,
      airDateIso: candidate.airDateIso,
      catalogId: candidate.catalogId,
      cast: candidate.cast.isNotEmpty ? candidate.cast : cached.cast,
      episodeDetails: candidate.episodeDetails,
    );
  }

  bool _candidateNeedsVisualRefresh(RemoteSearchCandidate candidate) {
    if (candidate.provider == RemoteProvider.animeKai ||
        candidate.title.trim().isEmpty) {
      return false;
    }
    final cacheKey = _visualCacheKeyForCandidate(candidate);
    if (candidate.releaseYear > 0 &&
        !_state.visualCache.containsKey(cacheKey)) {
      return true;
    }
    return candidate.logoUrl.isEmpty ||
        candidate.backgroundUrl.isEmpty ||
        candidate.backgroundUrl == candidate.imageUrl;
  }

  bool _candidateVisualsChanged(
    RemoteSearchCandidate before,
    RemoteSearchCandidate after,
  ) {
    return before.imageUrl != after.imageUrl ||
        before.backgroundUrl != after.backgroundUrl ||
        before.logoUrl != after.logoUrl ||
        before.trailerUrl != after.trailerUrl ||
        before.description != after.description ||
        before.rating != after.rating ||
        before.japaneseTitle != after.japaneseTitle ||
        before.aliases.join('\n') != after.aliases.join('\n') ||
        before.cast.join('\n') != after.cast.join('\n');
  }

  String _visualCacheKeyForCandidate(RemoteSearchCandidate candidate) {
    const cachePrefix = 'visual-v3';
    if (candidate.catalogId > 0) {
      final yearSuffix =
          candidate.releaseYear > 0 ? ':${candidate.releaseYear}' : '';
      return '$cachePrefix:catalog:${candidate.catalogId}$yearSuffix';
    }
    final titleKey = normalizeSeriesKey(_stripProviderSuffix(candidate.title));
    if (titleKey.isEmpty) {
      return '';
    }
    final yearSuffix =
        candidate.releaseYear > 0 ? ':${candidate.releaseYear}' : '';
    return '$cachePrefix:title:$titleKey$yearSuffix';
  }

  CandidateVisualCacheEntry _visualCacheEntryForCandidate(
    RemoteSearchCandidate candidate,
  ) {
    return CandidateVisualCacheEntry(
      imageUrl: candidate.imageUrl,
      backgroundUrl: candidate.backgroundUrl,
      logoUrl: candidate.logoUrl,
      trailerUrl: candidate.trailerUrl,
      description: candidate.description,
      rating: candidate.rating,
      japaneseTitle: candidate.japaneseTitle,
      aliases: candidate.aliases,
      cast: candidate.cast,
      cachedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  String _firstCandidateText(
    List<RemoteSearchCandidate> candidates,
    String Function(RemoteSearchCandidate candidate) read,
  ) {
    for (final candidate in candidates) {
      final value = read(candidate).trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  String _longestCandidateText(
    List<RemoteSearchCandidate> candidates,
    String Function(RemoteSearchCandidate candidate) read,
  ) {
    var selected = '';
    for (final candidate in candidates) {
      final value = read(candidate).trim();
      if (value.length > selected.length) {
        selected = value;
      }
    }
    return selected;
  }

  int _firstPositiveCandidateInt(
    List<RemoteSearchCandidate> candidates,
    int Function(RemoteSearchCandidate candidate) read,
  ) {
    for (final candidate in candidates) {
      final value = read(candidate);
      if (value > 0) {
        return value;
      }
    }
    return 0;
  }

  List<T> _longestCandidateList<T>(
    List<RemoteSearchCandidate> candidates,
    List<T> Function(RemoteSearchCandidate candidate) read,
  ) {
    List<T> selected = <T>[];
    for (final candidate in candidates) {
      final value = read(candidate);
      if (value.length > selected.length) {
        selected = value;
      }
    }
    return selected;
  }

  Future<void> removeRemoteSeries(SeriesItem series) async {
    if (!series.isRemote) {
      return;
    }
    final key = series.stableKey;
    final remoteLibrary =
        _state.remoteLibrary.where((entry) => entry.stableKey != key).toList();
    final playlist = activePlaylist.copyWith(
      selectedSeries: {...activePlaylist.selectedSeries}..remove(key),
      progress: {...activePlaylist.progress}..remove(key),
    );
    _state = _state.copyWith(
      remoteLibrary: remoteLibrary,
      profile: _replaceActivePlaylist(playlist),
    );
    await _save();
    notifyListeners();
  }

  Future<void> toggleSeriesSelection(SeriesItem series) async {
    final selected = {...activePlaylist.selectedSeries};
    if (selected.contains(series.stableKey)) {
      selected.remove(series.stableKey);
    } else {
      selected.add(series.stableKey);
    }
    final playlist = activePlaylist.copyWith(selectedSeries: selected);
    _state = _state.copyWith(profile: _replaceActivePlaylist(playlist));
    await _save();
    notifyListeners();
  }

  Future<void> setCurrentEntry(EpisodeItem episode) async {
    _state = _state.copyWith(
      profile: _state.profile.copyWith(currentEntry: episode),
    );
    await _save();
    notifyListeners();
  }

  Future<void> clearCurrentEntry() async {
    _state = _state.copyWith(
      profile: _state.profile.copyWith(clearCurrentEntry: true),
    );
    await _save();
    notifyListeners();
  }

  Future<void> setVideoScaleModeForEpisode(
    EpisodeItem episode,
    VideoScaleMode mode,
  ) async {
    await _updateSeriesPlaybackPreference(
      episode,
      (current) => current.copyWith(videoScaleMode: mode.id),
      'Vista de video: ${mode.dialogLabel}.',
    );
  }

  Future<void> setPlaybackProviderForEpisode(
    EpisodeItem episode,
    RemoteProvider? provider,
  ) async {
    final normalized =
        provider == null || !canUsePlaybackProviderForEpisode(episode, provider)
            ? null
            : provider;
    await _updateSeriesPlaybackPreference(
      episode,
      (current) => current.copyWith(
        provider: normalized,
        clearProvider: normalized == null,
      ),
      normalized == null
          ? 'Fuente automatica para esta serie.'
          : 'Fuente de la serie: ${normalized.label}.',
    );
  }

  bool _isDisabledRemoteProvider(RemoteProvider? provider) {
    return provider == RemoteProvider.animeKai ||
        provider == RemoteProvider.animeFlv;
  }

  bool _isSelectablePreferredRemoteProvider(RemoteProvider? provider) {
    return provider == RemoteProvider.animeAv1 ||
        provider == RemoteProvider.jkAnime ||
        provider == RemoteProvider.latAnime;
  }

  Future<void> setAnimeAv1ModeForEpisode(
    EpisodeItem episode,
    AnimeAv1PlaybackMode mode,
  ) async {
    await _updateSeriesPlaybackPreference(
      episode,
      (current) => current.copyWith(animeAv1Mode: mode.id),
      'AnimeAV1: ${mode.dialogLabel}.',
    );
  }

  Future<void> setJkAnimeServerForEpisode(
    EpisodeItem episode,
    JkAnimeServerPreference server,
  ) async {
    await _updateSeriesPlaybackPreference(
      episode,
      (current) => current.copyWith(jkAnimeServer: server.id),
      'JKAnime: ${server.label}.',
    );
  }

  Future<void> setFacebookModeForEpisode(
    EpisodeItem episode,
    FacebookPlaybackMode mode,
  ) async {
    await _updateSeriesPlaybackPreference(
      episode,
      (current) => current.copyWith(facebookMode: mode.id),
      'Facebook: ${mode.dialogLabel}.',
    );
  }

  Future<void> setFacebookOptionForEpisode(
    EpisodeItem episode,
    FacebookPlaybackOption option,
  ) async {
    await _updateSeriesPlaybackPreference(
      episode,
      (current) => current.copyWith(facebookOption: option.id),
      'Facebook: ${option.label}.',
    );
  }

  Future<void> _updateSeriesPlaybackPreference(
    EpisodeItem episode,
    SeriesPlaybackPreference Function(SeriesPlaybackPreference current) update,
    String status,
  ) async {
    final key = normalizeSeriesKey(episode.seriesName);
    if (key.isEmpty) {
      return;
    }
    final preferences = Map<String, SeriesPlaybackPreference>.from(
      _state.profile.seriesPlaybackPreferences,
    );
    final current = preferences[key] ?? const SeriesPlaybackPreference();
    final next = update(current);
    if (next.isMeaningful) {
      preferences[key] = next;
    } else {
      preferences.remove(key);
    }
    _state = _state.copyWith(
      profile: _state.profile.copyWith(seriesPlaybackPreferences: preferences),
    );
    await _save();
    _statusMessage = status;
    notifyListeners();
  }

  Future<void> markEpisodePlayed(EpisodeItem episode) async {
    final existing = playbackForEpisode(episode);
    await saveEpisodePlayback(
      episode,
      position: Duration(milliseconds: existing?.positionMs ?? 0),
      duration: Duration(milliseconds: existing?.durationMs ?? 0),
      completed: true,
    );
  }

  Future<void> saveEpisodePlayback(
    EpisodeItem episode, {
    required Duration position,
    required Duration duration,
    bool completed = false,
  }) async {
    final aliases = _expandedEpisodePlaybackAliases(episode);
    if (aliases.isEmpty) {
      return;
    }

    final existing = _firstPlaybackRecord(aliases);
    final positionMs = position.inMilliseconds;
    final durationMs = duration.inMilliseconds;
    final normalizedDuration = [
      durationMs,
      existing?.durationMs ?? 0,
      0,
    ].reduce((left, right) => left > right ? left : right);
    final normalizedPosition = switch (completed) {
      true when normalizedDuration > 0 => normalizedDuration,
      true => [
          positionMs,
          existing?.positionMs ?? 0,
          1,
        ].reduce((left, right) => left > right ? left : right),
      false => positionMs < 0 ? 0 : positionMs,
    };
    final record = EpisodePlaybackRecord.normalized(
      positionMs: normalizedPosition,
      durationMs: normalizedDuration,
      completed: completed || existing?.completed == true,
    );
    final nextPlayback = Map<String, EpisodePlaybackRecord>.from(
      _state.profile.episodePlayback,
    );
    for (final key in aliases) {
      nextPlayback[key] = record;
    }

    var profile = _state.profile.copyWith(
      episodePlayback: nextPlayback,
      currentEntry: episode,
    );
    if (record.completed) {
      profile = _profileWithPlayedEpisode(profile, episode);
    }
    _state = _state.copyWith(profile: profile);
    await _save();
    notifyListeners();
    if (record.completed) {
      unawaited(_syncCompletedEpisodeExternal(episode));
    }
  }

  Future<bool> sendSimklScrobble(
    EpisodeItem episode, {
    required Duration position,
    required Duration duration,
    required String action,
  }) async {
    if (!_state.profile.simklAuth.isConnected || duration <= Duration.zero) {
      return false;
    }
    final clientId = _simklService.resolveClientId(_state.simklClientId);
    if (clientId.isEmpty) {
      return false;
    }
    final update = _buildSimklScrobbleUpdate(
      episode,
      progressPercent: (position.inMilliseconds / duration.inMilliseconds * 100)
          .clamp(0, 100)
          .toDouble(),
    );
    if (update == null) {
      return false;
    }
    try {
      await _simklService.scrobbleEpisode(
        accessToken: _state.profile.simklAuth.accessToken,
        clientId: clientId,
        action: action,
        update: update,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> resetProgress(SeriesItem series) async {
    final progress = {...activePlaylist.progress}..remove(series.stableKey);
    final playlist = activePlaylist.copyWith(progress: progress);
    _state = _state.copyWith(profile: _replaceActivePlaylist(playlist));
    await _save();
    notifyListeners();
  }

  Future<void> _syncCompletedEpisodeExternal(EpisodeItem episode) async {
    final key = _seriesStateKeyForEpisode(episode);
    if (key.isEmpty) {
      return;
    }
    final malAuth = _state.profile.myAnimeListAuth;
    if (malAuth.isConnected) {
      try {
        final updates = _buildMyAnimeListLocalUpdates(
          _state,
        ).where((update) => update.seriesKey == key).toList();
        if (updates.isNotEmpty) {
          final result = await _myAnimeListService.pushLocalAnimeState(
            accessToken: malAuth.accessToken,
            updates: updates,
          );
          if (result.mappings.isNotEmpty) {
            _state = _state.copyWith(
              profile: _state.profile.copyWith(
                myAnimeListMappings: {
                  ..._state.profile.myAnimeListMappings,
                  ...result.mappings,
                },
              ),
            );
            await _save();
          }
        }
      } catch (_) {
        // La reproduccion no debe fallar si una sincronizacion externa falla.
      }
    }

    final simklAuth = _state.profile.simklAuth;
    if (simklAuth.isConnected) {
      try {
        final clientId = _simklService.resolveClientId(_state.simklClientId);
        if (clientId.isEmpty) {
          return;
        }
        final updates = _buildSimklLocalUpdates(
          _state,
        ).where((update) => update.seriesKey == key).toList();
        if (updates.isNotEmpty) {
          await _simklService.pushLocalAnimeState(
            accessToken: simklAuth.accessToken,
            clientId: clientId,
            updates: updates,
          );
        }
      } catch (_) {
        // La reproduccion no debe fallar si una sincronizacion externa falla.
      }
    }
  }

  Future<void> setBooleanSetting({
    bool? showSeriesUpcomingCards,
    bool? showPlaylistUpcomingCards,
    bool? skipMixedEpisodes,
    bool? skipFillerEpisodes,
  }) async {
    _state = _state.copyWith(
      showSeriesUpcomingCards: showSeriesUpcomingCards,
      showPlaylistUpcomingCards: showPlaylistUpcomingCards,
      skipMixedEpisodes: skipMixedEpisodes,
      skipFillerEpisodes: skipFillerEpisodes,
    );
    await _save();
    notifyListeners();
    if (skipFillerEpisodes == true || skipMixedEpisodes == true) {
      unawaited(refreshFillerMetadata());
    }
  }

  Future<void> refreshFillerMetadata({bool force = false}) async {
    if (_isRefreshingFillerMetadata) {
      return;
    }
    final targetSeries =
        library.where((series) => series.episodes.isNotEmpty).toList();
    if (targetSeries.isEmpty) {
      _statusMessage = 'No hay series para consultar metadata de relleno.';
      notifyListeners();
      return;
    }

    _isRefreshingFillerMetadata = true;
    _statusMessage = 'Actualizando metadata de relleno...';
    notifyListeners();

    var found = 0;
    var misses = 0;
    final nextCache = Map<String, FillerMetadataRecord>.from(
      _state.fillerCache,
    );
    try {
      for (final series in targetSeries) {
        final keys = _fillerCacheKeysForSeries(series);
        if (!force && keys.every(nextCache.containsKey)) {
          continue;
        }

        final record = await _fillerMetadata.resolveFillerMetadata(
          _fillerAliasesForSeries(series),
        );
        final normalizedRecord = record.found
            ? record
            : const FillerMetadataRecord(status: 'missing');
        if (normalizedRecord.found) {
          found += 1;
        } else {
          misses += 1;
        }
        for (final key in keys) {
          nextCache[key] = normalizedRecord;
        }
      }

      _state = _state.copyWith(
        fillerCache: nextCache,
        remoteLibrary: _applyFillerCacheToLibrary(
          _state.remoteLibrary,
          cache: nextCache,
        ),
      );
      _localLibrary = _applyFillerCacheToLibrary(
        _localLibrary,
        cache: nextCache,
      );
      await _save();
      _statusMessage = found > 0
          ? 'Metadata de relleno actualizada: $found series con datos.'
          : misses > 0
              ? 'No se encontraron nuevos datos de relleno.'
              : 'Metadata de relleno ya estaba actualizada.';
    } catch (error) {
      _statusMessage = 'No se pudo actualizar relleno: $error';
    } finally {
      _isRefreshingFillerMetadata = false;
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(SeriesItem series) async {
    final favorites = {..._state.profile.favoriteSeries};
    if (favorites.contains(series.stableKey)) {
      favorites.remove(series.stableKey);
    } else {
      favorites.add(series.stableKey);
    }
    _state = _state.copyWith(
      profile: _state.profile.copyWith(favoriteSeries: favorites),
    );
    await _save();
    notifyListeners();
  }

  Future<void> setSpaceStatus(SeriesItem series, String statusKey) async {
    var profile = _state.profile;
    final key = series.stableKey;
    profile = profile.copyWith(
      watchlistSeries: {...profile.watchlistSeries}..remove(key),
      watchingSeries: {...profile.watchingSeries}..remove(key),
      abandonedSeries: {...profile.abandonedSeries}..remove(key),
      completedSeries: {...profile.completedSeries}..remove(key),
    );

    switch (statusKey) {
      case 'want_to_watch':
        profile = profile.copyWith(
          watchlistSeries: {...profile.watchlistSeries, key},
        );
        break;
      case 'watching':
        profile = profile.copyWith(
          watchingSeries: {...profile.watchingSeries, key},
        );
        break;
      case 'abandoned':
        profile = profile.copyWith(
          abandonedSeries: {...profile.abandonedSeries, key},
        );
        break;
      case 'completed':
        profile = profile.copyWith(
          completedSeries: {...profile.completedSeries, key},
        );
        break;
    }

    _state = _state.copyWith(profile: profile);
    await _save();
    notifyListeners();
  }

  Future<void> stopWatchingSeries(SeriesItem series) async {
    final key = series.stableKey;
    final profile = _state.profile;
    final nextPlayback = Map<String, EpisodePlaybackRecord>.from(
      profile.episodePlayback,
    );
    for (final episode in series.episodes) {
      for (final alias in _episodePlaybackAliases(episode)) {
        nextPlayback.remove(alias);
      }
    }
    final currentEntry = profile.currentEntry;
    final clearCurrent = currentEntry != null &&
        (currentEntry.seriesStateKey == key ||
            normalizeSeriesKey(currentEntry.seriesName) ==
                normalizeSeriesKey(series.name));
    final playlistProgress = {...profile.activePlaylist.progress}..remove(key);
    final playlist = profile.activePlaylist.copyWith(
      progress: playlistProgress,
      lastPlayedSeriesName: profile.activePlaylist.lastPlayedSeriesName == key
          ? ''
          : profile.activePlaylist.lastPlayedSeriesName,
    );
    final profileWithPlaylist = _replaceActivePlaylistForProfile(
      profile,
      playlist,
    );
    _state = _state.copyWith(
      profile: profileWithPlaylist.copyWith(
        watchlistSeries: {...profile.watchlistSeries}..remove(key),
        watchingSeries: {...profile.watchingSeries}..remove(key),
        abandonedSeries: {...profile.abandonedSeries}..remove(key),
        completedSeries: {...profile.completedSeries}..remove(key),
        episodePlayback: nextPlayback,
        currentEntry: clearCurrent ? null : currentEntry,
        clearCurrentEntry: clearCurrent,
      ),
    );
    _statusMessage = '${series.name} salio de Continuar viendo.';
    await _save();
    notifyListeners();
  }

  List<MyAnimeListLocalAnimeUpdate> _buildMyAnimeListLocalUpdates(
    AppState state,
  ) {
    final profile = state.profile;
    final seriesByKey = {
      for (final series in [..._localLibrary, ...state.remoteLibrary])
        series.stableKey: series,
    };
    final keys = <String>{
      ...profile.favoriteSeries,
      ...profile.watchlistSeries,
      ...profile.watchingSeries,
      ...profile.abandonedSeries,
      ...profile.completedSeries,
      ...profile.activePlaylist.progress.keys,
      ...profile.myAnimeListMappings.keys,
      if (profile.currentEntry != null)
        _seriesStateKeyForEpisode(profile.currentEntry!),
    }..removeWhere((key) => key.trim().isEmpty);

    final updates = <MyAnimeListLocalAnimeUpdate>[];
    for (final key in keys) {
      final series = seriesByKey[key] ?? _findSeriesByKeyFallback(key);
      final title = series?.name ??
          (profile.currentEntry != null &&
                  _seriesStateKeyForEpisode(profile.currentEntry!) == key
              ? profile.currentEntry!.seriesName
              : key);
      final watched = _watchedEpisodesForSeriesKey(profile, key, series);
      final listStatus = _myAnimeListListStatusForKey(
        profile,
        key,
        watched,
        series,
      );
      final favorite = profile.favoriteSeries.contains(key);
      if (!favorite && listStatus.isEmpty && watched <= 0) {
        continue;
      }
      final catalogId = series?.catalogId ?? 0;
      updates.add(
        MyAnimeListLocalAnimeUpdate(
          seriesKey: key,
          title: title,
          malId: profile.myAnimeListMappings[key] ??
              (catalogId > 0 ? catalogId : _catalogIdFromSeriesKey(key)),
          imageUrl: series?.imageUrl ?? '',
          aliases: series?.aliases ?? const [],
          japaneseTitle: series?.japaneseTitle ?? '',
          year: series?.releaseYear ?? 0,
          format: series?.format ?? '',
          episodeCount: series?.episodeCount ?? 0,
          watchedEpisodes: watched,
          favorite: favorite,
          listStatus: listStatus,
        ),
      );
    }
    return updates;
  }

  List<SimklLocalAnimeUpdate> _buildSimklLocalUpdates(AppState state) {
    final profile = state.profile;
    final seriesByKey = {
      for (final series in [..._localLibrary, ...state.remoteLibrary])
        series.stableKey: series,
    };
    final keys = <String>{
      ...profile.watchlistSeries,
      ...profile.watchingSeries,
      ...profile.abandonedSeries,
      ...profile.completedSeries,
      ...profile.activePlaylist.progress.keys,
      ...profile.simklMappings.keys,
      if (profile.currentEntry != null)
        _seriesStateKeyForEpisode(profile.currentEntry!),
    }..removeWhere((key) => key.trim().isEmpty);

    final updates = <SimklLocalAnimeUpdate>[];
    for (final key in keys) {
      final series = seriesByKey[key] ?? _findSeriesByKeyFallback(key);
      final title = series?.name ??
          (profile.currentEntry != null &&
                  _seriesStateKeyForEpisode(profile.currentEntry!) == key
              ? profile.currentEntry!.seriesName
              : key);
      final watched = _watchedEpisodesForSeriesKey(profile, key, series);
      final listStatus = _simklListStatusForKey(profile, key, watched, series);
      if (listStatus.isEmpty && watched <= 0) {
        continue;
      }
      final catalogId = series?.catalogId ?? 0;
      updates.add(
        SimklLocalAnimeUpdate(
          seriesKey: key,
          title: title,
          simklId: profile.simklMappings[key] ?? _simklIdFromSeriesKey(key),
          malId: catalogId > 0 ? catalogId : _catalogIdFromSeriesKey(key),
          year: series?.releaseYear ?? 0,
          listStatus: listStatus,
          watchedEpisodes: watched,
          episodeCount: series?.episodeCount ?? 0,
        ),
      );
    }
    return updates;
  }

  SimklEpisodeScrobbleUpdate? _buildSimklScrobbleUpdate(
    EpisodeItem episode, {
    required double progressPercent,
  }) {
    final key = _seriesStateKeyForEpisode(episode);
    if (key.isEmpty || episode.episodeNumber <= 0) {
      return null;
    }
    final series = _findSeriesByKeyFallback(key);
    final title = series?.name ?? episode.seriesName;
    if (title.trim().isEmpty) {
      return null;
    }
    final catalogId = series?.catalogId ?? 0;
    return SimklEpisodeScrobbleUpdate(
      seriesKey: key,
      title: title,
      episodeNumber: episode.episodeNumber,
      progressPercent: progressPercent,
      simklId: _state.profile.simklMappings[key] ?? _simklIdFromSeriesKey(key),
      malId: catalogId > 0 ? catalogId : _catalogIdFromSeriesKey(key),
      year: series?.releaseYear ?? episode.releaseYear,
    );
  }

  SeriesItem? _findSeriesByKeyFallback(String key) {
    final normalized = normalizeSeriesKey(key);
    for (final series in library) {
      if (series.stableKey == key ||
          normalizeSeriesKey(series.name) == normalized) {
        return series;
      }
    }
    return null;
  }

  int _watchedEpisodesForSeriesKey(
    UserProfileState profile,
    String key,
    SeriesItem? series,
  ) {
    final progress = [
      profile.activePlaylist.progress[key] ?? 0,
      if (series != null) profile.activePlaylist.progress[series.name] ?? 0,
    ].reduce(max);
    final playback = profile.episodePlayback.entries
        .where(
          (entry) => entry.value.completed && entry.key.startsWith('$key|'),
        )
        .map((entry) => int.tryParse(entry.key.split('|').last) ?? 0)
        .fold<int>(0, max);
    return max(progress, playback);
  }

  String _myAnimeListListStatusForKey(
    UserProfileState profile,
    String key,
    int watchedEpisodes,
    SeriesItem? series,
  ) {
    if (profile.completedSeries.contains(key)) {
      return 'completed';
    }
    if (profile.abandonedSeries.contains(key)) {
      return 'dropped';
    }
    if (profile.watchingSeries.contains(key)) {
      return 'watching';
    }
    if (profile.watchlistSeries.contains(key)) {
      return 'plan_to_watch';
    }
    final episodeCount = series?.episodeCount ?? 0;
    if (watchedEpisodes > 0 &&
        episodeCount > 0 &&
        watchedEpisodes >= episodeCount) {
      return 'completed';
    }
    if (watchedEpisodes > 0) {
      return 'watching';
    }
    return '';
  }

  String _simklListStatusForKey(
    UserProfileState profile,
    String key,
    int watchedEpisodes,
    SeriesItem? series,
  ) {
    if (profile.completedSeries.contains(key)) {
      return 'completed';
    }
    if (profile.abandonedSeries.contains(key)) {
      return 'dropped';
    }
    if (profile.watchingSeries.contains(key)) {
      return 'watching';
    }
    if (profile.watchlistSeries.contains(key)) {
      return 'plantowatch';
    }
    final episodeCount = series?.episodeCount ?? 0;
    if (watchedEpisodes > 0 &&
        episodeCount > 0 &&
        watchedEpisodes >= episodeCount) {
      return 'completed';
    }
    if (watchedEpisodes > 0) {
      return 'watching';
    }
    return '';
  }

  int _catalogIdFromSeriesKey(String key) {
    return int.tryParse(
          RegExp(
                r'^catalog:(\d+)$',
                caseSensitive: false,
              ).firstMatch(key.trim())?.group(1) ??
              '',
        ) ??
        0;
  }

  int _simklIdFromSeriesKey(String key) {
    return int.tryParse(
          RegExp(
                r'^simkl:(\d+)$',
                caseSensitive: false,
              ).firstMatch(key.trim())?.group(1) ??
              '',
        ) ??
        0;
  }

  AppState _applyMyAnimeListRemoteEntries(
    AppState state,
    List<MyAnimeListRemoteAnimeEntry> entries,
  ) {
    if (entries.isEmpty) {
      return state;
    }
    var profile = state.profile;
    final keyedEntries = <String, MyAnimeListRemoteAnimeEntry>{};
    for (final entry in entries) {
      final key = _myAnimeListSeriesKeyForEntry(state, profile, entry);
      if (key.isNotEmpty) {
        keyedEntries[key] = entry;
      }
    }
    if (keyedEntries.isEmpty) {
      return state;
    }

    final incomingKeys = keyedEntries.keys.toSet();
    var nextFavorites = {...profile.favoriteSeries}
      ..removeWhere(incomingKeys.contains);
    var nextWatchlist = {...profile.watchlistSeries}
      ..removeWhere(incomingKeys.contains);
    var nextWatching = {...profile.watchingSeries}
      ..removeWhere(incomingKeys.contains);
    var nextAbandoned = {...profile.abandonedSeries}
      ..removeWhere(incomingKeys.contains);
    var nextCompleted = {...profile.completedSeries}
      ..removeWhere(incomingKeys.contains);
    final nextMappings = {...profile.myAnimeListMappings};
    final nextProgress = {...profile.activePlaylist.progress};

    for (final entry in keyedEntries.entries) {
      final seriesKey = entry.key;
      final remote = entry.value;
      if (remote.malId > 0) {
        nextMappings[seriesKey] = remote.malId;
      }
      if (remote.status.tags.any(
        (tag) => tag.trim().toLowerCase() == MyAnimeListService.favoriteTag,
      )) {
        nextFavorites.add(seriesKey);
      }
      switch (_spaceStatusFromMyAnimeList(remote.status)) {
        case 'want_to_watch':
          nextWatchlist.add(seriesKey);
          break;
        case 'watching':
          nextWatching.add(seriesKey);
          break;
        case 'abandoned':
          nextAbandoned.add(seriesKey);
          break;
        case 'completed':
          nextCompleted.add(seriesKey);
          break;
      }
      if (remote.status.watchedEpisodes > 0) {
        nextProgress[seriesKey] = remote.status.watchedEpisodes;
      }
    }

    final nextPlaylist = profile.activePlaylist.copyWith(
      progress: nextProgress,
    );
    profile = _replaceActivePlaylistForProfile(profile, nextPlaylist).copyWith(
      favoriteSeries: nextFavorites,
      watchlistSeries: nextWatchlist,
      watchingSeries: nextWatching,
      abandonedSeries: nextAbandoned,
      completedSeries: nextCompleted,
      myAnimeListMappings: nextMappings,
    );

    final placeholders = keyedEntries.entries
        .map((entry) => _myAnimeListPlaceholderSeries(entry.key, entry.value))
        .toList();
    return state.copyWith(
      remoteLibrary: _mergeRemoteLibraryByKey(
        state.remoteLibrary,
        placeholders,
      ),
      profile: profile,
    );
  }

  String _myAnimeListSeriesKeyForEntry(
    AppState state,
    UserProfileState profile,
    MyAnimeListRemoteAnimeEntry entry,
  ) {
    if (entry.malId > 0) {
      for (final item in profile.myAnimeListMappings.entries) {
        if (item.value == entry.malId && item.key.isNotEmpty) {
          return item.key;
        }
      }
      for (final series in state.remoteLibrary) {
        if (series.catalogId == entry.malId && series.stableKey.isNotEmpty) {
          return series.stableKey;
        }
      }
    }
    final normalizedTitle = normalizeSeriesKey(entry.title);
    if (normalizedTitle.isNotEmpty) {
      for (final series in state.remoteLibrary) {
        final yearMatches = entry.year <= 0 ||
            series.releaseYear <= 0 ||
            (series.releaseYear - entry.year).abs() <= 1;
        if (normalizeSeriesKey(series.name) == normalizedTitle &&
            yearMatches &&
            series.stableKey.isNotEmpty) {
          return series.stableKey;
        }
      }
    }
    if (entry.malId > 0) {
      return 'catalog:${entry.malId}';
    }
    return normalizedTitle;
  }

  SeriesItem _myAnimeListPlaceholderSeries(
    String seriesKey,
    MyAnimeListRemoteAnimeEntry entry,
  ) {
    final movieLike = entry.mediaType.toLowerCase().contains('movie') ||
        entry.mediaType.toLowerCase().contains('pelicula');
    final count = [
      entry.episodeCount,
      entry.status.watchedEpisodes,
      movieLike ? 1 : 0,
      1,
    ].reduce(max);
    final title = entry.title.trim().isEmpty
        ? 'MyAnimeList ${entry.malId > 0 ? entry.malId : seriesKey}'
        : entry.title.trim();
    final episodes = List.generate(count, (index) {
      final episodeNumber = index + 1;
      return EpisodeItem(
        seriesName: title,
        seriesStateKey: seriesKey,
        episodeIndex: index,
        episodeNumber: episodeNumber,
        displayName: movieLike ? title : '$title - Capitulo $episodeNumber',
        relativePath: movieLike
            ? 'MyAnimeList / Pelicula'
            : 'MyAnimeList / Capitulo $episodeNumber',
        filePath: '',
        sourceType: SourceType.remote,
        slug: entry.malId > 0 ? '${entry.malId}' : '',
        releaseYear: entry.year,
        imageUrl: entry.imageUrl,
      );
    });
    return SeriesItem(
      name: title,
      seriesStateKey: seriesKey,
      sourceType: SourceType.remote,
      slug: entry.malId > 0 ? '${entry.malId}' : '',
      episodeCount: episodes.length,
      imageUrl: entry.imageUrl,
      episodes: episodes,
      releaseYear: entry.year,
      format: _myAnimeListFormatLabel(entry.mediaType),
      catalogId: entry.malId,
      japaneseTitle: entry.japaneseTitle,
      aliases: entry.aliases,
    );
  }

  AppState _applySimklRemoteEntries(
    AppState state,
    List<SimklRemoteAnimeEntry> entries,
  ) {
    if (entries.isEmpty) {
      return state;
    }
    var profile = state.profile;
    final keyedEntries = <String, SimklRemoteAnimeEntry>{};
    for (final entry in entries) {
      final key = _simklSeriesKeyForEntry(state, profile, entry);
      if (key.isNotEmpty) {
        keyedEntries[key] = entry;
      }
    }
    if (keyedEntries.isEmpty) {
      return state;
    }

    final incomingKeys = keyedEntries.keys.toSet();
    var nextWatchlist = {...profile.watchlistSeries}
      ..removeWhere(incomingKeys.contains);
    var nextWatching = {...profile.watchingSeries}
      ..removeWhere(incomingKeys.contains);
    var nextAbandoned = {...profile.abandonedSeries}
      ..removeWhere(incomingKeys.contains);
    var nextCompleted = {...profile.completedSeries}
      ..removeWhere(incomingKeys.contains);
    final nextMappings = {...profile.simklMappings};
    final nextProgress = {...profile.activePlaylist.progress};

    for (final entry in keyedEntries.entries) {
      final seriesKey = entry.key;
      final remote = entry.value;
      if (remote.simklId > 0) {
        nextMappings[seriesKey] = remote.simklId;
      }
      switch (_spaceStatusFromSimkl(remote.status, remote.watchedEpisodes)) {
        case 'want_to_watch':
          nextWatchlist.add(seriesKey);
          break;
        case 'watching':
          nextWatching.add(seriesKey);
          break;
        case 'abandoned':
          nextAbandoned.add(seriesKey);
          break;
        case 'completed':
          nextCompleted.add(seriesKey);
          break;
      }
      if (remote.watchedEpisodes > 0) {
        nextProgress[seriesKey] = remote.watchedEpisodes;
      }
    }

    final nextPlaylist = profile.activePlaylist.copyWith(
      progress: nextProgress,
    );
    profile = _replaceActivePlaylistForProfile(profile, nextPlaylist).copyWith(
      watchlistSeries: nextWatchlist,
      watchingSeries: nextWatching,
      abandonedSeries: nextAbandoned,
      completedSeries: nextCompleted,
      simklMappings: nextMappings,
    );

    final placeholders = keyedEntries.entries
        .map((entry) => _simklPlaceholderSeries(entry.key, entry.value))
        .toList();
    return state.copyWith(
      remoteLibrary: _mergeRemoteLibraryByKey(
        state.remoteLibrary,
        placeholders,
      ),
      profile: profile,
    );
  }

  ({AppState state, int appliedCount}) _applySimklRemoteEpisodeProgress(
    AppState state,
    List<SimklRemoteEpisodeProgress> entries,
  ) {
    if (entries.isEmpty) {
      return (state: state, appliedCount: 0);
    }
    var profile = state.profile;
    final seriesByKey = {
      for (final series in [..._localLibrary, ...state.remoteLibrary])
        series.stableKey: series,
    };
    final nextPlayback = Map<String, EpisodePlaybackRecord>.from(
      profile.episodePlayback,
    );
    final nextProgress = {...profile.activePlaylist.progress};
    var appliedCount = 0;

    for (final entry in entries) {
      final seriesKey = _simklSeriesKeyForEpisodeProgress(
        state,
        profile,
        entry,
      );
      if (seriesKey.isEmpty || entry.episodeNumber <= 0) {
        continue;
      }
      final progressPercent = entry.progressPercent.clamp(0, 100).toDouble();
      if (progressPercent <= 0) {
        continue;
      }
      final series =
          seriesByKey[seriesKey] ?? _findSeriesByKeyFallback(seriesKey);
      EpisodeItem? episode;
      if (series != null) {
        for (final candidate in series.episodes) {
          if (candidate.episodeNumber == entry.episodeNumber) {
            episode = candidate;
            break;
          }
        }
        episode ??= EpisodeItem(
          seriesName: series.name,
          seriesStateKey: seriesKey,
          episodeIndex: entry.episodeNumber - 1,
          episodeNumber: entry.episodeNumber,
          displayName: '${series.name} - Capitulo ${entry.episodeNumber}',
          relativePath: 'SIMKL / Capitulo ${entry.episodeNumber}',
          filePath: '',
          sourceType: SourceType.remote,
          provider: series.provider,
          slug: series.slug,
          watchUrl: series.watchUrl,
          releaseYear: series.releaseYear,
          imageUrl: series.imageUrl,
        );
      }
      final aliases = episode == null
          ? {'$seriesKey|${entry.episodeNumber}'}
          : _episodePlaybackAliases(episode);
      EpisodePlaybackRecord? existing;
      for (final alias in aliases) {
        existing = nextPlayback[alias];
        if (existing != null) {
          break;
        }
      }
      final durationMs = max(
        existing?.durationMs ?? 0,
        const Duration(minutes: 24).inMilliseconds,
      );
      final remotePositionMs =
          (durationMs * progressPercent / 100).round().clamp(0, durationMs);
      final completed = progressPercent >= 95 || existing?.completed == true;
      final record = EpisodePlaybackRecord.normalized(
        positionMs: completed
            ? durationMs
            : max(remotePositionMs, existing?.positionMs ?? 0),
        durationMs: durationMs,
        completed: completed,
      );
      for (final alias in aliases) {
        nextPlayback[alias] = record;
      }
      if (completed) {
        nextProgress[seriesKey] = max(
          nextProgress[seriesKey] ?? 0,
          entry.episodeNumber,
        );
      }
      appliedCount += 1;
    }

    if (appliedCount <= 0) {
      return (state: state, appliedCount: 0);
    }
    final nextPlaylist = profile.activePlaylist.copyWith(
      progress: nextProgress,
    );
    profile = _replaceActivePlaylistForProfile(
      profile,
      nextPlaylist,
    ).copyWith(episodePlayback: nextPlayback);
    return (
      state: state.copyWith(profile: profile),
      appliedCount: appliedCount,
    );
  }

  String _simklSeriesKeyForEpisodeProgress(
    AppState state,
    UserProfileState profile,
    SimklRemoteEpisodeProgress entry,
  ) {
    if (entry.simklId > 0) {
      for (final mapping in profile.simklMappings.entries) {
        if (mapping.value == entry.simklId && mapping.key.isNotEmpty) {
          return mapping.key;
        }
      }
    }
    if (entry.malId > 0) {
      for (final series in [..._localLibrary, ...state.remoteLibrary]) {
        if (series.catalogId == entry.malId && series.stableKey.isNotEmpty) {
          return series.stableKey;
        }
      }
      return 'catalog:${entry.malId}';
    }
    final normalizedTitle = normalizeSeriesKey(entry.title);
    if (normalizedTitle.isNotEmpty) {
      for (final series in [..._localLibrary, ...state.remoteLibrary]) {
        final yearMatches = entry.year <= 0 ||
            series.releaseYear <= 0 ||
            (series.releaseYear - entry.year).abs() <= 1;
        if (normalizeSeriesKey(series.name) == normalizedTitle &&
            yearMatches &&
            series.stableKey.isNotEmpty) {
          return series.stableKey;
        }
      }
      return normalizedTitle;
    }
    return '';
  }

  String _simklSeriesKeyForEntry(
    AppState state,
    UserProfileState profile,
    SimklRemoteAnimeEntry entry,
  ) {
    if (entry.simklId > 0) {
      for (final item in profile.simklMappings.entries) {
        if (item.value == entry.simklId && item.key.isNotEmpty) {
          return item.key;
        }
      }
    }
    if (entry.malId > 0) {
      for (final series in state.remoteLibrary) {
        if (series.catalogId == entry.malId && series.stableKey.isNotEmpty) {
          return series.stableKey;
        }
      }
    }
    final normalizedTitle = normalizeSeriesKey(entry.title);
    if (normalizedTitle.isNotEmpty) {
      for (final series in state.remoteLibrary) {
        final yearMatches = entry.year <= 0 ||
            series.releaseYear <= 0 ||
            (series.releaseYear - entry.year).abs() <= 1;
        if (normalizeSeriesKey(series.name) == normalizedTitle &&
            yearMatches &&
            series.stableKey.isNotEmpty) {
          return series.stableKey;
        }
      }
    }
    if (entry.malId > 0) {
      return 'catalog:${entry.malId}';
    }
    if (entry.simklId > 0) {
      return 'simkl:${entry.simklId}';
    }
    return normalizedTitle;
  }

  SeriesItem _simklPlaceholderSeries(
    String seriesKey,
    SimklRemoteAnimeEntry entry,
  ) {
    final movieLike = entry.animeType.toLowerCase().contains('movie') ||
        entry.animeType.toLowerCase().contains('pelicula');
    final count = [
      entry.episodesTotal,
      entry.watchedEpisodes,
      movieLike ? 1 : 0,
      1,
    ].reduce(max);
    final title = entry.title.trim().isEmpty
        ? 'SIMKL ${entry.simklId > 0 ? entry.simklId : seriesKey}'
        : entry.title.trim();
    final episodes = List.generate(count, (index) {
      final episodeNumber = index + 1;
      return EpisodeItem(
        seriesName: title,
        seriesStateKey: seriesKey,
        episodeIndex: index,
        episodeNumber: episodeNumber,
        displayName: movieLike ? title : '$title - Capitulo $episodeNumber',
        relativePath:
            movieLike ? 'SIMKL / Pelicula' : 'SIMKL / Capitulo $episodeNumber',
        filePath: '',
        sourceType: SourceType.remote,
        slug: entry.simklId > 0 ? '${entry.simklId}' : '',
        releaseYear: entry.year,
      );
    });
    return SeriesItem(
      name: title,
      seriesStateKey: seriesKey,
      sourceType: SourceType.remote,
      slug: entry.simklId > 0 ? '${entry.simklId}' : '',
      episodeCount: episodes.length,
      episodes: episodes,
      releaseYear: entry.year,
      format: _simklFormatLabel(entry.animeType),
      catalogId: entry.malId,
    );
  }

  bool _seriesNeedsVisualRefresh(SeriesItem series) {
    if (series.releaseYear > 0) {
      return true;
    }
    if (series.logoUrl.isEmpty || series.backgroundUrl.isEmpty) {
      return true;
    }
    if (series.imageUrl.isEmpty || series.description.isEmpty) {
      return true;
    }
    return series.episodes.any((episode) => episode.imageUrl.isEmpty);
  }

  SeriesItem _mergeSeriesVisuals(SeriesItem current, SeriesItem refreshed) {
    final replaceExistingVisuals = current.releaseYear > 0;
    String mergedVisual(String currentValue, String refreshedValue) {
      if (replaceExistingVisuals && refreshedValue.isNotEmpty) {
        return refreshedValue;
      }
      return currentValue.isNotEmpty ? currentValue : refreshedValue;
    }

    final refreshedByNumber = {
      for (final episode in refreshed.episodes)
        if (episode.episodeNumber > 0) episode.episodeNumber: episode,
    };
    final episodes = current.episodes.map((episode) {
      final visual = refreshedByNumber[episode.episodeNumber];
      if (visual == null) {
        return episode;
      }
      return episode.copyWith(
        displayName: episode.displayName.isNotEmpty
            ? episode.displayName
            : visual.displayName,
        imageUrl: mergedVisual(episode.imageUrl, visual.imageUrl),
        description: episode.description.isNotEmpty
            ? episode.description
            : visual.description,
        airDateIso: episode.airDateIso.isNotEmpty
            ? episode.airDateIso
            : visual.airDateIso,
        durationLabel: episode.durationLabel.isNotEmpty
            ? episode.durationLabel
            : visual.durationLabel,
      );
    }).toList(growable: false);
    return current.copyWith(
      imageUrl: mergedVisual(current.imageUrl, refreshed.imageUrl),
      backgroundUrl:
          mergedVisual(current.backgroundUrl, refreshed.backgroundUrl),
      logoUrl: mergedVisual(current.logoUrl, refreshed.logoUrl),
      trailerUrl: current.trailerUrl.isNotEmpty
          ? current.trailerUrl
          : refreshed.trailerUrl,
      description: current.description.isNotEmpty
          ? current.description
          : refreshed.description,
      rating: current.rating.isNotEmpty ? current.rating : refreshed.rating,
      releaseYear:
          current.releaseYear > 0 ? current.releaseYear : refreshed.releaseYear,
      format: current.format.isNotEmpty ? current.format : refreshed.format,
      catalogId:
          current.catalogId > 0 ? current.catalogId : refreshed.catalogId,
      japaneseTitle: current.japaneseTitle.isNotEmpty
          ? current.japaneseTitle
          : refreshed.japaneseTitle,
      aliases: {...current.aliases, ...refreshed.aliases}.toList(),
      cast: current.cast.isNotEmpty ? current.cast : refreshed.cast,
      episodes: episodes,
    );
  }

  List<SeriesItem> _mergeRemoteLibraryByKey(
    List<SeriesItem> current,
    List<SeriesItem> incoming,
  ) {
    final merged = <String, SeriesItem>{};
    for (final series in [...current, ...incoming]) {
      final key = series.stableKey;
      if (key.isEmpty) {
        continue;
      }
      final existing = merged[key];
      if (existing == null) {
        merged[key] = series;
        continue;
      }
      merged[key] = existing.copyWith(
        episodeCount: max(existing.episodeCount, series.episodeCount),
        episodes:
            existing.episodes.isNotEmpty ? existing.episodes : series.episodes,
        imageUrl:
            existing.imageUrl.isNotEmpty ? existing.imageUrl : series.imageUrl,
        backgroundUrl: existing.backgroundUrl.isNotEmpty
            ? existing.backgroundUrl
            : series.backgroundUrl,
        logoUrl:
            existing.logoUrl.isNotEmpty ? existing.logoUrl : series.logoUrl,
        trailerUrl: existing.trailerUrl.isNotEmpty
            ? existing.trailerUrl
            : series.trailerUrl,
        description: existing.description.isNotEmpty
            ? existing.description
            : series.description,
        rating: existing.rating.isNotEmpty ? existing.rating : series.rating,
        releaseYear: existing.releaseYear > 0
            ? existing.releaseYear
            : series.releaseYear,
        format: existing.format.isNotEmpty ? existing.format : series.format,
        catalogId:
            existing.catalogId > 0 ? existing.catalogId : series.catalogId,
        slug: existing.slug.isNotEmpty ? existing.slug : series.slug,
        japaneseTitle: existing.japaneseTitle.isNotEmpty
            ? existing.japaneseTitle
            : series.japaneseTitle,
        aliases: {...existing.aliases, ...series.aliases}.toList(),
      );
    }
    return merged.values.toList();
  }

  String _spaceStatusFromMyAnimeList(MyAnimeListRemoteStatus status) {
    final hasNoStatusOverride = status.tags.any(
      (tag) =>
          tag.trim().toLowerCase() ==
          MyAnimeListService.syntheticPlanToWatchTag,
    );
    if (hasNoStatusOverride && status.watchedEpisodes <= 0) {
      return '';
    }
    return switch (status.status.trim().toLowerCase()) {
      'completed' => 'completed',
      'dropped' => 'abandoned',
      'watching' => 'watching',
      'on_hold' => status.watchedEpisodes > 0 ? 'watching' : 'want_to_watch',
      'plan_to_watch' => hasNoStatusOverride ? '' : 'want_to_watch',
      _ => status.watchedEpisodes > 0 ? 'watching' : '',
    };
  }

  String _spaceStatusFromSimkl(String status, int watchedEpisodes) {
    return switch (status.trim().toLowerCase()) {
      'plantowatch' || 'plan_to_watch' => 'want_to_watch',
      'watching' => 'watching',
      'hold' => watchedEpisodes > 0 ? 'watching' : 'want_to_watch',
      'dropped' => 'abandoned',
      'completed' => 'completed',
      _ => watchedEpisodes > 0 ? 'watching' : '',
    };
  }

  String _myAnimeListFormatLabel(String value) {
    return switch (value.trim().toLowerCase()) {
      'tv' => 'TV',
      'movie' => 'Movie',
      'ova' => 'OVA',
      'ona' => 'ONA',
      'special' => 'Special',
      _ => value.trim(),
    };
  }

  String _simklFormatLabel(String value) {
    return switch (value.trim().toLowerCase()) {
      'tv' => 'TV',
      'movie' => 'Movie',
      'ova' => 'OVA',
      'ona' => 'ONA',
      'special' => 'Special',
      _ => value.trim(),
    };
  }

  List<EpisodeItem> buildNextEntries({int limit = 12}) {
    return _playlistEngine.buildNextEntries(
      playlist: activePlaylist,
      library: library,
      limit: limit,
      shouldIncludeEpisode: _shouldIncludeEpisode,
    );
  }

  EpisodeItem? firstPlayableEpisode(SeriesItem series) {
    final progress = activePlaylist.progress[series.stableKey] ?? 0;
    if (series.episodes.isEmpty) {
      return null;
    }
    if (progress >= series.episodes.length) {
      return series.episodes.reversed.firstWhere(
        _shouldIncludeEpisode,
        orElse: () => series.episodes.last,
      );
    }
    return series.episodes.skip(progress).firstWhere(
          _shouldIncludeEpisode,
          orElse: () => series.episodes[progress],
        );
  }

  int watchedCountFor(SeriesItem series) {
    return (activePlaylist.progress[series.stableKey] ?? 0)
        .clamp(0, series.episodeCount)
        .toInt();
  }

  bool isSelected(SeriesItem series) {
    return activePlaylist.selectedSeries.contains(series.stableKey);
  }

  bool isFavorite(SeriesItem series) {
    return _state.profile.favoriteSeries.contains(series.stableKey);
  }

  String spaceStatusFor(SeriesItem series) {
    final key = series.stableKey;
    if (_state.profile.watchlistSeries.contains(key)) {
      return 'want_to_watch';
    }
    if (_state.profile.watchingSeries.contains(key)) {
      return 'watching';
    }
    if (_state.profile.abandonedSeries.contains(key)) {
      return 'abandoned';
    }
    if (_state.profile.completedSeries.contains(key)) {
      return 'completed';
    }
    return '';
  }

  SeriesItem? findSeriesForEpisode(EpisodeItem episode) {
    final key = episode.seriesStateKey.isNotEmpty
        ? episode.seriesStateKey
        : normalizeSeriesKey(episode.seriesName);
    for (final series in library) {
      if (series.stableKey == key) {
        return series;
      }
    }
    return null;
  }

  bool _shouldIncludeEpisode(EpisodeItem episode) {
    final tag = _normalizeEpisodeTag(episode.episodeTag);
    if (_state.skipFillerEpisodes && tag == 'filler') {
      return false;
    }
    if (_state.skipMixedEpisodes && tag == 'mixed') {
      return false;
    }
    return true;
  }

  String _normalizeEpisodeTag(String tag) {
    return switch (tag.trim().toLowerCase()) {
      'mixed' || 'mixto' => 'mixed',
      'filler' || 'relleno' => 'filler',
      'canon' => 'canon',
      _ => '',
    };
  }

  List<SeriesItem> _applyFillerCacheToLibrary(
    List<SeriesItem> series, {
    Map<String, FillerMetadataRecord>? cache,
  }) {
    return series
        .map((entry) => _applyFillerCacheToSeries(entry, cache: cache))
        .toList();
  }

  SeriesItem _applyFillerCacheToSeries(
    SeriesItem series, {
    Map<String, FillerMetadataRecord>? cache,
  }) {
    final filler = _cachedFillerForSeries(series, cache: cache);
    if (filler == null || filler.episodeMap.isEmpty) {
      return series;
    }
    var changed = false;
    final episodes = series.episodes.map((episode) {
      final tag = filler.episodeMap['${episode.episodeNumber}'] ?? '';
      if (tag.isEmpty || episode.episodeTag == tag) {
        return episode;
      }
      changed = true;
      return episode.copyWith(episodeTag: tag);
    }).toList();
    return changed ? series.copyWith(episodes: episodes) : series;
  }

  FillerMetadataRecord? _cachedFillerForSeries(
    SeriesItem series, {
    Map<String, FillerMetadataRecord>? cache,
  }) {
    final source = cache ?? _state.fillerCache;
    for (final key in _fillerCacheKeysForSeries(series)) {
      final record = source[key];
      if (record != null) {
        return record;
      }
    }
    return null;
  }

  List<String> _fillerAliasesForSeries(SeriesItem series) {
    return {
      series.name,
      _stripProviderSuffix(series.name),
      series.japaneseTitle,
      ...series.aliases,
    }.map((entry) => entry.trim()).where((entry) => entry.isNotEmpty).toList();
  }

  List<String> _fillerCacheKeysForSeries(SeriesItem series) {
    return _fillerAliasesForSeries(series)
        .map(normalizeSeriesKey)
        .where((entry) => entry.isNotEmpty)
        .toSet()
        .toList();
  }

  String _stripProviderSuffix(String value) {
    return value
        .replaceAll(
          RegExp(
            r'\s*\((AnimeAV1|AnimeKai|JKAnime|LatAnime|AnimeFLV|Facebook|Catalogo)(\s+\d+)?\)\s*$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  String _createProfileId(String name, Set<String> existingIds) {
    final normalizedName = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('(^-+|-+\$)'), '');
    final base = normalizedName.isEmpty ? 'perfil' : normalizedName;
    var candidate = base;
    var index = 2;
    while (existingIds.contains(candidate)) {
      candidate = '$base-$index';
      index += 1;
    }
    return candidate;
  }

  String _nextAvatarPresetId(Iterable<String> usedAvatarPresetIds) {
    const presets = ['sunrise', 'lagoon', 'mint', 'ember', 'sky', 'dusk'];
    final used = usedAvatarPresetIds.map((id) => id.trim()).toSet();
    return presets.firstWhere(
      (id) => !used.contains(id),
      orElse: () => presets[used.length % presets.length],
    );
  }

  UserProfileState _replaceActivePlaylist(PlaylistState playlist) {
    return _replaceActivePlaylistForProfile(_state.profile, playlist);
  }

  UserProfileState _replaceActivePlaylistForProfile(
    UserProfileState profile,
    PlaylistState playlist,
  ) {
    final activeId = profile.activePlaylist.id;
    return profile.copyWith(
      playlists: profile.playlists.map((entry) {
        return entry.id == activeId ? playlist : entry;
      }).toList(),
    );
  }

  UserProfileState _profileWithPlayedEpisode(
    UserProfileState profile,
    EpisodeItem episode,
  ) {
    final key = _seriesStateKeyForEpisode(episode);
    final nextProgress = {...profile.activePlaylist.progress};
    final current = nextProgress[key] ?? 0;
    if (episode.episodeIndex + 1 > current) {
      nextProgress[key] = episode.episodeIndex + 1;
    }
    final playlist = profile.activePlaylist.copyWith(
      progress: nextProgress,
      lastPlayedSeriesName: key,
    );
    final nextWatchlist = {...profile.watchlistSeries}..remove(key);
    final nextWatching = {...profile.watchingSeries};
    if (key.isNotEmpty &&
        !profile.completedSeries.contains(key) &&
        !profile.abandonedSeries.contains(key)) {
      nextWatching.add(key);
    } else {
      nextWatching.remove(key);
    }
    return _replaceActivePlaylistForProfile(profile, playlist).copyWith(
      watchlistSeries: nextWatchlist,
      watchingSeries: nextWatching,
      currentEntry: episode,
    );
  }

  Set<String> _episodePlaybackAliases(EpisodeItem episode) {
    return {
      _episodePlaybackKey(episode),
      _providerEpisodePlaybackKey(episode),
      '${normalizeSeriesKey(episode.seriesName)}|${episode.episodeNumber}',
    }.where((entry) => entry.trim().isNotEmpty).toSet();
  }

  Set<String> _expandedEpisodePlaybackAliases(EpisodeItem episode) {
    final aliases = <String>{..._episodePlaybackAliases(episode)};
    final series = findSeriesForEpisode(episode);
    if (series != null) {
      aliases.add('${series.stableKey}|${episode.episodeNumber}');
      for (final candidate in series.episodes) {
        if (candidate.episodeNumber == episode.episodeNumber) {
          aliases.addAll(_episodePlaybackAliases(candidate));
        }
      }
    }
    return aliases.where((entry) => entry.trim().isNotEmpty).toSet();
  }

  String _episodePlaybackKey(EpisodeItem episode) {
    final series = _seriesStateKeyForEpisode(episode);
    if (series.isEmpty) {
      return '';
    }
    return '$series|${episode.episodeNumber}';
  }

  String _providerEpisodePlaybackKey(EpisodeItem episode) {
    final providerKey = _providerSeriesStateKey(episode.provider, episode.slug);
    if (providerKey.isEmpty) {
      return '';
    }
    return '$providerKey|${episode.episodeNumber}';
  }

  String _seriesStateKeyForEpisode(EpisodeItem episode) {
    final explicit = episode.seriesStateKey.trim();
    if (explicit.isNotEmpty) {
      return explicit;
    }
    final providerKey = _providerSeriesStateKey(episode.provider, episode.slug);
    if (providerKey.isNotEmpty) {
      return providerKey;
    }
    return normalizeSeriesKey(episode.seriesName);
  }

  String _providerSeriesStateKey(RemoteProvider? provider, String slug) {
    final normalizedSlug = slug.trim().toLowerCase();
    if (provider == null || normalizedSlug.isEmpty) {
      return '';
    }
    return '${provider.id}:$normalizedSlug';
  }

  EpisodePlaybackRecord? _firstPlaybackRecord(Set<String> aliases) {
    for (final key in aliases) {
      final record = _state.profile.episodePlayback[key];
      if (record != null) {
        return record;
      }
    }
    return null;
  }

  Future<void> _save() async {
    _isSaving = true;
    notifyListeners();
    try {
      await _store.save(_state);
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }
}
