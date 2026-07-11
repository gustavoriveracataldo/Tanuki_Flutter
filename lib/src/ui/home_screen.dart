import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../models.dart';
import '../services/my_anime_list_service.dart';
import 'player_screen.dart';
import 'toonami_theme.dart';
import 'trailer_queue_screen.dart';

const _appVersionLabel = '0.9.5';

enum _Section {
  anime,
  playlist,
  random,
  search,
  favorites,
  similar,
  settings,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  _Section _section = _Section.anime;
  SeriesItem? _selectedSeries;
  _Section? _detailReturnSection;
  SeriesItem? _heroPreviewSeries;
  SeriesItem? _similarSeries;
  List<RemoteSearchCandidate> _similarResults = const [];
  List<RemoteSearchCandidate> _detailSimilarResults = const [];
  List<RemoteSearchCandidate> _homeTrendingResults = const [];
  List<RemoteSearchCandidate> _homeMovieResults = const [];
  bool _similarLoading = false;
  bool _detailSimilarLoading = false;
  bool _homeTrendingLoading = false;
  bool _homeMoviesLoading = false;
  bool _randomLoading = false;
  bool _detailImporting = false;
  double _animePanelScrollOffset = 0.0;
  int _detailSimilarRequest = 0;
  int _homeTrendingVisualRequest = 0;
  int _homeMovieVisualRequest = 0;
  int _handledTrailerDetailRequestId = 0;
  String _similarStatus = '';
  String _detailSimilarStatus = '';
  bool _profilePickerVisible = false;
  bool _handlingTrailerDetailRequest = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handlePendingTrailerDetailRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadHomeTrending());
        unawaited(_loadHomeMovies());
        _handlePendingTrailerDetailRequest();
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handlePendingTrailerDetailRequest);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final heroSeries = _resolveHeroSeries(widget.controller);
        return Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) {
              final compactNavigation = constraints.maxWidth < 720 ||
                  constraints.maxHeight > constraints.maxWidth;
              return Stack(
                children: [
                  Positioned.fill(child: _HeroBackground(series: heroSeries)),
                  if (compactNavigation) ...[
                    Positioned.fill(
                      bottom: 64,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                        child: _buildPanel(widget.controller),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _BottomRail(
                        activeSection: _section,
                        profile: widget.controller.state.profile,
                        onSectionSelected: _selectSection,
                        onProfilePressed: _showProfilePicker,
                      ),
                    ),
                  ] else ...[
                    Positioned.fill(
                      left: 54,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 14, 14, 14),
                        child: _buildPanel(widget.controller),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: _SideRail(
                        activeSection: _section,
                        profile: widget.controller.state.profile,
                        onSectionSelected: _selectSection,
                        onProfilePressed: _showProfilePicker,
                      ),
                    ),
                  ],
                  if (widget.controller.isSaving)
                    const Positioned(
                      right: 18,
                      top: 18,
                      child: _SavingPill(),
                    ),
                  if (_profilePickerVisible)
                    Positioned.fill(
                      child: _ProfilePickerOverlay(
                        controller: widget.controller,
                        onClose: _hideProfilePicker,
                        onSelectProfile: _selectProfile,
                        onCreateProfile: _createProfile,
                        onRenameProfile: _renameProfile,
                        onChangeProfileAvatar: _changeProfileAvatar,
                        onSetDefaultProfile: _setDefaultProfile,
                        onDeleteProfile: _deleteProfile,
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _selectSection(_Section section) {
    if (section == _Section.random) {
      setState(() {
        _section = _Section.random;
        _selectedSeries = null;
        _randomLoading = true;
      });
      unawaited(_openRandomSeries());
      return;
    }
    setState(() {
      _section = section;
      if (section == _Section.anime) {
        _selectedSeries = null;
      }
    });
    if (section == _Section.search && widget.controller.remoteResults.isEmpty) {
      widget.controller.searchRemote(_searchController.text);
    }
  }

  SeriesItem? _resolveHeroSeries(AppController controller) {
    if (_selectedSeries != null) {
      return _selectedSeries;
    }
    if (_heroPreviewSeries != null) {
      return _heroPreviewSeries;
    }
    final currentEntry = controller.currentEntry;
    if (currentEntry != null) {
      return controller.findSeriesForEpisode(currentEntry);
    }
    for (final series in controller.library) {
      if (series.backgroundUrl.isNotEmpty || series.imageUrl.isNotEmpty) {
        return series;
      }
    }
    return controller.library.isEmpty ? null : controller.library.first;
  }

  Widget _buildAnimePanel(AppController controller) {
    return _AnimePanel(
      controller: controller,
      selectedSeries: _selectedSeries,
      heroPreviewSeries: _heroPreviewSeries,
      detailBackLabel: _detailBackLabel,
      detailSimilarCandidates: _detailSimilarResults,
      detailSimilarStatus: _detailSimilarStatus,
      detailSimilarLoading: _detailSimilarLoading,
      detailImporting: _detailImporting,
      trendingCandidates: _homeTrendingResults,
      trendingLoading: _homeTrendingLoading,
      movieCandidates: _homeMovieResults,
      moviesLoading: _homeMoviesLoading,
      scrollOffset: _animePanelScrollOffset,
      onScrollOffset: _updateAnimePanelOpacity,
      onSeriesCleared: _clearSelectedSeries,
      onRemoteCandidateSelected: (candidate) {
        _openRemoteCandidate(candidate);
      },
      onSimilarSeriesRequested: _openSimilarForSeries,
      onPlayEpisode: _playEpisode,
      onOpenSeriesTrailer: _openSeriesTrailer,
      onPlayTrendingTrailers: _playTrendingTrailerQueue,
      onStopWatchingSeries: widget.controller.stopWatchingSeries,
      onSeriesSelected: _selectSeries,
      onPreviewSeries: _previewSeries,
      onPreviewRemoteCandidate: _previewRemoteCandidate,
    );
  }

  Widget _buildPanel(AppController controller) {
    return switch (_section) {
      _Section.playlist => _PlaylistPanel(
          controller: controller,
          onSeriesSelected: _selectSeries,
          onPlayEpisode: _playEpisode,
        ),
      _Section.search => _SearchPanel(
          controller: controller,
          searchController: _searchController,
          onRemoteCandidateSelected: (candidate) {
            _openRemoteCandidate(candidate);
          },
          onPlaySearchTrailers: _playSearchTrailerQueue,
        ),
      _Section.favorites => _FavoritesPanel(
          controller: controller,
          onSeriesSelected: _selectSeries,
        ),
      _Section.similar => _SimilarPanel(
          controller: controller,
          series: _similarSeries,
          candidates: _similarResults,
          status: _similarStatus,
          loading: _similarLoading,
          onBack: _returnToSelectedSeries,
          onRemoteCandidateSelected: _openRemoteCandidate,
        ),
      _Section.settings => _SettingsPanel(controller: controller),
      _Section.random => _RandomLoadingPanel(loading: _randomLoading),
      _ => _buildAnimePanel(controller),
    };
  }

  void _selectSeries(
    SeriesItem series, {
    _Section? returnSection,
    bool refreshVisuals = true,
    bool importing = false,
  }) {
    final origin = returnSection ?? _section;
    setState(() {
      _selectedSeries = series;
      _detailReturnSection =
          origin == _Section.anime || origin == _Section.random ? null : origin;
      _heroPreviewSeries = series;
      _section = _Section.anime;
      _detailImporting = importing;
    });
    if (refreshVisuals) {
      unawaited(_refreshSelectedSeriesVisuals(series));
    }
    unawaited(_loadDetailSimilar(series));
  }

  void _previewSeries(SeriesItem series) {
    if (_selectedSeries?.stableKey == series.stableKey ||
        _heroPreviewSeries?.stableKey == series.stableKey) {
      return;
    }
    setState(() {
      _heroPreviewSeries = series;
    });
  }

  void _previewRemoteCandidate(RemoteSearchCandidate candidate) {
    final preview = candidate.toSeries(existingNames: const []);
    if (_heroPreviewSeries?.stableKey == preview.stableKey) {
      return;
    }
    setState(() {
      _heroPreviewSeries = preview;
    });
  }

  void _updateAnimePanelOpacity(double offset) {
    if (offset != _animePanelScrollOffset) {
      setState(() {
        _animePanelScrollOffset = offset;
      });
    }
  }

  Future<void> _refreshSelectedSeriesVisuals(SeriesItem series) async {
    final refreshed =
        await widget.controller.refreshRemoteSeriesVisuals(series);
    if (!mounted || refreshed.stableKey != series.stableKey) {
      return;
    }
    if (_selectedSeries?.stableKey == series.stableKey) {
      setState(() {
        _selectedSeries = refreshed;
      });
      unawaited(_loadDetailSimilar(refreshed));
    }
  }

  void _clearSelectedSeries() {
    final returnSection = _detailReturnSection;
    setState(() {
      _selectedSeries = null;
      _detailReturnSection = null;
      _detailImporting = false;
      if (returnSection != null) {
        _section = returnSection;
      }
    });
  }

  void _returnToSelectedSeries() {
    setState(() {
      _section = _Section.anime;
    });
  }

  void _showProfilePicker() {
    setState(() {
      _profilePickerVisible = true;
    });
  }

  void _hideProfilePicker() {
    setState(() {
      _profilePickerVisible = false;
    });
  }

  Future<void> _selectProfile(String profileId) async {
    await widget.controller.selectProfile(profileId);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedSeries = null;
      _section = _Section.anime;
      _profilePickerVisible = false;
    });
  }

  Future<void> _createProfile([String name = '']) async {
    await widget.controller.createProfile(name);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedSeries = null;
      _section = _Section.anime;
    });
  }

  Future<void> _renameProfile(String profileId, String name) async {
    await widget.controller.renameProfile(profileId, name);
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _changeProfileAvatar(
      String profileId, String avatarPresetId) async {
    await widget.controller
        .updateProfileAvatarPreset(profileId, avatarPresetId);
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _setDefaultProfile(String? profileId) async {
    await widget.controller.setDefaultProfile(profileId);
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _deleteProfile(String profileId) async {
    await widget.controller.deleteProfile(profileId);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedSeries = null;
      _section = _Section.anime;
    });
  }

  Future<void> _openRemoteCandidate(RemoteSearchCandidate candidate) async {
    final origin = _section;
    final existingSeries = widget.controller.findRemoteSeriesForCandidate(
      candidate,
    );
    if (existingSeries != null) {
      _selectSeries(existingSeries, returnSection: origin);
      return;
    }
    final provisional = candidate.toSeries(
      existingNames: widget.controller.library.map((series) => series.name),
    );
    _selectSeries(
      provisional,
      returnSection: origin,
      refreshVisuals: false,
      importing: true,
    );
    final series = await widget.controller.importRemoteCandidate(candidate);
    if (!mounted) {
      return;
    }
    if (_selectedSeries?.stableKey == provisional.stableKey) {
      _selectSeries(series, returnSection: origin, refreshVisuals: false);
    }
  }

  void _handlePendingTrailerDetailRequest() {
    final request = widget.controller.pendingTrailerDetailRequest;
    if (request == null ||
        request.id == _handledTrailerDetailRequestId ||
        _handlingTrailerDetailRequest) {
      return;
    }
    _handledTrailerDetailRequestId = request.id;
    _handlingTrailerDetailRequest = true;
    widget.controller.clearPendingTrailerDetailRequest(request.id);
    unawaited(_openTrailerDetailRequest(request).whenComplete(() {
      _handlingTrailerDetailRequest = false;
    }));
  }

  Future<void> _openTrailerDetailRequest(TrailerDetailRequest request) async {
    final existingSeries = _seriesForTrailerDetailRequest(request);
    if (existingSeries != null) {
      if (!mounted) {
        return;
      }
      _selectSeries(existingSeries, returnSection: _Section.anime);
      return;
    }
    final candidate = _candidateForTrailerDetailRequest(request) ??
        request.toRemoteCandidate();
    if (candidate == null) {
      widget.controller
          .setStatusMessage('No pude abrir el detalle del trailer.');
      return;
    }
    try {
      final series = await widget.controller.importRemoteCandidate(candidate);
      if (!mounted) {
        return;
      }
      _selectSeries(series, returnSection: _Section.anime);
    } catch (_) {
      widget.controller
          .setStatusMessage('No pude abrir el detalle de ${request.title}.');
    }
  }

  SeriesItem? _seriesForTrailerDetailRequest(TrailerDetailRequest request) {
    for (final series in widget.controller.library) {
      if (_matchesSeriesTrailerDetailRequest(series, request)) {
        return series;
      }
    }
    return null;
  }

  bool _matchesSeriesTrailerDetailRequest(
    SeriesItem series,
    TrailerDetailRequest request,
  ) {
    final seriesKey = request.seriesKey.trim();
    if (seriesKey.isNotEmpty && series.stableKey == seriesKey) {
      return true;
    }
    if (request.catalogId > 0 && series.catalogId == request.catalogId) {
      return true;
    }
    final provider = request.provider;
    if (provider != null &&
        request.slug.trim().isNotEmpty &&
        series.provider == provider &&
        series.slug == request.slug.trim()) {
      return true;
    }
    return normalizeSeriesKey(series.name) == normalizeSeriesKey(request.title);
  }

  RemoteSearchCandidate? _candidateForTrailerDetailRequest(
    TrailerDetailRequest request,
  ) {
    final candidates = <RemoteSearchCandidate>[
      ..._homeTrendingResults,
      ..._homeMovieResults,
      ...widget.controller.remoteResults,
      ..._similarResults,
      ..._detailSimilarResults,
    ];
    for (final candidate in candidates) {
      if (_matchesCandidateTrailerDetailRequest(candidate, request)) {
        return candidate;
      }
    }
    return null;
  }

  bool _matchesCandidateTrailerDetailRequest(
    RemoteSearchCandidate candidate,
    TrailerDetailRequest request,
  ) {
    if (request.catalogId > 0 && candidate.catalogId == request.catalogId) {
      return true;
    }
    final provider = request.provider;
    if (provider != null &&
        request.slug.trim().isNotEmpty &&
        candidate.provider == provider &&
        candidate.slug == request.slug.trim()) {
      return true;
    }
    if (request.trailerUrl.trim().isNotEmpty &&
        candidate.trailerUrl.trim() == request.trailerUrl.trim()) {
      return true;
    }
    return normalizeSeriesKey(candidate.title) ==
        normalizeSeriesKey(request.title);
  }

  Future<void> _loadHomeTrending() async {
    if (_homeTrendingLoading) {
      return;
    }
    if (widget.controller.remoteResults.isNotEmpty) {
      setState(() {
        _homeTrendingResults =
            widget.controller.remoteResults.take(14).toList(growable: false);
      });
      unawaited(_refreshHomeTrendingVisuals(_homeTrendingResults));
      return;
    }
    setState(() {
      _homeTrendingLoading = true;
    });
    await widget.controller.searchRemote('');
    if (!mounted) {
      return;
    }
    setState(() {
      _homeTrendingResults =
          widget.controller.remoteResults.take(14).toList(growable: false);
      _homeTrendingLoading = false;
    });
    unawaited(_refreshHomeTrendingVisuals(_homeTrendingResults));
  }

  Future<void> _loadHomeMovies() async {
    if (_homeMoviesLoading) {
      return;
    }
    setState(() {
      _homeMoviesLoading = true;
    });
    try {
      final movies = await widget.controller.loadHomeMovieCandidates(pages: 3);
      if (!mounted) {
        return;
      }
      setState(() {
        _homeMovieResults = movies.take(18).toList(growable: false);
        _homeMoviesLoading = false;
      });
      unawaited(_refreshHomeMovieVisuals(_homeMovieResults));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _homeMoviesLoading = false;
      });
    }
  }

  Future<void> _refreshHomeTrendingVisuals(
      List<RemoteSearchCandidate> candidates) async {
    if (candidates.isEmpty) {
      return;
    }
    final request = ++_homeTrendingVisualRequest;
    final refreshed = await widget.controller.refreshCandidateVisuals(
      candidates,
      limit: 14,
    );
    if (!mounted || request != _homeTrendingVisualRequest) {
      return;
    }
    setState(() {
      _homeTrendingResults = refreshed.take(14).toList(growable: false);
      final preview = _heroPreviewSeries;
      if (preview != null) {
        final refreshedPreview = refreshed.firstWhere(
          (candidate) =>
              normalizeSeriesKey(candidate.title) == preview.stableKey,
          orElse: () => const RemoteSearchCandidate(
            provider: RemoteProvider.catalog,
            slug: '',
            title: '',
          ),
        );
        if (refreshedPreview.title.isNotEmpty) {
          _heroPreviewSeries =
              refreshedPreview.toSeries(existingNames: const []);
        }
      }
    });
  }

  Future<void> _refreshHomeMovieVisuals(
      List<RemoteSearchCandidate> candidates) async {
    if (candidates.isEmpty) {
      return;
    }
    final request = ++_homeMovieVisualRequest;
    final refreshed = await widget.controller.refreshCandidateVisuals(
      candidates,
      limit: 14,
    );
    if (!mounted || request != _homeMovieVisualRequest) {
      return;
    }
    setState(() {
      _homeMovieResults = refreshed.take(18).toList(growable: false);
    });
  }

  Future<void> _openRandomSeries() async {
    final series = await widget.controller.openRandomSeries();
    if (!mounted || series == null) {
      if (mounted) {
        setState(() {
          _randomLoading = false;
          _section = _Section.anime;
        });
      }
      return;
    }
    setState(() {
      _randomLoading = false;
    });
    _selectSeries(series, returnSection: _Section.anime);
  }

  Future<void> _loadDetailSimilar(SeriesItem series) async {
    final request = ++_detailSimilarRequest;
    final seriesKey = series.stableKey;
    setState(() {
      _detailSimilarLoading = true;
      _detailSimilarStatus = 'Buscando similares...';
      _detailSimilarResults = const [];
    });
    final result = await widget.controller.loadSimilarCandidates(series);
    if (!mounted ||
        request != _detailSimilarRequest ||
        _selectedSeries?.stableKey != seriesKey) {
      return;
    }
    setState(() {
      _detailSimilarResults = result.candidates.take(12).toList();
      _detailSimilarStatus = result.status;
      _detailSimilarLoading = false;
    });
  }

  String get _detailBackLabel {
    return switch (_detailReturnSection) {
      _Section.search => 'Buscar',
      _Section.favorites => 'Mi espacio',
      _Section.playlist => 'Playlist',
      _Section.similar => 'Similares',
      _Section.settings => 'Ajustes',
      _ => 'Inicio',
    };
  }

  Future<void> _openSimilarForSeries(SeriesItem series) async {
    setState(() {
      _similarSeries = series;
      _similarResults = const [];
      _similarStatus = 'Buscando series realmente relacionadas...';
      _similarLoading = true;
      _section = _Section.similar;
    });
    final result = await widget.controller.loadSimilarCandidates(series);
    if (!mounted) {
      return;
    }
    setState(() {
      _similarResults = result.candidates;
      _similarStatus = result.status;
      _similarLoading = false;
    });
  }

  Future<void> _playEpisode(EpisodeItem episode) async {
    final series = widget.controller.findSeriesForEpisode(episode);
    final launchMode = _selectedSeries != null &&
            series?.stableKey == _selectedSeries!.stableKey
        ? PlayerLaunchMode.detail
        : _section == _Section.anime &&
                series != null &&
                widget.controller.state.profile.watchingSeries
                    .contains(series.stableKey)
            ? PlayerLaunchMode.continueWatching
            : PlayerLaunchMode.normal;
    await widget.controller.setCurrentEntry(episode);
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          controller: widget.controller,
          episode: episode,
          launchMode: launchMode,
        ),
      ),
    );
  }

  Future<void> _openSeriesTrailer(SeriesItem series) async {
    await _openTrailerQueue(
      series.name,
      [
        TrailerQueueEntry(
          title: series.name,
          trailerUrl: series.trailerUrl,
          seriesKey: series.stableKey,
          providerId: series.provider?.id ?? '',
          slug: series.slug,
          watchUrl: series.watchUrl,
          seriesUrl: series.watchUrl,
          catalogId: series.catalogId,
        ),
      ],
      emptyMessage: 'No hay trailer disponible para esta serie.',
    );
  }

  Future<void> _playTrendingTrailerQueue() async {
    await _openTrailerQueue(
      'Tendencias',
      _trailerEntriesFromCandidates(_homeTrendingResults.take(14)),
      emptyMessage: 'No hay trailers disponibles en tendencias.',
    );
  }

  Future<void> _playSearchTrailerQueue() async {
    await _openTrailerQueue(
      _searchController.text.trim().isEmpty
          ? 'Busqueda'
          : 'Busqueda: ${_searchController.text.trim()}',
      _trailerEntriesFromCandidates(widget.controller.remoteResults),
      emptyMessage: 'No hay trailers disponibles para los resultados visibles.',
    );
  }

  List<TrailerQueueEntry> _trailerEntriesFromCandidates(
    Iterable<RemoteSearchCandidate> candidates,
  ) {
    final seen = <String>{};
    return candidates
        .map(
          (candidate) => TrailerQueueEntry(
            title: candidate.title,
            trailerUrl: candidate.trailerUrl,
            providerId: candidate.provider.id,
            slug: candidate.slug,
            watchUrl: candidate.watchUrl,
            seriesUrl: candidate.seriesUrl,
            catalogId: candidate.catalogId,
          ),
        )
        .where((entry) =>
            entry.trailerUrl.trim().isNotEmpty &&
            seen.add(entry.trailerUrl.trim()))
        .toList();
  }

  Future<void> _openTrailerQueue(
    String title,
    List<TrailerQueueEntry> entries, {
    required String emptyMessage,
  }) async {
    final playable =
        entries.where((entry) => entry.trailerUrl.trim().isNotEmpty).toList();
    if (playable.isEmpty) {
      widget.controller.setStatusMessage(emptyMessage);
      return;
    }
    widget.controller.setStatusMessage(
      playable.length == 1
          ? 'Abriendo trailer.'
          : 'Reproduciendo ${playable.length} trailers.',
    );
    if (!mounted) {
      return;
    }
    final detailLink = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => TrailerQueueScreen(
          title: title,
          entries: playable,
          onDetailLink: (link) {
            unawaited(widget.controller.handleInternalDeepLink(link));
          },
        ),
      ),
    );
    if (detailLink != null && detailLink.trim().isNotEmpty) {
      await widget.controller.handleInternalDeepLink(detailLink);
    }
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.activeSection,
    required this.profile,
    required this.onSectionSelected,
    required this.onProfilePressed,
  });

  final _Section activeSection;
  final UserProfileState profile;
  final ValueChanged<_Section> onSectionSelected;
  final VoidCallback onProfilePressed;

  @override
  Widget build(BuildContext context) {
    final items = _navigationItems();

    return Container(
      width: 72,
      height: double.infinity,
      decoration: const BoxDecoration(
        color: TanukiColors.rail,
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Image.asset(
                'assets/images/tanuki_brand_logo.png',
                width: 56,
                height: 58,
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
              ),
            ),
            const SizedBox(height: 8),
            Tooltip(
              message: profile.name,
              child: InkWell(
                onTap: onProfilePressed,
                borderRadius: BorderRadius.circular(14),
                child: _ProfileAvatar(
                  profile: profile,
                  size: 42,
                  radius: 21,
                  fontSize: 20,
                  borderColor: const Color(0x55334A62),
                ),
              ),
            ),
            const Spacer(),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                child: _SideRailButton(
                  item: item,
                  active: activeSection == item.section,
                  onPressed: () => onSectionSelected(item.section),
                ),
              ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _SideRailButton extends StatefulWidget {
  const _SideRailButton({
    required this.item,
    required this.active,
    required this.onPressed,
  });

  final _RailItem item;
  final bool active;
  final VoidCallback onPressed;

  @override
  State<_SideRailButton> createState() => _SideRailButtonState();
}

class _SideRailButtonState extends State<_SideRailButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final foreground = _focused || _hovered
        ? TanukiColors.orange
        : widget.active
            ? TanukiColors.text
            : TanukiColors.muted;
    return Tooltip(
      message: widget.item.label,
      child: AnimatedScale(
        scale: _focused ? 1.06 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: InkWell(
          onTap: widget.onPressed,
          onFocusChange: (value) {
            if (_focused != value) {
              setState(() => _focused = value);
            }
          },
          onHover: (value) {
            if (_hovered != value) {
              setState(() => _hovered = value);
            }
          },
          borderRadius: BorderRadius.circular(8),
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          child: Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(color: Colors.transparent),
            child: Stack(
              alignment: Alignment.center,
              children: [
                _RailItemIcon(
                  item: widget.item,
                  size: 29,
                  color: foreground,
                ),
                if (widget.active)
                  const Positioned(
                    bottom: 3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: TanukiColors.orange,
                        borderRadius: BorderRadius.all(Radius.circular(2)),
                      ),
                      child: SizedBox(width: 16, height: 3),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomRail extends StatelessWidget {
  const _BottomRail({
    required this.activeSection,
    required this.profile,
    required this.onSectionSelected,
    required this.onProfilePressed,
  });

  final _Section activeSection;
  final UserProfileState profile;
  final ValueChanged<_Section> onSectionSelected;
  final VoidCallback onProfilePressed;

  @override
  Widget build(BuildContext context) {
    final items = _navigationItems();
    return Container(
      decoration: const BoxDecoration(
        color: TanukiColors.rail,
        border: Border(top: BorderSide(color: TanukiColors.panelStroke)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Tooltip(
                message: profile.name,
                child: IconButton(
                  onPressed: onProfilePressed,
                  icon: _ProfileAvatar(
                    profile: profile,
                    size: 32,
                    radius: 16,
                    fontSize: 16,
                    borderColor: const Color(0x55334A62),
                  ),
                  tooltip: 'Menu',
                ),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final item in items)
                      _BottomRailButton(
                        item: item,
                        active: activeSection == item.section,
                        onPressed: () => onSectionSelected(item.section),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomRailButton extends StatelessWidget {
  const _BottomRailButton({
    required this.item,
    required this.active,
    required this.onPressed,
  });

  final _RailItem item;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.label,
      child: IconButton(
        onPressed: onPressed,
        icon: _RailItemIcon(
          item: item,
          size: 21,
          color: active ? TanukiColors.text : TanukiColors.muted,
        ),
        color: active ? TanukiColors.text : TanukiColors.muted,
        style: ButtonStyle(
          fixedSize: WidgetStateProperty.all(const Size(72, 72)),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return active ? const Color(0x332B3B4D) : Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return TanukiColors.orange;
            }
            if (active) {
              return TanukiColors.text;
            }
            return TanukiColors.muted;
          }),
          side: WidgetStateProperty.all(BorderSide.none),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    );
  }
}

List<_RailItem> _navigationItems() {
  return const [
    _RailItem(_Section.search, Icons.search, 'Buscar'),
    _RailItem(
      _Section.anime,
      Icons.live_tv,
      'Inicio',
      assetPath: 'assets/images/sidebar_home_naruto.png',
    ),
    _RailItem(_Section.random, Icons.shuffle, 'Random'),
    _RailItem(_Section.favorites, Icons.favorite, 'Mi espacio'),
    _RailItem(_Section.playlist, Icons.playlist_play, 'Playlist'),
    _RailItem(_Section.settings, Icons.settings, 'Ajustes'),
  ];
}

class _RailItem {
  const _RailItem(
    this.section,
    this.icon,
    this.label, {
    this.assetPath = '',
  });

  final _Section section;
  final IconData icon;
  final String label;
  final String assetPath;
}

class _RailItemIcon extends StatelessWidget {
  const _RailItemIcon({
    required this.item,
    required this.size,
    required this.color,
  });

  final _RailItem item;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (item.assetPath.isEmpty) {
      return Icon(item.icon, size: size, color: color);
    }
    return ImageIcon(
      AssetImage(item.assetPath),
      size: size,
      color: color,
    );
  }
}

enum _ProfileOverlayMode {
  picker,
  manage,
  actions,
  create,
  rename,
  avatar,
  delete,
}

class _ProfilePickerOverlay extends StatefulWidget {
  const _ProfilePickerOverlay({
    required this.controller,
    required this.onClose,
    required this.onSelectProfile,
    required this.onCreateProfile,
    required this.onRenameProfile,
    required this.onChangeProfileAvatar,
    required this.onSetDefaultProfile,
    required this.onDeleteProfile,
  });

  final AppController controller;
  final VoidCallback onClose;
  final ValueChanged<String> onSelectProfile;
  final Future<void> Function(String name) onCreateProfile;
  final Future<void> Function(String profileId, String name) onRenameProfile;
  final Future<void> Function(String profileId, String avatarPresetId)
      onChangeProfileAvatar;
  final Future<void> Function(String? profileId) onSetDefaultProfile;
  final Future<void> Function(String profileId) onDeleteProfile;

  @override
  State<_ProfilePickerOverlay> createState() => _ProfilePickerOverlayState();
}

class _ProfilePickerOverlayState extends State<_ProfilePickerOverlay> {
  final TextEditingController _profileNameController = TextEditingController();
  _ProfileOverlayMode _mode = _ProfileOverlayMode.picker;
  String _selectedProfileId = '';

  @override
  void dispose() {
    _profileNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE812141A),
      child: InkWell(
        onTap: widget.onClose,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxPanelWidth =
                _mode == _ProfileOverlayMode.picker ? 760.0 : 680.0;
            final availableWidth = constraints.maxWidth - 32;
            final panelWidth =
                availableWidth < maxPanelWidth ? availableWidth : maxPanelWidth;
            return Center(
              child: InkWell(
                onTap: () {},
                child: Container(
                  constraints: BoxConstraints(
                    minWidth: constraints.maxWidth >= 700 ? 620 : 0,
                    maxWidth: panelWidth,
                  ),
                  padding: const EdgeInsets.fromLTRB(44, 28, 44, 28),
                  decoration: glassDecoration(color: const Color(0xEE141D28)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: TanukiColors.text,
                          fontSize: 27,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildBody(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  AppController get controller => widget.controller;

  String get _title {
    return switch (_mode) {
      _ProfileOverlayMode.picker => 'Cambiar usuario',
      _ProfileOverlayMode.manage => 'Administrar perfiles',
      _ProfileOverlayMode.actions =>
        _selectedProfile.name.trim().isEmpty ? 'Perfil' : _selectedProfile.name,
      _ProfileOverlayMode.create => 'Nuevo perfil',
      _ProfileOverlayMode.rename => 'Renombrar perfil',
      _ProfileOverlayMode.avatar => 'Cambiar avatar',
      _ProfileOverlayMode.delete => 'Eliminar perfil',
    };
  }

  UserProfileState get _selectedProfile {
    final selectedId = _selectedProfileId.trim();
    if (selectedId.isNotEmpty) {
      for (final profile in controller.profiles) {
        if (profile.id == selectedId) {
          return profile;
        }
      }
    }
    return controller.state.profile;
  }

  Widget _buildBody() {
    return switch (_mode) {
      _ProfileOverlayMode.picker => _buildPicker(),
      _ProfileOverlayMode.manage => _buildManage(),
      _ProfileOverlayMode.actions => _buildActions(),
      _ProfileOverlayMode.create => _buildNameForm(
          hint: 'Nombre del perfil',
          primaryLabel: 'Crear',
          onSubmit: _submitCreate,
        ),
      _ProfileOverlayMode.rename => _buildNameForm(
          hint: 'Nombre del perfil',
          primaryLabel: 'Guardar',
          onSubmit: _submitRename,
        ),
      _ProfileOverlayMode.avatar => _buildAvatarGrid(),
      _ProfileOverlayMode.delete => _buildDeleteConfirm(),
    };
  }

  Widget _buildPicker() {
    final profiles = controller.profiles;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final profileRowHeight = (screenHeight * 0.38).clamp(180.0, 260.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: profileRowHeight,
          child: ListView.separated(
            clipBehavior: Clip.none,
            scrollDirection: Axis.horizontal,
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemBuilder: (context, index) {
              final profile = profiles[index];
              return _ProfileTile(
                profile: profile,
                active: profile.id == controller.activeProfileId,
                isDefault: profile.id == controller.defaultProfileId,
                onSelect: () => widget.onSelectProfile(profile.id),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemCount: profiles.length,
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 42,
          child: OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _mode = _ProfileOverlayMode.manage;
              });
            },
            icon: const Icon(Icons.manage_accounts),
            label: const Text('Administrar perfiles'),
          ),
        ),
      ],
    );
  }

  Widget _buildManage() {
    final profiles = controller.profiles;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final manageListMaxHeight = (screenHeight * 0.5).clamp(260.0, 380.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: manageListMaxHeight),
          child: ListView.separated(
            shrinkWrap: true,
            itemBuilder: (context, index) {
              final profile = profiles[index];
              return _ProfileManagementRow(
                profile: profile,
                meta: _profileMeta(profile),
                onTap: () {
                  setState(() {
                    _selectedProfileId = profile.id;
                    _mode = _ProfileOverlayMode.actions;
                  });
                },
              );
            },
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemCount: profiles.length,
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: _openCreate,
              icon: const Icon(Icons.person_add),
              label: const Text('Agregar perfil'),
            ),
            OutlinedButton(
              onPressed: () {
                setState(() {
                  _mode = _ProfileOverlayMode.picker;
                });
              },
              child: const Text('Cerrar'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActions() {
    final profile = _selectedProfile;
    final defaultActive = profile.id == controller.defaultProfileId &&
        controller.defaultProfileId.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ProfileActionButton(
          icon: Icons.check_circle_outline,
          label: 'Seleccionar ahora',
          onPressed: () => widget.onSelectProfile(profile.id),
        ),
        _ProfileActionButton(
          icon: Icons.edit,
          label: 'Renombrar',
          onPressed: () => _openRename(profile),
        ),
        _ProfileActionButton(
          icon: Icons.palette_outlined,
          label: 'Cambiar avatar',
          onPressed: () {
            setState(() {
              _mode = _ProfileOverlayMode.avatar;
            });
          },
        ),
        _ProfileActionButton(
          icon: Icons.star_outline,
          label: defaultActive
              ? 'Quitar perfil predeterminado'
              : 'Establecer como predeterminado',
          onPressed: () async {
            await widget.onSetDefaultProfile(defaultActive ? null : profile.id);
            if (!mounted) {
              return;
            }
            setState(() {
              _mode = _ProfileOverlayMode.actions;
            });
          },
        ),
        if (controller.profiles.length > 1)
          _ProfileActionButton(
            icon: Icons.delete_outline,
            label: 'Eliminar perfil',
            danger: true,
            onPressed: () {
              setState(() {
                _mode = _ProfileOverlayMode.delete;
              });
            },
          ),
        const SizedBox(height: 14),
        OutlinedButton(
          onPressed: () {
            setState(() {
              _mode = _ProfileOverlayMode.manage;
            });
          },
          child: const Text('Volver'),
        ),
      ],
    );
  }

  Widget _buildNameForm({
    required String hint,
    required String primaryLabel,
    required Future<void> Function() onSubmit,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _profileNameController,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: 22),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 10,
          children: [
            FilledButton(
              onPressed: onSubmit,
              child: Text(primaryLabel),
            ),
            OutlinedButton(
              onPressed: () {
                setState(() {
                  _mode = _mode == _ProfileOverlayMode.create
                      ? _ProfileOverlayMode.manage
                      : _ProfileOverlayMode.actions;
                });
              },
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAvatarGrid() {
    final profile = _selectedProfile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          runSpacing: 14,
          children: [
            for (var index = 0; index < _profileAvatarPresets.length; index++)
              _AvatarPresetButton(
                preset: _profileAvatarPresets[index],
                label: 'Avatar ${index + 1}',
                initial: _profileInitial(profile),
                selected:
                    profile.avatarPresetId == _profileAvatarPresets[index].id,
                onTap: () async {
                  await widget.onChangeProfileAvatar(
                    profile.id,
                    _profileAvatarPresets[index].id,
                  );
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _mode = _ProfileOverlayMode.actions;
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 22),
        OutlinedButton(
          onPressed: () {
            setState(() {
              _mode = _ProfileOverlayMode.actions;
            });
          },
          child: const Text('Volver'),
        ),
      ],
    );
  }

  Widget _buildDeleteConfirm() {
    final profile = _selectedProfile;
    final displayName = profile.name.trim().isEmpty ? 'Perfil' : profile.name;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Se borrara el perfil $displayName y sus listas/progreso guardados.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: TanukiColors.muted,
            fontSize: 14,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () async {
                await widget.onDeleteProfile(profile.id);
                if (!mounted) {
                  return;
                }
                setState(() {
                  _selectedProfileId = '';
                  _mode = _ProfileOverlayMode.manage;
                });
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Eliminar'),
            ),
            OutlinedButton(
              onPressed: () {
                setState(() {
                  _mode = _ProfileOverlayMode.actions;
                });
              },
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ],
    );
  }

  String _profileMeta(UserProfileState profile) {
    final parts = <String>[];
    if (profile.id == controller.activeProfileId) {
      parts.add('activo');
    }
    if (profile.id == controller.defaultProfileId) {
      parts.add('predeterminado');
    }
    return parts.isEmpty ? '' : parts.join(' | ');
  }

  void _openCreate() {
    _profileNameController.text = 'Perfil ${controller.profiles.length + 1}';
    _profileNameController.selection = TextSelection.fromPosition(
      TextPosition(offset: _profileNameController.text.length),
    );
    setState(() {
      _mode = _ProfileOverlayMode.create;
    });
  }

  void _openRename(UserProfileState profile) {
    _profileNameController.text = profile.name;
    _profileNameController.selection = TextSelection.fromPosition(
      TextPosition(offset: _profileNameController.text.length),
    );
    setState(() {
      _selectedProfileId = profile.id;
      _mode = _ProfileOverlayMode.rename;
    });
  }

  Future<void> _submitCreate() async {
    await widget.onCreateProfile(_profileNameController.text);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedProfileId = controller.activeProfileId;
      _mode = _ProfileOverlayMode.manage;
    });
  }

  Future<void> _submitRename() async {
    final profile = _selectedProfile;
    await widget.onRenameProfile(profile.id, _profileNameController.text);
    if (!mounted) {
      return;
    }
    setState(() {
      _mode = _ProfileOverlayMode.actions;
    });
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.active,
    required this.isDefault,
    required this.onSelect,
  });

  final UserProfileState profile;
  final bool active;
  final bool isDefault;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final tileWidth = (screenWidth * 0.14).clamp(120.0, 160.0);
    return SizedBox(
      width: tileWidth,
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(26),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF171E27) : Colors.transparent,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color:
                  isDefault ? const Color(0xFF94A5B7) : const Color(0xFF24303D),
              width: isDefault ? 3 : 1,
            ),
          ),
          child: Column(
            children: [
              _ProfileAvatar(
                profile: profile,
                size: 114,
                radius: 28,
                fontSize: 40,
              ),
              const SizedBox(height: 10),
              Text(
                profile.name.trim().isEmpty ? 'Perfil' : profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: TanukiColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 24,
                child: Text(
                  isDefault ? 'Predeterminado' : '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFD3DEE8),
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileManagementRow extends StatelessWidget {
  const _ProfileManagementRow({
    required this.profile,
    required this.meta,
    required this.onTap,
  });

  final UserProfileState profile;
  final String meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = profile.name.trim().isEmpty ? 'Perfil' : profile.name;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0x88101923),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x6624303D)),
        ),
        child: Row(
          children: [
            _ProfileAvatar(
              profile: profile,
              size: 52,
              radius: 14,
              fontSize: 23,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TanukiColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta.isEmpty ? 'Perfil guardado' : meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TanukiColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: TanukiColors.subtle),
          ],
        ),
      ),
    );
  }
}

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: Alignment.center,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxButtonWidth =
                (constraints.maxWidth * 0.85).clamp(220.0, 360.0);
            return ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxButtonWidth),
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: onPressed,
                  icon: Icon(icon, color: danger ? TanukiColors.danger : null),
                  label: Text(label),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AvatarPresetButton extends StatelessWidget {
  const _AvatarPresetButton({
    required this.preset,
    required this.label,
    required this.initial,
    required this.selected,
    required this.onTap,
  });

  final _ProfileAvatarPreset preset;
  final String label;
  final String initial;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fallback = _AvatarFallback(
      preset: preset,
      initial: initial,
      fontSize: 28,
      borderRadius: 18,
    );
    return SizedBox(
      width: 92,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF080C12),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? TanukiColors.orange : preset.accentColor,
                  width: selected ? 3 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: preset.assetPath.isEmpty
                  ? fallback
                  : Image.asset(
                      preset.assetPath,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      errorBuilder: (_, __, ___) => fallback,
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: TanukiColors.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({
    required this.preset,
    required this.initial,
    required this.fontSize,
    required this.borderRadius,
  });

  final _ProfileAvatarPreset preset;
  final String initial;
  final double fontSize;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [preset.startColor, preset.endColor],
          ),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              color: preset.textColor,
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.profile,
    required this.size,
    required this.radius,
    required this.fontSize,
    this.borderColor,
  });

  final UserProfileState profile;
  final double size;
  final double radius;
  final double fontSize;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final preset = _profileAvatarPreset(profile.avatarPresetId);
    final fallback = _AvatarFallback(
      preset: preset,
      initial: _profileInitial(profile),
      fontSize: fontSize,
      borderRadius: radius,
    );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF080C12),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? Colors.transparent),
      ),
      child: preset.assetPath.isEmpty
          ? fallback
          : Image.asset(
              preset.assetPath,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }
}

class _ProfileAvatarPreset {
  const _ProfileAvatarPreset({
    required this.id,
    required this.startColor,
    required this.endColor,
    required this.accentColor,
    this.assetPath = '',
  });

  final String id;
  final Color startColor;
  final Color endColor;
  final Color accentColor;
  final String assetPath;
  final Color textColor = TanukiColors.text;
}

const _profileAvatarPresets = [
  _ProfileAvatarPreset(
    id: 'avatar_01',
    assetPath: 'assets/images/avatar_01.png',
    startColor: Color(0xFF8E5A2A),
    endColor: Color(0xFF1C2733),
    accentColor: Color(0xFFECC38C),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_02',
    assetPath: 'assets/images/avatar_02.png',
    startColor: Color(0xFF102B55),
    endColor: Color(0xFF0A1018),
    accentColor: Color(0xFFDDE7F6),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_03',
    assetPath: 'assets/images/avatar_03.png',
    startColor: Color(0xFFD6B844),
    endColor: Color(0xFF1D1C20),
    accentColor: Color(0xFFFCE7A6),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_04',
    assetPath: 'assets/images/avatar_04.png',
    startColor: Color(0xFF182033),
    endColor: Color(0xFF8791A6),
    accentColor: Color(0xFFD6DEEF),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_05',
    assetPath: 'assets/images/avatar_05.png',
    startColor: Color(0xFFAEB8C5),
    endColor: Color(0xFF243128),
    accentColor: Color(0xFFE5EBF4),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_06',
    assetPath: 'assets/images/avatar_06.png',
    startColor: Color(0xFFE38BA5),
    endColor: Color(0xFF9B263C),
    accentColor: Color(0xFFFFD7E1),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_07',
    assetPath: 'assets/images/avatar_07.png',
    startColor: Color(0xFFE4B321),
    endColor: Color(0xFF20252D),
    accentColor: Color(0xFFFFE18F),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_08',
    assetPath: 'assets/images/avatar_08.png',
    startColor: Color(0xFFE3382F),
    endColor: Color(0xFF47121B),
    accentColor: Color(0xFFFFB6B1),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_09',
    assetPath: 'assets/images/avatar_09.png',
    startColor: Color(0xFF9EBDC4),
    endColor: Color(0xFF293B40),
    accentColor: Color(0xFFD4EDF2),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_10',
    assetPath: 'assets/images/avatar_10.png',
    startColor: Color(0xFFE0B23A),
    endColor: Color(0xFF721E24),
    accentColor: Color(0xFFFFD97B),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_11',
    assetPath: 'assets/images/avatar_11.png',
    startColor: Color(0xFF1E2438),
    endColor: Color(0xFFEDEEF6),
    accentColor: Color(0xFFD8D8FF),
  ),
  _ProfileAvatarPreset(
    id: 'avatar_12',
    assetPath: 'assets/images/avatar_12.png',
    startColor: Color(0xFF1E1C22),
    endColor: Color(0xFF6A5B50),
    accentColor: Color(0xFFE2D4C9),
  ),
];

_ProfileAvatarPreset _profileAvatarPreset(String presetId) {
  final normalized = presetId.trim().toLowerCase();
  return _profileAvatarPresets.firstWhere(
    (preset) => preset.id == normalized,
    orElse: () => _profileAvatarPresets.first,
  );
}

String _profileInitial(UserProfileState profile) {
  final name = profile.name.trim();
  return name.isEmpty ? 'P' : name.substring(0, 1).toUpperCase();
}

class _HeroBackground extends StatelessWidget {
  const _HeroBackground({required this.series});

  final SeriesItem? series;

  @override
  Widget build(BuildContext context) {
    final imageUrl = series?.backgroundUrl.isNotEmpty == true
        ? series!.backgroundUrl
        : series?.imageUrl ?? '';
    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl.isNotEmpty)
            _FadeInNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: Opacity(
                opacity: 0.08,
                child: Image.asset('assets/images/tanuki_tv_banner.png',
                    fit: BoxFit.cover),
              ),
            ),
          Container(
            color: const Color(0x66000000),
          ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0x77000000),
                  Color(0x33000000),
                  Color(0x22000000),
                  Color(0x55000000),
                ],
              ),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x22000000), Color(0x88000000)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimePanel extends StatelessWidget {
  const _AnimePanel({
    required this.controller,
    required this.selectedSeries,
    required this.heroPreviewSeries,
    required this.detailBackLabel,
    required this.detailSimilarCandidates,
    required this.detailSimilarStatus,
    required this.detailSimilarLoading,
    required this.detailImporting,
    required this.trendingCandidates,
    required this.trendingLoading,
    required this.movieCandidates,
    required this.moviesLoading,
    required this.scrollOffset,
    required this.onScrollOffset,
    required this.onSeriesCleared,
    required this.onRemoteCandidateSelected,
    required this.onSimilarSeriesRequested,
    required this.onPlayEpisode,
    required this.onOpenSeriesTrailer,
    required this.onPlayTrendingTrailers,
    required this.onStopWatchingSeries,
    required this.onSeriesSelected,
    required this.onPreviewSeries,
    required this.onPreviewRemoteCandidate,
  });

  final AppController controller;
  final SeriesItem? selectedSeries;
  final SeriesItem? heroPreviewSeries;
  final String detailBackLabel;
  final List<RemoteSearchCandidate> detailSimilarCandidates;
  final String detailSimilarStatus;
  final bool detailSimilarLoading;
  final bool detailImporting;
  final List<RemoteSearchCandidate> trendingCandidates;
  final bool trendingLoading;
  final List<RemoteSearchCandidate> movieCandidates;
  final bool moviesLoading;
  final double scrollOffset;
  final ValueChanged<double> onScrollOffset;
  final VoidCallback onSeriesCleared;
  final ValueChanged<RemoteSearchCandidate> onRemoteCandidateSelected;
  final ValueChanged<SeriesItem> onSimilarSeriesRequested;
  final ValueChanged<EpisodeItem> onPlayEpisode;
  final ValueChanged<SeriesItem> onOpenSeriesTrailer;
  final VoidCallback onPlayTrendingTrailers;
  final ValueChanged<SeriesItem> onStopWatchingSeries;
  final ValueChanged<SeriesItem> onSeriesSelected;
  final ValueChanged<SeriesItem> onPreviewSeries;
  final ValueChanged<RemoteSearchCandidate> onPreviewRemoteCandidate;

  @override
  Widget build(BuildContext context) {
    final library = controller.library;
    final hero = selectedSeries ??
        heroPreviewSeries ??
        (library.isEmpty ? null : library.first);
    final continueWatching = _continueWatchingEntries(controller);
    final upcoming = _upcomingCandidates(trendingCandidates);
    final latestMovies = _latestMovieCandidates(
      [...movieCandidates, ...trendingCandidates],
    );

    final screenHeight = MediaQuery.sizeOf(context).height;
    final heroHeight = (screenHeight * 0.36).clamp(320.0, 480.0);
    final topPadding = heroHeight + 18;
    final baseSectionHeight = (screenHeight * 0.3525).clamp(320.0, 480.0);
    final sectionHeight = baseSectionHeight * _homePosterScale;
    const sectionGap = 28.0;
    const fadeDistance = 80.0;

    double sectionOpacity(double sectionTop) {
      final startOffset = sectionTop + topPadding - heroHeight;
      final delta = scrollOffset - startOffset;
      if (delta <= 0) return 1.0;
      if (delta >= fadeDistance) return 0.0;
      return 1.0 - (delta / fadeDistance);
    }

    Widget fadeSection(double sectionTop, Widget child) {
      return Opacity(
        opacity: sectionOpacity(sectionTop),
        child: child,
      );
    }

    final panelChildren = <Widget>[];
    final sectionPadding = (baseSectionHeight * 0.5).clamp(180.0, 240.0);
    panelChildren.add(SizedBox(height: sectionPadding));
    double nextSectionTop = sectionPadding;
    if (continueWatching.isNotEmpty) {
      panelChildren.add(fadeSection(
        nextSectionTop,
        _ContinueWatchingShelf(
          entries: continueWatching,
          onPlayEpisode: onPlayEpisode,
          onStopWatchingSeries: onStopWatchingSeries,
          onGoToSeries: onSeriesSelected,
          onEntryFocused: onPreviewSeries,
        ),
      ));
      panelChildren.add(const SizedBox(height: sectionGap));
      nextSectionTop += sectionHeight + sectionGap;
    }
    if (trendingCandidates.isNotEmpty || trendingLoading) {
      panelChildren.add(fadeSection(
        nextSectionTop,
        _TrendingPosterShelf(
          controller: controller,
          candidates: trendingCandidates,
          loading: trendingLoading,
          onCandidateSelected: onRemoteCandidateSelected,
          onCandidateFocused: onPreviewRemoteCandidate,
          onPlayTrailers: onPlayTrendingTrailers,
        ),
      ));
      panelChildren.add(const SizedBox(height: sectionGap));
      nextSectionTop += sectionHeight + sectionGap;
    }
    if (upcoming.isNotEmpty) {
      panelChildren.add(fadeSection(
        nextSectionTop,
        _UpcomingPosterShelf(
          candidates: upcoming,
          controller: controller,
          onCandidateSelected: onRemoteCandidateSelected,
          onCandidateFocused: onPreviewRemoteCandidate,
        ),
      ));
      panelChildren.add(const SizedBox(height: sectionGap));
      nextSectionTop += sectionHeight + sectionGap;
    }
    if (latestMovies.isNotEmpty || moviesLoading) {
      panelChildren.add(fadeSection(
        nextSectionTop,
        _UpcomingPosterShelf(
          title: 'Ultimas peliculas',
          trailing: moviesLoading && latestMovies.isEmpty
              ? 'Cargando...'
              : '${latestMovies.length} peliculas',
          candidates: latestMovies,
          loading: moviesLoading,
          controller: controller,
          onCandidateSelected: onRemoteCandidateSelected,
          onCandidateFocused: onPreviewRemoteCandidate,
        ),
      ));
      panelChildren.add(const SizedBox(height: sectionGap));
      nextSectionTop += sectionHeight + sectionGap;
    }
    panelChildren.add(SizedBox(height: sectionPadding));
    panelChildren.add(const SizedBox(height: 56));

    if (selectedSeries != null) {
      return Padding(
        padding: const EdgeInsets.only(left: 30, bottom: 16),
        child: _SeriesDetailPanel(
          controller: controller,
          series: selectedSeries!,
          backLabel: detailBackLabel,
          similarCandidates: detailSimilarCandidates,
          similarStatus: detailSimilarStatus,
          similarLoading: detailSimilarLoading,
          detailsLoading: detailImporting,
          onBack: onSeriesCleared,
          onRemoteCandidateSelected: onRemoteCandidateSelected,
          onSimilarSeriesRequested: onSimilarSeriesRequested,
          onPlayEpisode: onPlayEpisode,
          onOpenTrailer: onOpenSeriesTrailer,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 36, bottom: 16),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.depth != 0 ||
                    notification.metrics.axis != Axis.vertical) {
                  return false;
                }
                onScrollOffset(notification.metrics.pixels);
                return false;
              },
              child: SingleChildScrollView(
                clipBehavior: Clip.none,
                padding: EdgeInsets.only(top: heroHeight + 46),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: panelChildren,
                ),
              ),
            ),
          ),
          Positioned(
            left: -20,
            top: -14,
            right: -14,
            height: heroHeight + 56,
            child: const IgnorePointer(child: _HeroFadeOverlay()),
          ),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: _HeroBlock(
              controller: controller,
              series: hero,
              height: heroHeight,
              onPlayEpisode: onPlayEpisode,
              onOpenTrailer: onOpenSeriesTrailer,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroFadeOverlay extends StatelessWidget {
  const _HeroFadeOverlay();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            Colors.transparent,
            Colors.transparent,
            Colors.transparent,
            Colors.transparent,
          ],
          stops: const [0, 0.72, 0.9, 1],
        ),
      ),
    );
  }
}

class _RandomLoadingPanel extends StatelessWidget {
  const _RandomLoadingPanel({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 14, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: loading
                    ? const CircularProgressIndicator(strokeWidth: 3)
                    : const Icon(Icons.shuffle, color: TanukiColors.orange),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  loading ? 'Buscando random...' : 'Random',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: glassDecoration(),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SkeletonLine(width: 240, height: 42),
                        SizedBox(height: 18),
                        _SkeletonLine(width: 360, height: 13),
                        SizedBox(height: 10),
                        _SkeletonLine(width: 320, height: 13),
                        SizedBox(height: 22),
                        _SkeletonLine(width: 140, height: 38),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: glassDecoration(),
                    child: ListView.separated(
                      itemBuilder: (_, __) => const Row(
                        children: [
                          _SkeletonLine(width: 128, height: 72),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _SkeletonLine(
                                    width: double.infinity, height: 12),
                                SizedBox(height: 8),
                                _SkeletonLine(width: 120, height: 10),
                              ],
                            ),
                          ),
                        ],
                      ),
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemCount: 6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const double _homePosterScale = 1.5;

double _homeShelfPosterHeight(
  BuildContext context, {
  double screenFactor = 0.24,
}) {
  final screenHeight = MediaQuery.sizeOf(context).height;
  return (screenHeight * screenFactor).clamp(220.0, 280.0) * _homePosterScale;
}

double _homeResponsiveValue(BuildContext context, double base,
    {double min = 0, double max = double.infinity}) {
  final width = MediaQuery.sizeOf(context).width;
  final scale = (width / 960).clamp(0.88, 1.24);
  final value = base * scale;
  return value.clamp(min == 0 ? base * 0.8 : min, max);
}

class _HorizontalFocusShelf extends StatelessWidget {
  const _HorizontalFocusShelf({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: child,
    );
  }
}

double _heroButtonSide(BuildContext context) =>
    _homeResponsiveValue(context, 48, min: 42, max: 60);

double _heroIconSize(BuildContext context) =>
    _homeResponsiveValue(context, 28, min: 24, max: 34);

double _heroLogoHeight(BuildContext context) =>
    _homeResponsiveValue(context, 72, min: 54, max: 90);

double _heroTitleFontSize(BuildContext context) =>
    _homeResponsiveValue(context, 34, min: 26, max: 42);

class _HeroBlock extends StatelessWidget {
  const _HeroBlock({
    required this.controller,
    required this.series,
    required this.height,
    required this.onPlayEpisode,
    required this.onOpenTrailer,
  });

  final AppController controller;
  final SeriesItem? series;
  final double height;
  final ValueChanged<EpisodeItem> onPlayEpisode;
  final ValueChanged<SeriesItem> onOpenTrailer;

  @override
  Widget build(BuildContext context) {
    final title = series?.name ?? 'Tanuki';
    final meta = _formatHeroMeta(series);
    final rating = _heroRating(series);
    final description = series?.description.trim().isNotEmpty == true
        ? series!.description
        : 'Playlist nocturna, biblioteca local y catalogo anime en una interfaz TV.';
    final nextEpisode =
        series == null ? null : controller.firstPlayableEpisode(series!);
    final maxHeroTextWidth =
        (MediaQuery.sizeOf(context).width * 0.55).clamp(340.0, 520.0);
    return Container(
      height: height,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxHeroTextWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Badge(text: _heroBadge(series)),
                    const SizedBox(height: 10),
                    if (series?.logoUrl.isNotEmpty == true)
                      SizedBox(
                        height: _heroLogoHeight(context),
                        child: _FadeInNetworkImage(
                          imageUrl: series!.logoUrl,
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          errorBuilder: (_, __, ___) =>
                              _HeroTitleFallback(title: title),
                        ),
                      )
                    else if (series == null)
                      Image.asset(
                        'assets/images/tanuki_brand_logo.png',
                        width: (MediaQuery.sizeOf(context).width * 0.27)
                            .clamp(200.0, 280.0),
                        height: _heroLogoHeight(context),
                        fit: BoxFit.contain,
                      )
                    else
                      _HeroTitleFallback(title: title),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFF0B760),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      _compactDescription(description),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (series != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _HeroIconButton(
                  icon: Icons.play_arrow,
                  tooltip: 'Reproducir',
                  onPressed: nextEpisode == null
                      ? null
                      : () => onPlayEpisode(nextEpisode),
                  primary: true,
                ),
                const SizedBox(height: 10),
                _HeroIconButton(
                  icon:
                      controller.isSelected(series!) ? Icons.check : Icons.add,
                  tooltip:
                      controller.isSelected(series!) ? 'Agregada' : 'Agregar',
                  onPressed: () => controller.toggleSeriesSelection(series!),
                ),
                if (series?.trailerUrl.isNotEmpty == true) ...[
                  const SizedBox(height: 10),
                  _HeroIconButton(
                    icon: Icons.movie_filter,
                    tooltip: 'Trailer',
                    onPressed: () => onOpenTrailer(series!),
                  ),
                ],
                if (rating.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _HeroRatingPill(text: rating),
                ],
              ],
            ),
        ],
      ),
    );
  }

  String _heroBadge(SeriesItem? series) {
    final format = series?.format.trim() ?? '';
    return format.isEmpty ? 'ANIME DESTACADO' : format;
  }

  String _formatHeroMeta(SeriesItem? series) {
    if (series == null) {
      return '';
    }
    final parts = [
      if (series.format.isNotEmpty) series.format,
      if (series.releaseYear > 0) '${series.releaseYear}',
      if (series.episodeCount > 0) '${series.episodeCount} eps',
      if (series.rating.isNotEmpty) series.rating,
    ];
    return parts.join(' | ');
  }

  String _heroRating(SeriesItem? series) {
    if (series == null) {
      return 'ANIME';
    }
    final rating = series.rating.trim();
    if (rating.isNotEmpty) {
      return rating;
    }
    final format = series.format.trim();
    return format.isEmpty ? 'ANIME' : format;
  }

  String _compactDescription(String value) {
    final normalized = value.replaceAll('\n', ' ').trim();
    if (normalized.length <= 220) {
      return normalized;
    }
    return '${normalized.substring(0, 217)}...';
  }
}

class _HeroTitleFallback extends StatelessWidget {
  const _HeroTitleFallback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final fontSize = _heroTitleFontSize(context);
    return SizedBox(
      height: fontSize * 2.4,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontSize: fontSize,
                height: 1.04,
              ),
        ),
      ),
    );
  }
}

class _HeroIconButton extends StatelessWidget {
  const _HeroIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final buttonSide = _heroButtonSide(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
        iconSize: _heroIconSize(context),
        style: IconButton.styleFrom(
          fixedSize: Size(buttonSide, buttonSide),
          backgroundColor: primary ? Colors.white : const Color(0x554A5E72),
          foregroundColor: primary ? TanukiColors.background : Colors.white,
          disabledForegroundColor: TanukiColors.subtle,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonSide / 2),
          ),
        ),
      ),
    );
  }
}

class _SeriesDetailPanel extends StatelessWidget {
  const _SeriesDetailPanel({
    required this.controller,
    required this.series,
    required this.backLabel,
    required this.similarCandidates,
    required this.similarStatus,
    required this.similarLoading,
    required this.detailsLoading,
    required this.onBack,
    required this.onRemoteCandidateSelected,
    required this.onSimilarSeriesRequested,
    required this.onPlayEpisode,
    required this.onOpenTrailer,
  });

  final AppController controller;
  final SeriesItem series;
  final String backLabel;
  final List<RemoteSearchCandidate> similarCandidates;
  final String similarStatus;
  final bool similarLoading;
  final bool detailsLoading;
  final VoidCallback onBack;
  final ValueChanged<RemoteSearchCandidate> onRemoteCandidateSelected;
  final ValueChanged<SeriesItem> onSimilarSeriesRequested;
  final ValueChanged<EpisodeItem> onPlayEpisode;
  final ValueChanged<SeriesItem> onOpenTrailer;

  @override
  Widget build(BuildContext context) {
    final nextEpisode = controller.firstPlayableEpisode(series);
    final meta = _seriesMeta(series);
    final description = series.description.trim().isEmpty
        ? 'Sin sinopsis disponible.'
        : series.description.replaceAll('\n', ' ').trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenHeight = MediaQuery.sizeOf(context).height;
        final wide = constraints.maxWidth >= 900;
        final episodePanelHeight = (screenHeight * 0.55).clamp(320.0, 560.0);
        final episodePanelWidth =
            (constraints.maxWidth * 0.38).clamp(380.0, 560.0);
        final info = _SeriesDetailInfo(
          controller: controller,
          series: series,
          meta: meta,
          description: description,
          nextEpisode: nextEpisode,
          backLabel: backLabel,
          detailsLoading: detailsLoading,
          onBack: onBack,
          onSimilarSeriesRequested: onSimilarSeriesRequested,
          onPlayEpisode: onPlayEpisode,
          onOpenTrailer: onOpenTrailer,
        );
        final similar = _DetailSimilarCarousel(
          controller: controller,
          candidates: similarCandidates,
          status: similarStatus,
          loading: similarLoading,
          onCandidateSelected: onRemoteCandidateSelected,
        );
        final episodes = _DetailEpisodesColumn(
          controller: controller,
          series: series,
          onPlayEpisode: onPlayEpisode,
        );
        if (!wide) {
          return SingleChildScrollView(
            clipBehavior: Clip.none,
            child: Column(
              children: [
                info,
                const SizedBox(height: 18),
                similar,
                const SizedBox(height: 18),
                SizedBox(height: episodePanelHeight, child: episodes),
              ],
            ),
          );
        }
        return SizedBox(
          height: MediaQuery.sizeOf(context).height - 28,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRect(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        info,
                        const SizedBox(height: 18),
                        similar,
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SizedBox(width: episodePanelWidth, child: episodes),
              ),
            ],
          ),
        );
      },
    );
  }

  String _seriesMeta(SeriesItem series) {
    final parts = [
      series.sourceType == SourceType.local
          ? 'LOCAL'
          : series.provider?.label ?? 'REMOTO',
      if (series.releaseYear > 0) '${series.releaseYear}',
      if (series.format.isNotEmpty) series.format,
      '${series.episodeCount} episodios',
      if (series.rating.isNotEmpty) 'Score ${series.rating}',
    ];
    return parts.join(' | ');
  }
}

class _SeriesDetailInfo extends StatelessWidget {
  const _SeriesDetailInfo({
    required this.controller,
    required this.series,
    required this.meta,
    required this.description,
    required this.nextEpisode,
    required this.backLabel,
    required this.detailsLoading,
    required this.onBack,
    required this.onSimilarSeriesRequested,
    required this.onPlayEpisode,
    required this.onOpenTrailer,
  });

  final AppController controller;
  final SeriesItem series;
  final String meta;
  final String description;
  final EpisodeItem? nextEpisode;
  final String backLabel;
  final bool detailsLoading;
  final VoidCallback onBack;
  final ValueChanged<SeriesItem> onSimilarSeriesRequested;
  final ValueChanged<EpisodeItem> onPlayEpisode;
  final ValueChanged<SeriesItem> onOpenTrailer;

  @override
  Widget build(BuildContext context) {
    final status = controller.spaceStatusFor(series);
    final hasLogo = series.logoUrl.isNotEmpty;
    final cast = series.cast
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();
    final posterUrl = series.imageUrl.trim();
    final castBlock =
        cast.isEmpty ? null : _DetailCastBlock(cast: cast.take(10).toList());
    final hasDescription = series.description.trim().isNotEmpty;
    Widget buildInfoColumn({
      required bool wide,
      bool alignCastBottom = false,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            meta,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFF0B760),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          if (detailsLoading && !hasDescription)
            const _DetailSkeletonLines()
          else
            Text(
              description,
              maxLines: wide ? 9 : 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFE7EEF6),
                fontSize: 15,
                height: 1.35,
              ),
            ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _DetailIconButton(
                icon: controller.isFavorite(series)
                    ? Icons.favorite
                    : Icons.favorite_border,
                tooltip: 'Favorito',
                active: controller.isFavorite(series),
                onPressed: () => controller.toggleFavorite(series),
              ),
              _DetailIconButton(
                icon: controller.isSelected(series)
                    ? Icons.playlist_add_check
                    : Icons.playlist_add,
                tooltip: 'Playlist',
                active: controller.isSelected(series),
                onPressed: () => controller.toggleSeriesSelection(series),
              ),
              _DetailSpaceButton(
                value: status,
                onChanged: (value) => controller.setSpaceStatus(series, value),
              ),
              if (series.trailerUrl.isNotEmpty)
                _DetailIconButton(
                  icon: Icons.movie_filter,
                  tooltip: 'Trailer',
                  active: true,
                  onPressed: () => onOpenTrailer(series),
                ),
              _DetailIconButton(
                icon: Icons.travel_explore,
                tooltip: 'Similares',
                active: false,
                onPressed: () => onSimilarSeriesRequested(series),
              ),
              _DetailIconButton(
                icon: Icons.play_arrow,
                tooltip: 'Reproducir',
                active: true,
                onPressed: nextEpisode == null
                    ? null
                    : () => onPlayEpisode(nextEpisode!),
              ),
            ],
          ),
          if (castBlock != null) ...[
            if (alignCastBottom) const Spacer() else const SizedBox(height: 18),
            castBlock,
          ],
        ],
      );
    }

    Widget buildPoster(double width) {
      return SizedBox(
        width: width,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: posterUrl.isEmpty && detailsLoading
              ? const _DetailSkeletonBox()
              : _Poster(
                  imageUrl: posterUrl,
                  title: series.name,
                ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: Text(backLabel),
            ),
          ),
          const SizedBox(height: 6),
          if (detailsLoading) ...[
            const SizedBox(
              width: 180,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: TanukiColors.orange,
                backgroundColor: Color(0x22334A62),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (hasLogo) ...[
            SizedBox(
              height: 76,
              child: _FadeInNetworkImage(
                imageUrl: series.logoUrl,
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              series.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: TanukiColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ] else ...[
            const SizedBox(height: 20),
            Text(
              series.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineLarge,
            ),
          ],
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final hasPosterSlot = posterUrl.isNotEmpty || detailsLoading;
              final horizontal = hasPosterSlot && constraints.maxWidth >= 680;
              if (!horizontal) {
                final posterWidth =
                    (constraints.maxWidth * 0.62).clamp(150.0, 220.0);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasPosterSlot) ...[
                      buildPoster(posterWidth),
                      const SizedBox(height: 16),
                    ],
                    buildInfoColumn(wide: false),
                  ],
                );
              }
              final posterWidth =
                  (constraints.maxWidth * 0.24).clamp(160.0, 250.0);
              final posterHeight = posterWidth * 1.5;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildPoster(posterWidth),
                  const SizedBox(width: 24),
                  Expanded(
                    child: SizedBox(
                      height: posterHeight,
                      child: buildInfoColumn(
                        wide: true,
                        alignCastBottom: true,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DetailSkeletonBox extends StatelessWidget {
  const _DetailSkeletonBox();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x33233445),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x22334A62)),
      ),
    );
  }
}

class _DetailSkeletonLines extends StatelessWidget {
  const _DetailSkeletonLines();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DetailSkeletonLine(widthFactor: 0.92),
        SizedBox(height: 8),
        _DetailSkeletonLine(widthFactor: 0.78),
        SizedBox(height: 8),
        _DetailSkeletonLine(widthFactor: 0.54),
      ],
    );
  }
}

class _DetailSkeletonLine extends StatelessWidget {
  const _DetailSkeletonLine({required this.widthFactor});

  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: const SizedBox(
        height: 13,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color(0x33233445),
            borderRadius: BorderRadius.all(Radius.circular(999)),
          ),
        ),
      ),
    );
  }
}

class _DetailCastBlock extends StatelessWidget {
  const _DetailCastBlock({required this.cast});

  final List<String> cast;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: glassDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Cast', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            cast.join('   '),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFC5D3E0), height: 1.25),
          ),
        ],
      ),
    );
  }
}

class _DetailSimilarCarousel extends StatelessWidget {
  const _DetailSimilarCarousel({
    required this.controller,
    required this.candidates,
    required this.status,
    required this.loading,
    required this.onCandidateSelected,
  });

  final AppController controller;
  final List<RemoteSearchCandidate> candidates;
  final String status;
  final bool loading;
  final ValueChanged<RemoteSearchCandidate> onCandidateSelected;

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final posterHeight = (screenHeight * 0.225).clamp(200.0, 240.0);
    final posterWidth = posterHeight * 0.7;
    final visibleStatus = status.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Similares', style: Theme.of(context).textTheme.titleLarge),
        if (visibleStatus.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            visibleStatus,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: TanukiColors.muted, fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        SizedBox(
          height: posterHeight + 16,
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : candidates.isEmpty
                  ? const _EmptyState(
                      icon: Icons.travel_explore,
                      title: 'Sin similares',
                      message:
                          'No encontre series relacionadas para esta ficha.',
                    )
                  : _HorizontalFocusShelf(
                      child: ListView.separated(
                        clipBehavior: Clip.hardEdge,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(0, 2, 18, 6),
                        itemBuilder: (context, index) {
                          final candidate = candidates[index];
                          return SizedBox(
                            width: posterWidth,
                            height: posterHeight,
                            child: _SearchResultPosterCard(
                              candidate: candidate,
                              imported: controller.findRemoteSeriesForCandidate(
                                    candidate,
                                  ) !=
                                  null,
                              onTap: () => onCandidateSelected(candidate),
                            ),
                          );
                        },
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemCount: candidates.length,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _SimilarPanel extends StatelessWidget {
  const _SimilarPanel({
    required this.controller,
    required this.series,
    required this.candidates,
    required this.status,
    required this.loading,
    required this.onBack,
    required this.onRemoteCandidateSelected,
  });

  final AppController controller;
  final SeriesItem? series;
  final List<RemoteSearchCandidate> candidates;
  final String status;
  final bool loading;
  final VoidCallback onBack;
  final ValueChanged<RemoteSearchCandidate> onRemoteCandidateSelected;

  @override
  Widget build(BuildContext context) {
    final title = series == null ? 'Similares' : 'Similares a ${series!.name}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Detalle'),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            status,
            style: const TextStyle(color: TanukiColors.muted, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : candidates.isEmpty
                    ? const _EmptyState(
                        icon: Icons.travel_explore,
                        title: 'Sin similares',
                        message:
                            'No encontre series relacionadas para esta ficha.',
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          var columns = constraints.maxWidth ~/ 166;
                          if (columns < 2) {
                            columns = 2;
                          } else if (columns > 5) {
                            columns = 5;
                          }
                          return GridView.builder(
                            clipBehavior: Clip.none,
                            padding:
                                const EdgeInsets.only(bottom: 12, right: 8),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              mainAxisExtent: 208,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            itemCount: candidates.length,
                            itemBuilder: (context, index) {
                              final candidate = candidates[index];
                              return _SearchResultPosterCard(
                                candidate: candidate,
                                imported:
                                    controller.findRemoteSeriesForCandidate(
                                            candidate) !=
                                        null,
                                onTap: () =>
                                    onRemoteCandidateSelected(candidate),
                              );
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

enum _DetailEpisodeAction {
  markCompleted,
  completeThrough,
}

class _DetailEpisodesColumn extends StatelessWidget {
  const _DetailEpisodesColumn({
    required this.controller,
    required this.series,
    required this.onPlayEpisode,
  });

  final AppController controller;
  final SeriesItem series;
  final ValueChanged<EpisodeItem> onPlayEpisode;

  @override
  Widget build(BuildContext context) {
    final watched = controller.watchedCountFor(series);
    return Container(
      padding: const EdgeInsets.all(16),
      clipBehavior: Clip.hardEdge,
      decoration: glassDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Episodios', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            '$watched vistos de ${series.episodeCount}',
            style: const TextStyle(color: TanukiColors.muted, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              clipBehavior: Clip.hardEdge,
              padding: const EdgeInsets.only(top: 4, bottom: 6),
              itemCount: series.episodes.length,
              itemBuilder: (context, index) {
                final episode = series.episodes[index];
                final future = _episodeAirsInFuture(episode.airDateIso);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _DetailEpisodeRow(
                    controller: controller,
                    series: series,
                    episode: episode,
                    enabled: !future,
                    onPlay: future ? null : () => onPlayEpisode(episode),
                    onOptions: future
                        ? null
                        : () => _showEpisodeActions(context, episode),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showEpisodeActions(
    BuildContext context,
    EpisodeItem episode,
  ) async {
    final action = await showModalBottomSheet<_DetailEpisodeAction>(
      context: context,
      backgroundColor: TanukiColors.panelSolid,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Marcar capitulo como completado'),
                onTap: () => Navigator.of(context)
                    .pop(_DetailEpisodeAction.markCompleted),
              ),
              ListTile(
                leading: const Icon(Icons.done_all),
                title: const Text('Completar capitulos hasta este'),
                onTap: () => Navigator.of(context)
                    .pop(_DetailEpisodeAction.completeThrough),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == null || !context.mounted) {
      return;
    }
    switch (action) {
      case _DetailEpisodeAction.markCompleted:
        await controller.markEpisodePlayed(episode);
        break;
      case _DetailEpisodeAction.completeThrough:
        await controller.markSeriesPlayedThrough(series, episode);
        break;
    }
  }
}

class _DetailEpisodeRow extends StatelessWidget {
  const _DetailEpisodeRow({
    required this.controller,
    required this.series,
    required this.episode,
    required this.enabled,
    required this.onPlay,
    required this.onOptions,
  });

  final AppController controller;
  final SeriesItem series;
  final EpisodeItem episode;
  final bool enabled;
  final VoidCallback? onPlay;
  final VoidCallback? onOptions;

  @override
  Widget build(BuildContext context) {
    final playback = controller.playbackForEpisode(episode);
    final watched = controller.watchedCountFor(series) > episode.episodeIndex;
    final progress = _progressFor(playback, watched);
    final scheduleLabel = _scheduleChipLabel(episode.airDateIso);
    final summary = episode.description.trim().isNotEmpty
        ? episode.description.replaceAll('\n', ' ').trim()
        : episode.relativePath;
    final content = Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '${episode.episodeNumber}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: enabled ? const Color(0xFFD6E1EA) : TanukiColors.subtle,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            height: 84,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Poster(
                  imageUrl: episode.imageUrl.trim().isNotEmpty
                      ? episode.imageUrl
                      : series.imageUrl,
                  title: episode.displayName,
                ),
                if (!enabled) const ColoredBox(color: Color(0x99000000)),
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: ColoredBox(
                    color: Color(0xFF38495B),
                    child: SizedBox(width: double.infinity, height: 3),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress,
                    alignment: Alignment.centerLeft,
                    child: const ColoredBox(
                      color: TanukiColors.orange,
                      child: SizedBox(height: 3),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  episode.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: enabled ? TanukiColors.text : TanukiColors.subtle,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _episodeMetaLabel(episode),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        enabled ? const Color(0xFFF0B760) : TanukiColors.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled ? summary : 'Disponible cuando se estrene.',
                  maxLines: episode.description.trim().isNotEmpty ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        enabled ? const Color(0xFFC5D3E0) : TanukiColors.muted,
                    fontSize: 9,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!enabled)
                const _ScheduleChip(text: 'Prox.')
              else if (scheduleLabel.isNotEmpty)
                _ScheduleChip(text: scheduleLabel),
              if ((scheduleLabel.isNotEmpty || !enabled) &&
                  _EpisodeTagChip.hasTag(episode.episodeTag))
                const SizedBox(height: 6),
              if (_EpisodeTagChip.hasTag(episode.episodeTag))
                _EpisodeTagChip(tag: episode.episodeTag),
              const SizedBox(height: 6),
              Text(
                _durationLabel(playback, episode),
                style: TextStyle(
                  color: enabled ? TanukiColors.text : TanukiColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return _FocusableEpisodeSurface(
      enabled: enabled,
      onTap: onPlay,
      onLongPress: onOptions,
      color: enabled ? const Color(0xFF11161D) : const Color(0xFF0B0F14),
      elevation: enabled ? 6 : 1,
      activeElevation: enabled ? 9 : 1,
      child: content,
    );
  }

  double _progressFor(EpisodePlaybackRecord? playback, bool watched) {
    if (playback?.completed == true || watched) {
      return 1;
    }
    final duration = playback?.durationMs ?? 0;
    final position = playback?.positionMs ?? 0;
    if (duration <= 0 || position <= 0) {
      return 0;
    }
    return (position / duration).clamp(0, 1).toDouble();
  }

  String _episodeMetaLabel(EpisodeItem episode) {
    final source = episode.sourceType == SourceType.local
        ? 'LOCAL'
        : episode.provider?.label ?? 'REMOTO';
    final date = _episodeAirDateLabel(episode.airDateIso);
    return date.isEmpty ? source : '$source | $date';
  }

  String _episodeAirDateLabel(String value) {
    final normalized = value.trim();
    if (normalized.length >= 10) {
      return normalized.substring(0, 10);
    }
    return normalized;
  }

  String _durationLabel(EpisodePlaybackRecord? playback, EpisodeItem episode) {
    final explicit = episode.durationLabel.trim();
    if (explicit.isNotEmpty) {
      return explicit;
    }
    final durationMs = playback?.durationMs ?? 0;
    if (durationMs <= 0) {
      return '24 min';
    }
    final minutes = Duration(milliseconds: durationMs).inMinutes;
    return '${minutes <= 0 ? 1 : minutes} min';
  }
}

class _DetailIconButton extends StatelessWidget {
  const _DetailIconButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          fixedSize: const Size(42, 42),
          backgroundColor:
              active ? TanukiColors.orangeHot : const Color(0xFF223041),
          foregroundColor: active ? Colors.black : TanukiColors.text,
          disabledForegroundColor: TanukiColors.subtle,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(21)),
        ),
      ),
    );
  }
}

class _DetailSpaceButton extends StatelessWidget {
  const _DetailSpaceButton({
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final normalized = value.trim();
    final colors = _spaceStatusColors(normalized);
    return Tooltip(
      message: _spaceStatusTooltip(normalized),
      child: IconButton(
        onPressed: () => _showSpaceDialog(context),
        icon: Icon(_spaceStatusIcon(normalized)),
        style: IconButton.styleFrom(
          fixedSize: const Size(42, 42),
          backgroundColor: colors.background,
          foregroundColor: colors.foreground,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(21)),
        ),
      ),
    );
  }

  Future<void> _showSpaceDialog(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: TanukiColors.panelSolid,
          title: const Text(
            'Mi espacio',
            style: TextStyle(
              color: TanukiColors.text,
              fontWeight: FontWeight.w900,
            ),
          ),
          contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SpaceDialogOption(
                label: 'Quiero ver',
                icon: Icons.bookmark_add,
                color: const Color(0xFF6FC2FF),
                onTap: () => Navigator.of(context).pop('want_to_watch'),
              ),
              _SpaceDialogOption(
                label: 'Viendo',
                icon: Icons.visibility,
                color: TanukiColors.orange,
                onTap: () => Navigator.of(context).pop('watching'),
              ),
              _SpaceDialogOption(
                label: 'Abandonada',
                icon: Icons.visibility_off,
                color: const Color(0xFFFF8F9D),
                onTap: () => Navigator.of(context).pop('abandoned'),
              ),
              _SpaceDialogOption(
                label: 'Completada',
                icon: Icons.check_circle,
                color: const Color(0xFF72E0A0),
                onTap: () => Navigator.of(context).pop('completed'),
              ),
              if (value.trim().isNotEmpty)
                _SpaceDialogOption(
                  label: 'Quitar de Mi espacio',
                  icon: Icons.remove_circle_outline,
                  color: TanukiColors.muted,
                  onTap: () => Navigator.of(context).pop(''),
                ),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      onChanged(selected);
    }
  }

  String _spaceStatusTooltip(String status) {
    return switch (status) {
      'want_to_watch' => 'Mi espacio: Quiero ver',
      'watching' => 'Mi espacio: Viendo',
      'abandoned' => 'Mi espacio: Abandonada',
      'completed' => 'Mi espacio: Completada',
      _ => 'Mi espacio',
    };
  }

  IconData _spaceStatusIcon(String status) {
    return switch (status) {
      'want_to_watch' => Icons.bookmark_add,
      'watching' => Icons.visibility,
      'abandoned' => Icons.visibility_off,
      'completed' => Icons.check_circle,
      _ => Icons.assignment_ind,
    };
  }

  ({Color background, Color foreground}) _spaceStatusColors(String status) {
    return switch (status) {
      'want_to_watch' => (
          background: const Color(0xFF14344C),
          foreground: const Color(0xFF6FC2FF),
        ),
      'watching' => (
          background: const Color(0xFF332915),
          foreground: TanukiColors.orange,
        ),
      'abandoned' => (
          background: const Color(0xFF3D2027),
          foreground: const Color(0xFFFF8F9D),
        ),
      'completed' => (
          background: const Color(0xFF173B2B),
          foreground: const Color(0xFF72E0A0),
        ),
      _ => (
          background: const Color(0xFF151A21),
          foreground: TanukiColors.text,
        ),
    };
  }
}

class _SpaceDialogOption extends StatelessWidget {
  const _SpaceDialogOption({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        label,
        style: const TextStyle(
          color: TanukiColors.text,
          fontWeight: FontWeight.w800,
        ),
      ),
      onTap: onTap,
    );
  }
}

class _TrendingPosterShelf extends StatelessWidget {
  const _TrendingPosterShelf({
    required this.controller,
    required this.candidates,
    required this.loading,
    required this.onCandidateSelected,
    required this.onCandidateFocused,
    required this.onPlayTrailers,
  });

  final AppController controller;
  final List<RemoteSearchCandidate> candidates;
  final bool loading;
  final ValueChanged<RemoteSearchCandidate> onCandidateSelected;
  final ValueChanged<RemoteSearchCandidate> onCandidateFocused;
  final VoidCallback onPlayTrailers;

  @override
  Widget build(BuildContext context) {
    final posterHeight = _homeShelfPosterHeight(context);
    final posterWidth = posterHeight * 0.7;
    final visibleCandidates = candidates.take(14).toList(growable: false);
    void focusCandidate(RemoteSearchCandidate candidate) {
      _ensureFocusedShelfVisible(context);
      onCandidateFocused(candidate);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SectionHeader(
                title: 'Tendencias',
                trailing: loading
                    ? 'Cargando portada...'
                    : '${visibleCandidates.length} series',
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: visibleCandidates.any(
                        (candidate) => candidate.trailerUrl.isNotEmpty,
                      ) &&
                      !loading
                  ? onPlayTrailers
                  : null,
              icon: const Icon(Icons.movie_filter),
              tooltip: 'Reproducir trailers',
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: posterHeight + 16,
          child: loading && visibleCandidates.isEmpty
              ? _PosterShelfSkeleton(width: posterWidth, height: posterHeight)
              : _HorizontalFocusShelf(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.fromLTRB(16, 2, 18, 6),
                    itemBuilder: (context, index) {
                      final candidate = visibleCandidates[index];
                      return _RemotePosterCard(
                        width: posterWidth,
                        height: posterHeight,
                        candidate: candidate,
                        imported: controller.findRemoteSeriesForCandidate(
                              candidate,
                            ) !=
                            null,
                        onTap: () => onCandidateSelected(candidate),
                        onFocused: () => focusCandidate(candidate),
                      );
                    },
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemCount: visibleCandidates.length,
                  ),
                ),
        ),
      ],
    );
  }
}

class _RemotePosterCard extends StatelessWidget {
  const _RemotePosterCard({
    required this.width,
    required this.height,
    required this.candidate,
    required this.imported,
    required this.onTap,
    required this.onFocused,
  });

  final double width;
  final double height;
  final RemoteSearchCandidate candidate;
  final bool imported;
  final VoidCallback onTap;
  final VoidCallback onFocused;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: _SearchResultPosterCard(
        candidate: candidate,
        imported: imported,
        onTap: onTap,
        onFocused: onFocused,
        onLongPress: () => _showCardMenu(context),
      ),
    );
  }

  Future<void> _showCardMenu(BuildContext context) async {
    final selected = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF101821),
      builder: (context) {
        return SafeArea(
          child: ListTile(
            leading: const Icon(Icons.tv, color: TanukiColors.orange),
            title: const Text(
              'Ir a serie',
              style: TextStyle(
                color: TanukiColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
            subtitle: Text(
              candidate.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: TanukiColors.muted),
            ),
            onTap: () => Navigator.of(context).pop(true),
          ),
        );
      },
    );
    if (selected == true) {
      onTap();
    }
  }
}

class _UpcomingPosterShelf extends StatelessWidget {
  const _UpcomingPosterShelf({
    this.title = 'Proximos estrenos',
    this.trailing,
    this.loading = false,
    required this.candidates,
    required this.controller,
    required this.onCandidateSelected,
    required this.onCandidateFocused,
  });

  final String title;
  final String? trailing;
  final bool loading;
  final List<RemoteSearchCandidate> candidates;
  final AppController controller;
  final ValueChanged<RemoteSearchCandidate> onCandidateSelected;
  final ValueChanged<RemoteSearchCandidate> onCandidateFocused;

  @override
  Widget build(BuildContext context) {
    final posterHeight = _homeShelfPosterHeight(context);
    final posterWidth = posterHeight * 0.7;

    void focusCandidate(RemoteSearchCandidate candidate) {
      _ensureFocusedShelfVisible(context);
      onCandidateFocused(candidate);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: title,
          trailing: trailing ?? '${candidates.length} fechas',
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: posterHeight + 16,
          child: loading && candidates.isEmpty
              ? _PosterShelfSkeleton(width: posterWidth, height: posterHeight)
              : _HorizontalFocusShelf(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.fromLTRB(16, 2, 18, 6),
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      return _RemotePosterCard(
                        width: posterWidth,
                        height: posterHeight,
                        candidate: candidate,
                        imported: controller.findRemoteSeriesForCandidate(
                              candidate,
                            ) !=
                            null,
                        onTap: () => onCandidateSelected(candidate),
                        onFocused: () => focusCandidate(candidate),
                      );
                    },
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemCount: candidates.length,
                  ),
                ),
        ),
      ],
    );
  }
}

class _PosterShelfSkeleton extends StatelessWidget {
  const _PosterShelfSkeleton({
    required this.width,
    required this.height,
  });

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return _HorizontalFocusShelf(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 18, 6),
        itemBuilder: (_, __) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF233445),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: 6,
      ),
    );
  }
}

class _SearchGridSkeleton extends StatelessWidget {
  const _SearchGridSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            (constraints.maxWidth / 184).floor().clamp(4, 7).toInt();
        const spacing = 6.0;
        final cardWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var index = 0; index < columns * 2; index++)
              SizedBox(
                width: cardWidth,
                height: (cardWidth * 1.5).clamp(208.0, 340.0),
                child: _PosterSkeletonCard(),
              ),
          ],
        );
      },
    );
  }
}

class _PosterSkeletonCard extends StatelessWidget {
  const _PosterSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF182536),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x55334A62)),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 5,
            top: 5,
            child: Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                color: Color(0xFF233445),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 54,
              padding: const EdgeInsets.fromLTRB(7, 7, 7, 7),
              color: const Color(0xB010161D),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonLine(width: 54, height: 12),
                  SizedBox(height: 7),
                  _SkeletonLine(width: double.infinity, height: 11),
                  SizedBox(height: 5),
                  _SkeletonLine(width: 92, height: 9),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({
    required this.width,
    required this.height,
  });

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF2B3B4D),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _ContinueWatchingShelf extends StatelessWidget {
  const _ContinueWatchingShelf({
    required this.entries,
    required this.onPlayEpisode,
    required this.onStopWatchingSeries,
    required this.onGoToSeries,
    required this.onEntryFocused,
  });

  final List<_ContinueWatchingEntry> entries;
  final ValueChanged<EpisodeItem> onPlayEpisode;
  final ValueChanged<SeriesItem> onStopWatchingSeries;
  final ValueChanged<SeriesItem> onGoToSeries;
  final ValueChanged<SeriesItem> onEntryFocused;

  @override
  Widget build(BuildContext context) {
    final posterHeight = _homeShelfPosterHeight(context, screenFactor: 0.235);
    final posterWidth = posterHeight * 0.7;

    void focusEntry(_ContinueWatchingEntry entry) {
      _ensureFocusedShelfVisible(context);
      final series = entry.series;
      if (series != null) {
        onEntryFocused(series);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: 'Continuar viendo',
          trailing: '${entries.length} series',
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: posterHeight + 16,
          child: _HorizontalFocusShelf(
            child: ListView.separated(
              clipBehavior: Clip.none,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 2, 18, 6),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return _ContinueWatchingPosterCard(
                  width: posterWidth,
                  height: posterHeight,
                  entry: entry,
                  onTap: () => onPlayEpisode(entry.episode),
                  onGoToSeries: entry.series == null
                      ? null
                      : () => onGoToSeries(entry.series!),
                  onStopWatching: entry.series == null
                      ? null
                      : () => onStopWatchingSeries(entry.series!),
                  onFocused: () => focusEntry(entry),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemCount: entries.length,
            ),
          ),
        ),
      ],
    );
  }
}

class _ContinueWatchingPosterCard extends StatelessWidget {
  const _ContinueWatchingPosterCard({
    required this.width,
    required this.height,
    required this.entry,
    required this.onTap,
    required this.onGoToSeries,
    required this.onStopWatching,
    required this.onFocused,
  });

  final double width;
  final double height;
  final _ContinueWatchingEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onGoToSeries;
  final VoidCallback? onStopWatching;
  final VoidCallback? onFocused;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: _FocusablePosterSurface(
        onTap: onTap,
        onFocused: onFocused,
        onLongPress: onGoToSeries == null && onStopWatching == null
            ? null
            : () => _showCardMenu(context),
        elevation: 6,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Poster(imageUrl: entry.imageUrl, title: entry.seriesName),
            Positioned(
              left: 5,
              top: 5,
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xD6101822),
                  shape: BoxShape.circle,
                  border: Border.all(color: TanukiColors.orangeHot, width: 2),
                ),
                child: Text(
                  entry.episodeCount > 0 ? '${entry.episodeCount}' : '?',
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  style: const TextStyle(
                    color: TanukiColors.text,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                minHeight: 3,
                value: entry.progress.clamp(0, 1).toDouble(),
                backgroundColor: const Color(0xFF38495B),
                valueColor:
                    const AlwaysStoppedAnimation<Color>(TanukiColors.orange),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 3,
              child: Container(
                padding: const EdgeInsets.fromLTRB(7, 6, 7, 7),
                color: const Color(0xB010161D),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.seriesName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: TanukiColors.text,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatContinueWatchingMeta(entry),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB1C0CF),
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCardMenu(BuildContext context) async {
    final selected = await showModalBottomSheet<_ContinueWatchingAction>(
      context: context,
      backgroundColor: const Color(0xFF101821),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onGoToSeries != null)
                ListTile(
                  leading: const Icon(Icons.tv, color: TanukiColors.orange),
                  title: const Text(
                    'Ir a serie',
                    style: TextStyle(
                      color: TanukiColors.text,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: Text(
                    entry.seriesName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: TanukiColors.muted),
                  ),
                  onTap: () => Navigator.of(context)
                      .pop(_ContinueWatchingAction.goToSeries),
                ),
              if (onStopWatching != null)
                ListTile(
                  leading: const Icon(
                    Icons.visibility_off,
                    color: TanukiColors.orange,
                  ),
                  title: const Text(
                    'Dejar de ver',
                    style: TextStyle(
                      color: TanukiColors.text,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: Text(
                    entry.seriesName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: TanukiColors.muted),
                  ),
                  onTap: () => Navigator.of(context)
                      .pop(_ContinueWatchingAction.stopWatching),
                ),
            ],
          ),
        );
      },
    );
    if (selected == _ContinueWatchingAction.goToSeries) {
      onGoToSeries?.call();
    } else if (selected == _ContinueWatchingAction.stopWatching) {
      onStopWatching?.call();
    }
  }
}

enum _ContinueWatchingAction {
  goToSeries,
  stopWatching,
}

class _PlaylistPanel extends StatelessWidget {
  const _PlaylistPanel({
    required this.controller,
    required this.onSeriesSelected,
    required this.onPlayEpisode,
  });

  final AppController controller;
  final ValueChanged<SeriesItem> onSeriesSelected;
  final ValueChanged<EpisodeItem> onPlayEpisode;

  @override
  Widget build(BuildContext context) {
    final entries = controller.buildNextEntries(limit: 12);
    final selected = _dedupeSeriesForDisplay(
        controller.library.where(controller.isSelected));
    final current =
        controller.currentEntry ?? (entries.isEmpty ? null : entries.first);
    final playlistOrder = PlaylistPlaybackOrder.normalize(
        controller.activePlaylist.playbackOrder);
    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            current?.seriesName ?? controller.activePlaylist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            current == null
                ? 'Selecciona series desde Biblioteca o Buscar.'
                : 'Episodio ${current.episodeNumber} - ${current.displayName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: TanukiColors.muted,
                ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                onPressed:
                    current == null ? null : () => onPlayEpisode(current),
                icon: const Icon(Icons.play_arrow),
                style: IconButton.styleFrom(
                  fixedSize: const Size(44, 44),
                  backgroundColor: const Color(0xFF1A2332),
                  foregroundColor: TanukiColors.text,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                tooltip: 'Reproducir actual',
              ),
              FilledButton(
                onPressed:
                    entries.isEmpty ? null : () => onPlayEpisode(entries.first),
                child: const Text('Reproducir siguiente'),
              ),
              OutlinedButton(
                onPressed: () {},
                child: const Text('Listas'),
              ),
              _PlaylistOrderChip(
                label: 'TV',
                selected: playlistOrder == PlaylistPlaybackOrder.tv,
                onPressed: () => controller.setActivePlaylistPlaybackOrder(
                  PlaylistPlaybackOrder.tv,
                ),
              ),
              _PlaylistOrderChip(
                label: 'Por serie',
                selected: playlistOrder == PlaylistPlaybackOrder.series,
                onPressed: () => controller.setActivePlaylistPlaybackOrder(
                  PlaylistPlaybackOrder.series,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 780;
                final queue = _PlaylistColumn(
                  title: 'Siguiente en la lista',
                  emptyText: 'No hay episodios pendientes.',
                  child: entries.isEmpty
                      ? null
                      : ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return _QueueRow(
                              episode: entry,
                              onPlay: () => onPlayEpisode(entry),
                            );
                          },
                        ),
                );
                final seriesColumn = _PlaylistColumn(
                  title: 'Animes agregados',
                  emptyText: 'No hay series seleccionadas.',
                  child: selected.isEmpty
                      ? null
                      : ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: selected.length,
                          itemBuilder: (context, index) {
                            final series = selected[index];
                            return _MiniSeriesTile(
                              controller: controller,
                              series: series,
                              onTap: () => onSeriesSelected(series),
                            );
                          },
                        ),
                );
                if (!wide) {
                  final screenHeight = MediaQuery.sizeOf(context).height;
                  final queueHeight = (screenHeight * 0.45).clamp(250.0, 420.0);
                  final seriesHeight =
                      (screenHeight * 0.38).clamp(220.0, 360.0);
                  return ListView(
                    children: [
                      SizedBox(height: queueHeight, child: queue),
                      const SizedBox(height: 16),
                      SizedBox(height: seriesHeight, child: seriesColumn),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: queue),
                    const SizedBox(width: 16),
                    Expanded(child: seriesColumn),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistOrderChip extends StatelessWidget {
  const _PlaylistOrderChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: OutlinedButton(
        onPressed: selected ? null : onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? TanukiColors.orange : null,
          foregroundColor: selected ? Colors.black : TanukiColors.text,
          disabledBackgroundColor: TanukiColors.orange,
          disabledForegroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
        ),
        child: Text(label),
      ),
    );
  }
}

class _PlaylistColumn extends StatelessWidget {
  const _PlaylistColumn({
    required this.title,
    required this.emptyText,
    required this.child,
  });

  final String title;
  final String emptyText;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        if (child == null)
          Text(
            emptyText,
            style: const TextStyle(color: TanukiColors.muted, fontSize: 13),
          )
        else
          Expanded(child: child!),
      ],
    );
  }
}

class _SearchPanel extends StatefulWidget {
  const _SearchPanel({
    required this.controller,
    required this.searchController,
    required this.onRemoteCandidateSelected,
    required this.onPlaySearchTrailers,
  });

  final AppController controller;
  final TextEditingController searchController;
  final ValueChanged<RemoteSearchCandidate> onRemoteCandidateSelected;
  final VoidCallback onPlaySearchTrailers;

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  final FocusNode _searchFieldFocusNode = FocusNode(debugLabel: 'searchField');

  @override
  void dispose() {
    _searchFieldFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleSearchFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    _searchFieldFocusNode.unfocus();
    final scope = FocusScope.of(context);
    if (key == LogicalKeyboardKey.arrowDown) {
      scope.nextFocus();
    } else {
      scope.previousFocus();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final searchController = widget.searchController;
    final query = searchController.text.trim();
    final searchStatus = _searchStatusLabel(controller, query);
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 640) {
          unawaited(controller.loadMoreSearchResults(searchController.text));
        }
        return false;
      },
      child: SingleChildScrollView(
        clipBehavior: Clip.none,
        padding: const EdgeInsets.only(left: 20, bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text('Buscar anime',
                        style: Theme.of(context).textTheme.headlineMedium)),
                IconButton(
                  onPressed: controller.isSearching
                      ? null
                      : () => controller.searchRemote(searchController.text),
                  icon: controller.isSearching
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  tooltip: 'Buscar',
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: controller.remoteResults.any(
                            (candidate) => candidate.trailerUrl.isNotEmpty,
                          ) &&
                          !controller.isSearching
                      ? widget.onPlaySearchTrailers
                      : null,
                  icon: const Icon(Icons.movie_filter),
                  tooltip: 'Reproducir trailers',
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Busca por titulo, por un ano exacto o por rangos como 1990-2000.',
              style: TextStyle(color: Color(0xFF9FB4C7), fontSize: 14),
            ),
            const SizedBox(height: 18),
            Focus(
              onKeyEvent: _handleSearchFieldKey,
              child: TextField(
                focusNode: _searchFieldFocusNode,
                controller: searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: controller.searchRemote,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Busca por nombre, 1998 o 1990-2000',
                ),
              ),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _SearchFilterButton(
                    label: controller.searchFormatFilter.label,
                    active:
                        controller.searchFormatFilter != SearchFormatFilter.all,
                    onPressed: () => controller
                        .cycleSearchFormatFilter(searchController.text),
                  ),
                  const SizedBox(width: 10),
                  _SearchFilterButton(
                    label: controller.searchSeasonFilter.label,
                    active: !controller.searchSeasonFilter.isAll,
                    onPressed: () => controller
                        .cycleSearchSeasonFilter(searchController.text),
                  ),
                  const SizedBox(width: 10),
                  _SearchFilterButton(
                    label: controller.searchYearFilter.label,
                    active: controller.searchYearFilter != SearchYearFilter.all,
                    onPressed: () =>
                        controller.cycleSearchYearFilter(searchController.text),
                  ),
                  const SizedBox(width: 10),
                  _SearchFilterButton(
                    label: 'Limpiar filtros',
                    active: controller.hasActiveSearchFilters,
                    onPressed: () {
                      controller.clearSearchFilters(searchController.text);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              searchStatus,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFF0B760),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 14),
            if (controller.isSearching && controller.remoteResults.isEmpty)
              const _SearchGridSkeleton()
            else if (controller.remoteResults.isEmpty &&
                !controller.isSearching)
              _EmptyState(
                icon: Icons.search_off,
                title: 'Sin resultados',
                message: 'Prueba otro titulo.',
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final portrait = MediaQuery.of(context).orientation ==
                          Orientation.portrait ||
                      constraints.maxWidth < 720;
                  final columns = portrait
                      ? 3
                      : (constraints.maxWidth / 184)
                          .floor()
                          .clamp(4, 7)
                          .toInt();
                  final spacing = 6.0;
                  final cardWidth =
                      (constraints.maxWidth - spacing * (columns - 1)) /
                          columns;
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final candidate in controller.remoteResults)
                        SizedBox(
                          width: cardWidth,
                          height: 208,
                          child: _SearchResultPosterCard(
                            candidate: candidate,
                            imported: controller
                                    .findRemoteSeriesForCandidate(candidate) !=
                                null,
                            onTap: () =>
                                widget.onRemoteCandidateSelected(candidate),
                          ),
                        ),
                    ],
                  );
                },
              ),
            if (controller.remoteResults.isNotEmpty &&
                (controller.hasMoreSearchResults ||
                    controller.isLoadingMoreSearchResults)) ...[
              const SizedBox(height: 18),
              Center(
                child: controller.isLoadingMoreSearchResults
                    ? const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : OutlinedButton.icon(
                        onPressed: () => controller
                            .loadMoreSearchResults(searchController.text),
                        icon: const Icon(Icons.expand_more),
                        label: const Text('Cargar mas'),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchFilterButton extends StatelessWidget {
  const _SearchFilterButton({
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? const Color(0x33F47521) : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          side: BorderSide(
            color: active ? TanukiColors.orange : TanukiColors.panelStroke,
          ),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        child: Text(label),
      ),
    );
  }
}

class _SearchResultPosterCard extends StatelessWidget {
  const _SearchResultPosterCard({
    required this.candidate,
    required this.imported,
    required this.onTap,
    this.onFocused,
    this.onLongPress,
  });

  final RemoteSearchCandidate candidate;
  final bool imported;
  final VoidCallback onTap;
  final VoidCallback? onFocused;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheduleLabel = _scheduleChipLabel(candidate.airDateIso);
    return _FocusablePosterSurface(
      onTap: onTap,
      onFocused: onFocused,
      onLongPress: onLongPress,
      elevation: 8,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Poster(imageUrl: candidate.imageUrl, title: candidate.title),
          Positioned(
            left: 5,
            top: 5,
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xD6101822),
                shape: BoxShape.circle,
                border: Border.all(color: TanukiColors.orangeHot, width: 2),
              ),
              child: Text(
                candidate.episodeCount > 0 ? '${candidate.episodeCount}' : '?',
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: const TextStyle(
                  color: TanukiColors.text,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          Positioned(
            right: 6,
            top: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (imported) ...[
                  const Icon(
                    Icons.check_circle,
                    color: TanukiColors.orangeHot,
                    size: 20,
                  ),
                  const SizedBox(height: 4),
                ],
                if (scheduleLabel.isNotEmpty)
                  _ScheduleChip(text: scheduleLabel),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(7, 6, 7, 7),
              color: const Color(0xB010161D),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    candidate.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TanukiColors.text,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatCandidateMeta(candidate),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFB1C0CF),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FavoritesPanel extends StatelessWidget {
  const _FavoritesPanel({
    required this.controller,
    required this.onSeriesSelected,
  });

  final AppController controller;
  final ValueChanged<SeriesItem> onSeriesSelected;

  @override
  Widget build(BuildContext context) {
    final profile = controller.state.profile;
    List<SeriesItem> seriesFor(Set<String> keys) {
      final byIdentity = <String, SeriesItem>{};
      for (final series in controller.library
          .where((series) => keys.contains(series.stableKey))) {
        final identities = _spaceSeriesIdentityKeys(series);
        if (identities.isEmpty) {
          continue;
        }
        final identity = identities.firstWhere(
          byIdentity.containsKey,
          orElse: () => identities.first,
        );
        final current = byIdentity[identity];
        if (current == null ||
            _spaceSeriesCompletenessScore(series) >
                _spaceSeriesCompletenessScore(current)) {
          if (current != null) {
            for (final key in byIdentity.entries
                .where((entry) => identical(entry.value, current))
                .map((entry) => entry.key)
                .toList(growable: false)) {
              byIdentity[key] = series;
            }
          }
          for (final key in identities) {
            byIdentity[key] = series;
          }
        }
      }
      return byIdentity.values.toSet().toList()
        ..sort((a, b) => _seriesTitleDedupeKey(a.name)
            .compareTo(_seriesTitleDedupeKey(b.name)));
    }

    final favorites = seriesFor(profile.favoriteSeries);
    final watchlist = seriesFor(profile.watchlistSeries);
    final watching = seriesFor(profile.watchingSeries);
    final abandoned = seriesFor(profile.abandonedSeries);
    final completed = seriesFor(profile.completedSeries);
    final totalSaved = favorites.length +
        watchlist.length +
        watching.length +
        abandoned.length +
        completed.length;

    return SingleChildScrollView(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.only(left: 20, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(title: 'Mi espacio'),
          const SizedBox(height: 6),
          const Text(
            'Guarda animes para seguirles la pista desde un solo lugar.',
            style: TextStyle(color: TanukiColors.muted, fontSize: 14),
          ),
          const SizedBox(height: 12),
          Text(
            _formatMySpaceSummary(totalSaved),
            style: const TextStyle(color: TanukiColors.orangeHot, fontSize: 13),
          ),
          const SizedBox(height: 18),
          _SpaceSection(
            title: 'Favoritos',
            series: favorites,
            emptyText: 'Aun no marcas favoritos desde el detalle.',
            onSeriesSelected: onSeriesSelected,
          ),
          const SizedBox(height: 18),
          _SpaceSection(
            title: 'Quiero ver',
            series: watchlist,
            emptyText:
                'Aqui apareceran las series que quieras retomar despues.',
            onSeriesSelected: onSeriesSelected,
          ),
          const SizedBox(height: 18),
          _SpaceSection(
            title: 'Viendo',
            series: watching,
            emptyText: 'Cuando empieces una serie, quedara listada aqui.',
            onSeriesSelected: onSeriesSelected,
          ),
          const SizedBox(height: 18),
          _SpaceSection(
            title: 'Abandonadas',
            series: abandoned,
            emptyText: 'Si dejas una serie a medias, puedes mandarla aqui.',
            onSeriesSelected: onSeriesSelected,
          ),
          const SizedBox(height: 18),
          _SpaceSection(
            title: 'Completadas',
            series: completed,
            emptyText: 'Las series terminadas quedaran listadas aqui.',
            onSeriesSelected: onSeriesSelected,
          ),
        ],
      ),
    );
  }
}

class _SpaceSection extends StatelessWidget {
  const _SpaceSection({
    required this.title,
    required this.series,
    required this.emptyText,
    required this.onSeriesSelected,
  });

  final String title;
  final List<SeriesItem> series;
  final String emptyText;
  final ValueChanged<SeriesItem> onSeriesSelected;

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final posterHeight = (screenHeight * 0.235).clamp(220.0, 280.0);
    final posterWidth = posterHeight * 0.7;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          _formatSpaceSectionStatus(series.length, emptyText),
          style: const TextStyle(color: TanukiColors.muted, fontSize: 12),
        ),
        if (series.isNotEmpty) ...[
          const SizedBox(height: 4),
          SizedBox(
            height: posterHeight + 16,
            child: _HorizontalFocusShelf(
              child: ListView.separated(
                clipBehavior: Clip.none,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 2, 18, 6),
                itemBuilder: (context, index) {
                  final item = series[index];
                  return _SpacePosterCard(
                    width: posterWidth,
                    height: posterHeight,
                    series: item,
                    onTap: () => onSeriesSelected(item),
                  );
                },
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemCount: series.length,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SpacePosterCard extends StatelessWidget {
  const _SpacePosterCard({
    required this.width,
    required this.height,
    required this.series,
    required this.onTap,
  });

  final double width;
  final double height;
  final SeriesItem series;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: _FocusablePosterSurface(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Poster(imageUrl: series.imageUrl, title: series.name),
            Positioned(
              left: 5,
              top: 5,
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xD6101822),
                  shape: BoxShape.circle,
                  border: Border.all(color: TanukiColors.orangeHot, width: 2),
                ),
                child: Text(
                  series.episodeCount > 0 ? '${series.episodeCount}' : '?',
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  style: const TextStyle(
                    color: TanukiColors.text,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(7, 6, 7, 7),
                color: const Color(0xB010161D),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      series.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: TanukiColors.text,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatSpaceSeriesMeta(series),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB1C0CF),
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final profile = controller.state.profile;
    final malAuth = profile.myAnimeListAuth;
    final simklAuth = profile.simklAuth;
    final media = MediaQuery.of(context);
    final logicalSize = media.size;
    final dpr = media.devicePixelRatio;
    final physicalSize =
        Size(logicalSize.width * dpr, logicalSize.height * dpr);
    final aspectRatio = logicalSize.width / logicalSize.height;
    const targetAspectRatio = 16 / 9;
    final aspectDiff = (aspectRatio - targetAspectRatio).abs();
    final isSixteenByNine = aspectDiff <= 0.05;
    final safePadding = media.padding;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 20, right: 4, bottom: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ajustes', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            const _SettingsStatusText(
              'Tanuki Flutter v$_appVersionLabel\nby Guzz.',
            ),
            const _SettingsSectionTitle('Tarjetas Luego y Mas tarde'),
            _SettingsCheckBox(
              value: controller.state.showSeriesUpcomingCards,
              label: 'Mostrar en reproduccion normal de una serie',
              onChanged: (value) =>
                  controller.setBooleanSetting(showSeriesUpcomingCards: value),
            ),
            _SettingsCheckBox(
              value: controller.state.showPlaylistUpcomingCards,
              label: 'Mostrar en playlist',
              onChanged: (value) => controller.setBooleanSetting(
                  showPlaylistUpcomingCards: value),
            ),
            const _SettingsSectionTitle('Saltos automaticos'),
            _SettingsCheckBox(
              value: controller.state.skipMixedEpisodes,
              label: 'Saltar capitulos mixtos',
              onChanged: (value) =>
                  controller.setBooleanSetting(skipMixedEpisodes: value),
            ),
            _SettingsCheckBox(
              value: controller.state.skipFillerEpisodes,
              label: 'Saltar capitulos de relleno',
              onChanged: (value) =>
                  controller.setBooleanSetting(skipFillerEpisodes: value),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: controller.isRefreshingFillerMetadata
                  ? null
                  : () => controller.refreshFillerMetadata(force: true),
              icon: controller.isRefreshingFillerMetadata
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync),
              label: const Text('Actualizar relleno'),
            ),
            const _SettingsSectionTitle('Debug de pantalla'),
            _SettingsStatusText(
                'Resolución lógica: ${logicalSize.width.toStringAsFixed(0)} x ${logicalSize.height.toStringAsFixed(0)}'),
            _SettingsStatusText(
                'Resolución física: ${physicalSize.width.toStringAsFixed(0)} x ${physicalSize.height.toStringAsFixed(0)}'),
            _SettingsStatusText(
                'DPI de dispositivo: ${dpr.toStringAsFixed(2)}'),
            _SettingsStatusText(
                'Aspect ratio: ${aspectRatio.toStringAsFixed(3)}'),
            _SettingsStatusText(
                'Cerca de 16:9: ${isSixteenByNine ? 'Sí' : 'No'}'),
            _SettingsStatusText(
                'Safe area: top ${safePadding.top.toStringAsFixed(0)}, bottom ${safePadding.bottom.toStringAsFixed(0)}, left ${safePadding.left.toStringAsFixed(0)}, right ${safePadding.right.toStringAsFixed(0)}'),
            const SizedBox(height: 16),
            const _SettingsSectionTitle('MyAnimeList'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SettingsChoiceButton(
                  label: 'Client ID',
                  selected: controller.state.myAnimeListClientId.isNotEmpty,
                  onPressed: () => _showSettingsTextDialog(
                    context,
                    title: 'Client ID de MyAnimeList',
                    initialValue: controller.state.myAnimeListClientId,
                    hintText: 'Client ID',
                    onSave: controller.setMyAnimeListClientId,
                  ),
                ),
                _SettingsChoiceButton(
                  label: 'Client Secret',
                  selected: controller.state.myAnimeListClientSecret.isNotEmpty,
                  onPressed: () => _showSettingsTextDialog(
                    context,
                    title: 'Client Secret de MyAnimeList',
                    initialValue: controller.state.myAnimeListClientSecret,
                    hintText: 'Client Secret',
                    obscureText: true,
                    onSave: controller.setMyAnimeListClientSecret,
                  ),
                ),
                _SettingsChoiceButton(
                  label: 'Conectar',
                  selected:
                      malAuth.isConnected || controller.isConnectingMyAnimeList,
                  onPressed:
                      malAuth.isConnected || controller.isConnectingMyAnimeList
                          ? null
                          : () async {
                              final url =
                                  await controller.beginMyAnimeListConnection();
                              if (url.isNotEmpty && context.mounted) {
                                await _openSettingsUrl(url);
                              }
                            },
                ),
                if (controller.myAnimeListPendingAuthorization != null)
                  _SettingsChoiceButton(
                    label: 'Pegar retorno',
                    selected: true,
                    onPressed: () => _showSettingsTextDialog(
                      context,
                      title: 'URL de retorno de MyAnimeList',
                      initialValue: '',
                      hintText: 'toonamitvshell://mal-auth/callback?...',
                      onSave: controller.completeMyAnimeListConnection,
                    ),
                  ),
                if (controller.myAnimeListPendingAuthorization != null)
                  _SettingsChoiceButton(
                    label: 'Cancelar OAuth',
                    onPressed: controller.cancelMyAnimeListConnection,
                  ),
                _SettingsChoiceButton(
                  label: 'Sincronizar ahora',
                  onPressed:
                      malAuth.isConnected && !controller.isSyncingMyAnimeList
                          ? controller.recordMyAnimeListSyncAttempt
                          : null,
                ),
                _SettingsChoiceButton(
                  label: 'Desconectar',
                  onPressed:
                      malAuth.isConnected && !controller.isSyncingMyAnimeList
                          ? controller.disconnectMyAnimeList
                          : null,
                ),
              ],
            ),
            const SizedBox(height: 10),
            _SettingsStatusText(_myAnimeListSettingsStatus(controller)),
            const _SettingsSectionTitle('SIMKL'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SettingsChoiceButton(
                  label: 'Client ID',
                  selected: controller.state.simklClientId.isNotEmpty,
                  onPressed: () => _showSettingsTextDialog(
                    context,
                    title: 'Client ID de SIMKL',
                    initialValue: controller.state.simklClientId,
                    hintText: 'Client ID',
                    onSave: controller.setSimklClientId,
                  ),
                ),
                _SettingsChoiceButton(
                  label: 'Conectar',
                  selected:
                      simklAuth.isConnected || controller.isConnectingSimkl,
                  onPressed: simklAuth.isConnected ||
                          controller.isConnectingSimkl ||
                          controller.isSyncingSimkl
                      ? null
                      : controller.beginSimklConnection,
                ),
                _SettingsChoiceButton(
                  label: 'Abrir sitio',
                  onPressed: controller.simklPendingAuthorization == null
                      ? null
                      : () => unawaited(_openSettingsUrl(
                            controller
                                .simklPendingAuthorization!.verificationUrl,
                          )),
                ),
                _SettingsChoiceButton(
                  label: 'Verificar ahora',
                  onPressed: controller.simklPendingAuthorization == null
                      ? null
                      : controller.pollSimklAuthorizationNow,
                ),
                _SettingsChoiceButton(
                  label: 'Sincronizar ahora',
                  selected: controller.isSyncingSimkl,
                  onPressed: simklAuth.isConnected && !controller.isSyncingSimkl
                      ? controller.recordSimklSyncAttempt
                      : null,
                ),
                _SettingsChoiceButton(
                  label: 'Desconectar',
                  onPressed: simklAuth.isConnected ||
                          controller.simklPendingAuthorization != null
                      ? controller.disconnectSimkl
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 10),
            _SettingsStatusText(_simklSettingsStatus(controller)),
            const SizedBox(height: 16),
            _SettingsStatusText(_settingsSummary(controller)),
          ],
        ),
      ),
    );
  }

  Future<void> _showSettingsTextDialog(
    BuildContext context, {
    required String title,
    required String initialValue,
    required String hintText,
    required Future<void> Function(String value) onSave,
    bool obscureText = false,
  }) async {
    final textController = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: textController,
            autofocus: true,
            obscureText: obscureText,
            decoration: InputDecoration(hintText: hintText),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(''),
              child: const Text('Borrar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(textController.text),
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );
    textController.dispose();
    if (result != null) {
      await onSave(result);
    }
  }

  Future<void> _openSettingsUrl(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      controller.setStatusMessage('URL invalida.');
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      controller.setStatusMessage('No pude abrir $value.');
    }
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Text(
        text,
        style: const TextStyle(
          color: TanukiColors.text,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _SettingsChoiceButton extends StatelessWidget {
  const _SettingsChoiceButton({
    required this.label,
    this.selected = false,
    this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? TanukiColors.orange : null,
          foregroundColor: selected ? Colors.black : TanukiColors.text,
          disabledForegroundColor: TanukiColors.subtle,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        child: Text(label),
      ),
    );
  }
}

class _SettingsCheckBox extends StatelessWidget {
  const _SettingsCheckBox({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      value: value,
      onChanged: (value) => onChanged(value ?? false),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: TanukiColors.orange,
      checkColor: Colors.black,
      title: Text(
        label,
        style: const TextStyle(color: Color(0xFFD8E1EB), fontSize: 14),
      ),
    );
  }
}

class _SettingsStatusText extends StatelessWidget {
  const _SettingsStatusText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: TanukiColors.muted,
        fontSize: 13,
        height: 1.35,
      ),
    );
  }
}

class _ContinueWatchingEntry {
  const _ContinueWatchingEntry({
    required this.series,
    required this.seriesName,
    required this.imageUrl,
    required this.episode,
    required this.episodeCount,
    required this.watchedCount,
    required this.progress,
    required this.isCurrent,
  });

  final SeriesItem? series;
  final String seriesName;
  final String imageUrl;
  final EpisodeItem episode;
  final int episodeCount;
  final int watchedCount;
  final double progress;
  final bool isCurrent;
}

List<_ContinueWatchingEntry> _continueWatchingEntries(
  AppController controller,
) {
  final current = controller.currentEntry;
  final currentSeriesKey = current == null ? '' : _seriesKeyForEpisode(current);
  final currentTitleKey =
      current == null ? '' : _seriesTitleDedupeKey(current.seriesName);
  final entries = <_ContinueWatchingEntry>[];
  final seenKeys = <String>{};
  final seenTitleKeys = <String>{};

  for (final series in controller.library) {
    final seriesKey = series.stableKey;
    final titleKey = _seriesTitleDedupeKey(series.name);
    final currentForSeries =
        current != null && currentSeriesKey == series.stableKey;
    final watched = controller.watchedCountFor(series);
    final partialEpisode = _partialPlaybackEpisode(controller, series);
    final shouldInclude =
        currentForSeries || partialEpisode != null || watched > 0;
    if (!shouldInclude) {
      continue;
    }
    if (seenKeys.contains(seriesKey) ||
        (titleKey.isNotEmpty && seenTitleKeys.contains(titleKey))) {
      continue;
    }

    final total =
        series.episodeCount > 0 ? series.episodeCount : series.episodes.length;
    if (!currentForSeries &&
        total > 0 &&
        watched >= total &&
        partialEpisode == null) {
      continue;
    }

    final episode = currentForSeries
        ? current
        : partialEpisode ?? controller.firstPlayableEpisode(series);
    if (episode == null) {
      continue;
    }

    final playback = controller.playbackForEpisode(episode);
    final playbackProgress = _playbackProgress(playback);
    final seriesProgress =
        total > 0 ? (watched / total).clamp(0, 1).toDouble() : 0.0;
    entries.add(
      _ContinueWatchingEntry(
        series: series,
        seriesName: series.name,
        imageUrl:
            series.imageUrl.isNotEmpty ? series.imageUrl : episode.imageUrl,
        episode: episode,
        episodeCount: total,
        watchedCount: watched,
        progress: playbackProgress > 0 ? playbackProgress : seriesProgress,
        isCurrent: currentForSeries,
      ),
    );
    seenKeys.add(seriesKey);
    if (titleKey.isNotEmpty) {
      seenTitleKeys.add(titleKey);
    }
  }

  if (current != null &&
      !seenKeys.contains(currentSeriesKey) &&
      (currentTitleKey.isEmpty || !seenTitleKeys.contains(currentTitleKey))) {
    final playback = controller.playbackForEpisode(current);
    entries.add(
      _ContinueWatchingEntry(
        series: controller.findSeriesForEpisode(current),
        seriesName: current.seriesName,
        imageUrl: current.imageUrl,
        episode: current,
        episodeCount: 0,
        watchedCount: 0,
        progress: _playbackProgress(playback),
        isCurrent: true,
      ),
    );
  }

  entries.sort((left, right) {
    final currentCompare =
        (right.isCurrent ? 1 : 0).compareTo(left.isCurrent ? 1 : 0);
    if (currentCompare != 0) {
      return currentCompare;
    }
    final progressCompare = right.progress.compareTo(left.progress);
    if (progressCompare != 0) {
      return progressCompare;
    }
    final watchedCompare = right.watchedCount.compareTo(left.watchedCount);
    if (watchedCompare != 0) {
      return watchedCompare;
    }
    return left.seriesName
        .toLowerCase()
        .compareTo(right.seriesName.toLowerCase());
  });
  return entries.take(10).toList(growable: false);
}

String _seriesTitleDedupeKey(String value) {
  final stripped = value.replaceAll(
    RegExp(
      r'\s*\((AnimeAV1|AnimeKai|JKAnime|LatAnime|AnimeFLV|Facebook|Catalogo)(\s+\d+)?\)\s*$',
      caseSensitive: false,
    ),
    '',
  );
  return normalizeSeriesKey(stripped);
}

List<String> _spaceSeriesIdentityKeys(SeriesItem series) {
  if (series.catalogId > 0) {
    return ['catalog:${series.catalogId}'];
  }
  final titleKeys = <String>{
    _seriesTitleDedupeKey(series.name),
    _seriesTitleDedupeKey(series.japaneseTitle),
    ...series.aliases.map(_seriesTitleDedupeKey),
  }..removeWhere((entry) => entry.isEmpty);
  if (titleKeys.isNotEmpty) {
    return titleKeys.toList(growable: false);
  }
  return [series.stableKey];
}

List<SeriesItem> _dedupeSeriesForDisplay(Iterable<SeriesItem> seriesItems) {
  final byIdentity = <String, SeriesItem>{};
  for (final series in seriesItems) {
    final identities = _spaceSeriesIdentityKeys(series);
    if (identities.isEmpty) {
      continue;
    }
    final identity = identities.firstWhere(
      byIdentity.containsKey,
      orElse: () => identities.first,
    );
    final current = byIdentity[identity];
    if (current == null ||
        _spaceSeriesCompletenessScore(series) >
            _spaceSeriesCompletenessScore(current)) {
      if (current != null) {
        for (final key in byIdentity.entries
            .where((entry) => identical(entry.value, current))
            .map((entry) => entry.key)
            .toList(growable: false)) {
          byIdentity[key] = series;
        }
      }
      for (final key in identities) {
        byIdentity[key] = series;
      }
    }
  }
  return byIdentity.values.toSet().toList()
    ..sort((a, b) =>
        _seriesTitleDedupeKey(a.name).compareTo(_seriesTitleDedupeKey(b.name)));
}

int _spaceSeriesCompletenessScore(SeriesItem series) {
  var score = series.episodeCount;
  if (series.imageUrl.isNotEmpty) {
    score += 10000;
  }
  if (series.backgroundUrl.isNotEmpty) {
    score += 8000;
  }
  if (series.logoUrl.isNotEmpty) {
    score += 6000;
  }
  if (series.description.isNotEmpty) {
    score += 3000;
  }
  if (series.cast.isNotEmpty) {
    score += 1000 + series.cast.length;
  }
  return score;
}

EpisodeItem? _partialPlaybackEpisode(
  AppController controller,
  SeriesItem series,
) {
  final episodes = [...series.episodes]..sort(
      (left, right) => left.episodeIndex.compareTo(right.episodeIndex),
    );
  for (final episode in episodes) {
    final playback = controller.playbackForEpisode(episode);
    if (playback != null && !playback.completed && playback.positionMs > 1000) {
      return episode;
    }
  }
  return null;
}

double _playbackProgress(EpisodePlaybackRecord? playback) {
  if (playback == null) {
    return 0;
  }
  if (playback.completed) {
    return 1;
  }
  if (playback.durationMs > 0) {
    return (playback.positionMs / playback.durationMs).clamp(0, 1).toDouble();
  }
  return playback.positionMs > 1000 ? 0.08 : 0;
}

String _seriesKeyForEpisode(EpisodeItem episode) {
  final explicit = episode.seriesStateKey.trim();
  return explicit.isNotEmpty
      ? explicit
      : normalizeSeriesKey(episode.seriesName);
}

String _formatContinueWatchingMeta(_ContinueWatchingEntry entry) {
  final parts = [
    'Ep ${entry.episode.episodeNumber}',
    if (entry.episodeCount > 0)
      '${(entry.episodeCount - entry.watchedCount).clamp(0, entry.episodeCount)} pendientes',
  ];
  return parts.join(' | ');
}

List<RemoteSearchCandidate> _upcomingCandidates(
  Iterable<RemoteSearchCandidate> candidates,
) {
  final upcoming = candidates
      .where((candidate) => _scheduleChipLabel(candidate.airDateIso).isNotEmpty)
      .toList();
  upcoming.sort((left, right) {
    final leftDate = _candidateAirDate(left);
    final rightDate = _candidateAirDate(right);
    if (leftDate == null && rightDate == null) {
      return left.title.toLowerCase().compareTo(right.title.toLowerCase());
    }
    if (leftDate == null) {
      return 1;
    }
    if (rightDate == null) {
      return -1;
    }
    final dateCompare = leftDate.compareTo(rightDate);
    if (dateCompare != 0) {
      return dateCompare;
    }
    return left.title.toLowerCase().compareTo(right.title.toLowerCase());
  });
  return upcoming.take(10).toList(growable: false);
}

List<RemoteSearchCandidate> _latestMovieCandidates(
  Iterable<RemoteSearchCandidate> candidates,
) {
  final byTitle = <String, RemoteSearchCandidate>{};
  for (final candidate in candidates) {
    if (!_candidateLooksMovieForHome(candidate)) {
      continue;
    }
    final key = _seriesTitleDedupeKey(candidate.title);
    if (key.isEmpty) {
      continue;
    }
    final current = byTitle[key];
    if (current == null ||
        candidate.releaseYear > current.releaseYear ||
        (candidate.releaseYear == current.releaseYear &&
            candidate.episodeCount > current.episodeCount)) {
      byTitle[key] = candidate;
    }
  }
  final movies = byTitle.values.toList(growable: false);
  movies.sort((left, right) {
    final yearCompare = right.releaseYear.compareTo(left.releaseYear);
    if (yearCompare != 0) {
      return yearCompare;
    }
    return left.title.toLowerCase().compareTo(right.title.toLowerCase());
  });
  return movies.take(10).toList(growable: false);
}

bool _candidateLooksMovieForHome(RemoteSearchCandidate candidate) {
  final text = normalizeSeriesKey([
    candidate.format,
    candidate.title,
    candidate.watchUrl,
  ].join(' '));
  return text.contains('movie') ||
      text.contains('pelicula') ||
      candidate.watchUrl.toLowerCase().contains('/pelicula/');
}

DateTime? _candidateAirDate(RemoteSearchCandidate candidate) {
  final normalized = candidate.airDateIso.trim();
  if (normalized.isEmpty) {
    return null;
  }
  final source =
      normalized.length >= 10 ? normalized.substring(0, 10) : normalized;
  final parsed = DateTime.tryParse(source);
  return parsed == null
      ? null
      : DateTime(parsed.year, parsed.month, parsed.day);
}

void _ensureFocusedShelfVisible(BuildContext context) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) {
      return;
    }
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: 0.78,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    );
  });
}

String _searchStatusLabel(AppController controller, String query) {
  final count = controller.remoteResults.length;
  final filterSummary = controller.activeSearchFilterSummary;
  final statusMessage = controller.statusMessage.trim();
  if (controller.isSearching) {
    return 'Buscando en el catalogo...';
  }
  if (query.isEmpty && count > 0 && filterSummary.isNotEmpty) {
    return '$count destacados con $filterSummary.';
  }
  if (query.isEmpty && count > 0) {
    return 'Explora lo destacado del momento o escribe un titulo.';
  }
  if (query.isEmpty) {
    return statusMessage.isNotEmpty
        ? statusMessage
        : 'Escribe un titulo para buscar.';
  }
  if (count == 0 && filterSummary.isNotEmpty) {
    return 'No encontre resultados para "$query" con $filterSummary.';
  }
  if (count == 0) {
    return 'No encontre resultados para "$query".';
  }
  if (filterSummary.isNotEmpty) {
    return '$count resultados para "$query" con $filterSummary.';
  }
  return '$count resultados para "$query".';
}

String _scheduleChipLabel(String airDateIso) {
  final normalized = airDateIso.trim();
  if (normalized.isEmpty) {
    return '';
  }
  final source =
      normalized.length >= 10 ? normalized.substring(0, 10) : normalized;
  final parsed = DateTime.tryParse(source);
  if (parsed == null) {
    return '';
  }
  final date = DateTime(parsed.year, parsed.month, parsed.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final daysUntil = date.difference(today).inDays;
  if (daysUntil < 0) {
    return '';
  }
  if (daysUntil == 0) {
    return 'Hoy';
  }
  if (daysUntil == 1) {
    return 'Manana';
  }
  final currentWeekEnd = today.add(Duration(days: 7 - today.weekday));
  if (!date.isAfter(currentWeekEnd)) {
    return switch (date.weekday) {
      DateTime.monday => 'Lunes',
      DateTime.tuesday => 'Martes',
      DateTime.wednesday => 'Miercoles',
      DateTime.thursday => 'Jueves',
      DateTime.friday => 'Viernes',
      DateTime.saturday => 'Sabado',
      _ => 'Domingo',
    };
  }
  return '${date.day} ${_monthLabel(date.month)}';
}

bool _episodeAirsInFuture(String airDateIso) {
  final normalized = airDateIso.trim();
  if (normalized.isEmpty) {
    return false;
  }
  final source =
      normalized.length >= 10 ? normalized.substring(0, 10) : normalized;
  final parsed = DateTime.tryParse(source);
  if (parsed == null) {
    return false;
  }
  final airDate = DateTime(parsed.year, parsed.month, parsed.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return airDate.isAfter(today);
}

String _monthLabel(int month) {
  return switch (month) {
    1 => 'enero',
    2 => 'febrero',
    3 => 'marzo',
    4 => 'abril',
    5 => 'mayo',
    6 => 'junio',
    7 => 'julio',
    8 => 'agosto',
    9 => 'septiembre',
    10 => 'octubre',
    11 => 'noviembre',
    _ => 'diciembre',
  };
}

String _formatCandidateMeta(RemoteSearchCandidate candidate) {
  final parts = [
    if (candidate.format.isNotEmpty) candidate.format,
    if (candidate.releaseYear > 0) '${candidate.releaseYear}',
    if (candidate.episodeCount > 0) '${candidate.episodeCount} eps',
    if (candidate.rating.isNotEmpty) 'Score ${candidate.rating}',
  ];
  return parts.isEmpty ? 'Serie remota' : parts.join(' | ');
}

String _formatMySpaceSummary(int totalSaved) {
  return switch (totalSaved) {
    0 =>
      'Todavia no guardas series aqui. Usa la ficha de detalle para marcarlas.',
    1 => 'Tienes 1 serie guardada en Mi espacio.',
    _ =>
      'Tienes $totalSaved series distribuidas entre favoritos, pendientes, viendo, abandonadas y completadas.',
  };
}

String _formatSpaceSectionStatus(int count, String emptyText) {
  return switch (count) {
    0 => emptyText,
    1 => '1 serie guardada.',
    _ => '$count series guardadas.',
  };
}

String _formatSpaceSeriesMeta(SeriesItem series) {
  final parts = [
    if (series.format.isNotEmpty) series.format,
    if (series.releaseYear > 0) '${series.releaseYear}',
  ];
  final meta = parts.join(' | ');
  if (meta.isNotEmpty) {
    return meta;
  }
  return series.sourceType == SourceType.local ? 'Serie local' : 'Serie remota';
}

String _myAnimeListSettingsStatus(AppController controller) {
  final auth = controller.state.profile.myAnimeListAuth;
  final parts = <String>[
    controller.hasConfiguredMyAnimeListClientId
        ? 'MyAnimeList configurado para iniciar OAuth.'
        : 'Falta configurar el Client ID de MyAnimeList.',
    if (controller.myAnimeListPendingAuthorization != null)
      'Autorizacion pendiente. Redirect URI: ${MyAnimeListService.redirectUri}',
    if (controller.isSyncingMyAnimeList) 'Sincronizando con MyAnimeList...',
    auth.isConnected
        ? 'Conectado como ${auth.userName.ifBlank('usuario ${auth.userId}')}.'
        : 'Perfil sin conectar.',
    if (auth.lastSyncAtMs > 0)
      'Ultima sincronizacion: ${_formatUnixMs(auth.lastSyncAtMs)}.',
    if (auth.lastSyncStatus.isNotEmpty) auth.lastSyncStatus,
    if (auth.lastSyncError.isNotEmpty) 'Error: ${auth.lastSyncError}',
  ];
  return parts.join('\n');
}

String _simklSettingsStatus(AppController controller) {
  final auth = controller.state.profile.simklAuth;
  final pending = controller.simklPendingAuthorization;
  final parts = <String>[
    controller.hasConfiguredSimklClientId
        ? 'SIMKL configurado para PIN.'
        : 'Falta configurar el Client ID de SIMKL.',
    if (pending != null) ...[
      'Codigo: ${pending.userCode}.',
      'Abre ${pending.verificationUrl}.',
      'Expira a las ${_formatUnixMs(pending.expiresAtMs)}.',
    ] else if (auth.isConnected)
      'Conectado como ${auth.userName.ifBlank('usuario ${auth.userId}')}.'
    else
      'Perfil sin conectar.',
    if (controller.isSyncingSimkl) 'Sincronizando con SIMKL...',
    if (auth.lastSyncAtMs > 0)
      'Ultima sincronizacion: ${_formatUnixMs(auth.lastSyncAtMs)}.',
    if (auth.lastSyncStatus.isNotEmpty) auth.lastSyncStatus,
    if (auth.lastSyncError.isNotEmpty) 'Error: ${auth.lastSyncError}',
  ];
  return parts.join('\n');
}

String _formatUnixMs(int value) {
  final date = DateTime.fromMillisecondsSinceEpoch(value);
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}

String _settingsSummary(AppController controller) {
  final profile = controller.state.profile;
  final profileName = profile.name.trim().isEmpty ? 'Perfil' : profile.name;
  final parts = [
    'Perfil activo: $profileName',
    'Series remotas importadas: ${controller.remoteLibrary.length}',
    'Favoritos guardados: ${profile.favoriteSeries.length}',
    'Series viendo: ${profile.watchingSeries.length}',
    'Tarjetas en series: ${controller.state.showSeriesUpcomingCards ? 'activadas' : 'desactivadas'}',
    'Tarjetas en playlist: ${controller.state.showPlaylistUpcomingCards ? 'activadas' : 'desactivadas'}',
    'Saltar capitulos mixtos: ${controller.state.skipMixedEpisodes ? 'activado' : 'desactivado'}',
    'Saltar capitulos de relleno: ${controller.state.skipFillerEpisodes ? 'activado' : 'desactivado'}',
    'MyAnimeList: ${profile.myAnimeListAuth.isConnected ? 'conectado' : 'sin conectar'}',
    'SIMKL: ${profile.simklAuth.isConnected ? 'conectado' : 'sin conectar'}',
    if (controller.storePath.isNotEmpty) 'Estado: ${controller.storePath}',
  ];
  return parts.join('\n');
}

extension _StringBlankFallback on String {
  String ifBlank(String fallback) => trim().isEmpty ? fallback : this;
}

class _MiniSeriesTile extends StatelessWidget {
  const _MiniSeriesTile({
    required this.controller,
    required this.series,
    required this.onTap,
  });

  final AppController controller;
  final SeriesItem series;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final watched = controller.watchedCountFor(series);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _FocusableEpisodeSurface(
        onTap: onTap,
        color: const Color(0xFF10151C),
        elevation: 8,
        activeElevation: 10,
        borderRadius: 10,
        child: SizedBox(
          height: 76,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SizedBox(
                  width: 50,
                  height: 56,
                  child: _Poster(imageUrl: series.imageUrl, title: series.name),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        series.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: TanukiColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$watched / ${series.episodeCount}',
                        style: const TextStyle(
                          color: TanukiColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => controller.toggleSeriesSelection(series),
                  icon: const Icon(Icons.close),
                  style: IconButton.styleFrom(
                    fixedSize: const Size(40, 40),
                    backgroundColor: const Color(0xFF1A2332),
                    foregroundColor: TanukiColors.text,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  tooltip: 'Quitar',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.episode,
    required this.onPlay,
  });

  final EpisodeItem episode;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _FocusableEpisodeSurface(
        onTap: onPlay,
        color: const Color(0xFF10151C),
        elevation: 8,
        activeElevation: 10,
        borderRadius: 10,
        child: SizedBox(
          height: 84,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SizedBox(
                  width: 60,
                  height: 64,
                  child: _Poster(
                    imageUrl: episode.imageUrl,
                    title: episode.displayName,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        episode.seriesName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: TanukiColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        episode.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: TanukiColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _QueueStatusChip(episode: episode),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueStatusChip extends StatelessWidget {
  const _QueueStatusChip({required this.episode});

  final EpisodeItem episode;

  @override
  Widget build(BuildContext context) {
    if (_EpisodeTagChip.hasTag(episode.episodeTag)) {
      return _EpisodeTagChip(tag: episode.episodeTag);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF325A3A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'Normal',
        style: TextStyle(
          color: TanukiColors.text,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _EpisodeTagChip extends StatelessWidget {
  const _EpisodeTagChip({required this.tag});

  final String tag;

  static bool hasTag(String tag) => _normalize(tag).isNotEmpty;

  static String _normalize(String tag) {
    return switch (tag.trim().toLowerCase()) {
      'mixed' || 'mixto' => 'mixed',
      'filler' || 'relleno' => 'filler',
      'canon' => 'canon',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _normalize(tag);
    if (normalized.isEmpty) {
      return const SizedBox.shrink();
    }
    final color = switch (normalized) {
      'filler' => TanukiColors.danger,
      'mixed' => TanukiColors.amber,
      _ => TanukiColors.cyan,
    };
    final label = switch (normalized) {
      'filler' => 'Relleno',
      'mixed' => 'Mixto',
      _ => 'Canon',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _FocusablePosterSurface extends StatefulWidget {
  const _FocusablePosterSurface({
    required this.child,
    required this.onTap,
    this.onFocused,
    this.onLongPress,
    this.elevation = 6,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onFocused;
  final VoidCallback? onLongPress;
  final double elevation;

  @override
  State<_FocusablePosterSurface> createState() =>
      _FocusablePosterSurfaceState();
}

class _FocusablePosterSurfaceState extends State<_FocusablePosterSurface> {
  bool _focused = false;
  bool _hovered = false;
  final FocusNode _focusNode = FocusNode();
  Timer? _remoteLongPressTimer;
  bool _remoteLongPressTriggered = false;
  bool _remoteKeyDown = false;

  bool get _active => _focused || _hovered;

  @override
  void dispose() {
    _remoteLongPressTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleRemoteKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent &&
        event is! KeyRepeatEvent &&
        event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    if (!_isRemoteActivateKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }

    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent) {
      if (_remoteKeyDown) {
        return KeyEventResult.handled;
      }
      _remoteKeyDown = true;
      _remoteLongPressTriggered = false;
      _remoteLongPressTimer?.cancel();
      if (widget.onLongPress != null) {
        _remoteLongPressTimer = Timer(
          const Duration(milliseconds: 450),
          _triggerRemoteLongPress,
        );
      }
    } else if (event is KeyUpEvent) {
      _remoteKeyDown = false;
      _remoteLongPressTimer?.cancel();
      _remoteLongPressTimer = null;
      if (_remoteLongPressTriggered) {
        _remoteLongPressTriggered = false;
        return KeyEventResult.handled;
      }
      widget.onTap();
    }

    return KeyEventResult.handled;
  }

  void _triggerRemoteLongPress() {
    if (!mounted || !_remoteKeyDown) {
      return;
    }
    _remoteLongPressTriggered = true;
    widget.onLongPress?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleRemoteKeyEvent,
      onFocusChange: (value) {
        if (_focused != value) {
          setState(() => _focused = value);
        }
        if (value) {
          widget.onFocused?.call();
          _ensureFocusableVisible(context, alignment: 0.54);
        }
      },
      child: AnimatedScale(
        scale: _active ? 1.015 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          elevation: _active ? 12 : widget.elevation,
          shadowColor: const Color(0x77000000),
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: () {
              if (_remoteLongPressTriggered) {
                _remoteLongPressTriggered = false;
                return;
              }
              widget.onTap();
            },
            onLongPress: widget.onLongPress,
            onHover: (value) {
              if (_hovered != value) {
                setState(() => _hovered = value);
              }
            },
            child: Container(
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _active ? TanukiColors.orange : Colors.transparent,
                  width: 3,
                ),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _FocusableEpisodeSurface extends StatefulWidget {
  const _FocusableEpisodeSurface({
    required this.child,
    required this.onTap,
    this.enabled = true,
    this.onLongPress,
    this.color = const Color(0xFF11161D),
    this.elevation = 6,
    this.activeElevation = 9,
    this.borderRadius = 7,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final VoidCallback? onLongPress;
  final Color color;
  final double elevation;
  final double activeElevation;
  final double borderRadius;

  @override
  State<_FocusableEpisodeSurface> createState() =>
      _FocusableEpisodeSurfaceState();
}

class _FocusableEpisodeSurfaceState extends State<_FocusableEpisodeSurface> {
  bool _focused = false;
  bool _hovered = false;
  final FocusNode _focusNode = FocusNode();
  Timer? _remoteLongPressTimer;
  bool _remoteLongPressTriggered = false;
  bool _remoteKeyDown = false;

  bool get _active => _focused || _hovered;

  @override
  void dispose() {
    _remoteLongPressTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleRemoteKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent &&
        event is! KeyRepeatEvent &&
        event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    if (!_isRemoteActivateKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (!widget.enabled) {
      return KeyEventResult.handled;
    }

    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent) {
      if (_remoteKeyDown) {
        return KeyEventResult.handled;
      }
      _remoteKeyDown = true;
      _remoteLongPressTriggered = false;
      _remoteLongPressTimer?.cancel();
      if (widget.onLongPress != null) {
        _remoteLongPressTimer = Timer(
          const Duration(milliseconds: 450),
          _triggerRemoteLongPress,
        );
      }
    } else if (event is KeyUpEvent) {
      _remoteKeyDown = false;
      _remoteLongPressTimer?.cancel();
      _remoteLongPressTimer = null;
      if (_remoteLongPressTriggered) {
        _remoteLongPressTriggered = false;
        return KeyEventResult.handled;
      }
      widget.onTap?.call();
    }

    return KeyEventResult.handled;
  }

  void _triggerRemoteLongPress() {
    if (!mounted || !_remoteKeyDown) {
      return;
    }
    _remoteLongPressTriggered = true;
    widget.onLongPress?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      canRequestFocus: widget.enabled,
      onKeyEvent: _handleRemoteKeyEvent,
      onFocusChange: (value) {
        if (_focused != value) {
          setState(() => _focused = value);
        }
        if (value) {
          _ensureFocusableVisible(context, alignment: 0.48);
        }
      },
      child: AnimatedScale(
        scale: _active ? 1.004 : 1,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: Material(
          color: widget.color,
          elevation: _active ? widget.activeElevation : widget.elevation,
          borderRadius: BorderRadius.circular(widget.borderRadius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: () {
              if (!widget.enabled) {
                return;
              }
              if (_remoteLongPressTriggered) {
                _remoteLongPressTriggered = false;
                return;
              }
              widget.onTap?.call();
            },
            onLongPress: widget.enabled ? widget.onLongPress : null,
            onHover: (value) {
              if (_hovered != value) {
                setState(() => _hovered = value);
              }
            },
            child: Container(
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                border: Border.all(
                  color: _active ? TanukiColors.orange : Colors.transparent,
                  width: 3,
                ),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

bool _isRemoteActivateKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.gameButtonA;
}

void _ensureFocusableVisible(
  BuildContext context, {
  required double alignment,
}) {
  final scrollable = Scrollable.maybeOf(context);
  final renderObject = context.findRenderObject();
  if (scrollable == null || renderObject == null) {
    return;
  }
  scrollable.position.ensureVisible(
    renderObject,
    duration: const Duration(milliseconds: 160),
    curve: Curves.easeOutCubic,
    alignment: alignment,
    alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
  );
}

class _Poster extends StatelessWidget {
  const _Poster({
    required this.imageUrl,
    required this.title,
  });

  final String imageUrl;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: const BoxDecoration(color: TanukiColors.backgroundAlt),
        child: imageUrl.isEmpty
            ? _PosterFallback(title: title)
            : _FadeInNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _PosterFallback(title: title),
              ),
      ),
    );
  }
}

class _FadeInNetworkImage extends StatelessWidget {
  const _FadeInNetworkImage({
    required this.imageUrl,
    this.fit,
    this.alignment = Alignment.center,
    this.errorBuilder,
  });

  final String imageUrl;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      imageUrl,
      fit: fit,
      alignment: alignment,
      errorBuilder: errorBuilder,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) {
          return child;
        }
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: child,
        );
      },
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final fontSize = _homeResponsiveValue(context, 10, min: 9, max: 12);
    final padding = _homeResponsiveValue(context, 12, min: 10, max: 14);
    final labelPadding = _homeResponsiveValue(context, 6, min: 5, max: 8);
    return Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: EdgeInsets.all(padding),
          child: Image.asset('assets/images/tanuki_brand_icon.png',
              fit: BoxFit.contain),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.all(labelPadding),
            color: const Color(0x99000000),
            child: Text(
              title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _ScheduleChip extends StatelessWidget {
  const _ScheduleChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = _homeResponsiveValue(context, 8, min: 6, max: 10);
    final verticalPadding = _homeResponsiveValue(context, 4, min: 3, max: 6);
    final fontSize = _homeResponsiveValue(context, 11, min: 10, max: 14);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: const Color(0xCC1E7A63),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x66E0FFF3)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: const Color(0xFFF9FCFF),
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _HeroRatingPill extends StatelessWidget {
  const _HeroRatingPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: glassDecoration(radius: 8),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: TanukiColors.text,
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF5D3420),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.trailing = '',
  });

  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final titleFontSize = _homeResponsiveValue(context, 22, min: 18, max: 28);
    final trailingFontSize =
        _homeResponsiveValue(context, 13, min: 11, max: 16);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: TanukiColors.text,
              fontSize: titleFontSize,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (trailing.isNotEmpty)
          Flexible(
            child: Text(
              trailing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: TanukiColors.text,
                fontSize: trailingFontSize,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: glassDecoration(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: TanukiColors.subtle),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _SavingPill extends StatelessWidget {
  const _SavingPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: glassDecoration(color: const Color(0xEE141D28)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Guardando',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
