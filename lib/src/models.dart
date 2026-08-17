enum SourceType {
  local,
  remote,
}

enum RemoteProvider {
  animeAv1,
  animeKai,
  jkAnime,
  latAnime,
  justAnime,
  aniPm,
  animeFlv,
  facebook,
  internetArchive,
  bilibili,
  youtube,
  catalog,
}

extension SourceTypeDetails on SourceType {
  String get id {
    return switch (this) {
      SourceType.local => 'local',
      SourceType.remote => 'remote',
    };
  }
}

extension RemoteProviderDetails on RemoteProvider {
  String get id {
    return switch (this) {
      RemoteProvider.animeAv1 => 'animeav1',
      RemoteProvider.animeKai => 'animekai',
      RemoteProvider.jkAnime => 'jkanime',
      RemoteProvider.latAnime => 'latanime',
      RemoteProvider.justAnime => 'justanime',
      RemoteProvider.aniPm => 'anipm',
      RemoteProvider.animeFlv => 'animeflv',
      RemoteProvider.facebook => 'facebook',
      RemoteProvider.internetArchive => 'internetarchive',
      RemoteProvider.bilibili => 'bilibili',
      RemoteProvider.youtube => 'youtube',
      RemoteProvider.catalog => 'catalog',
    };
  }

  String get label {
    return switch (this) {
      RemoteProvider.animeAv1 => 'AnimeAV1',
      RemoteProvider.animeKai => 'AnimeKai',
      RemoteProvider.jkAnime => 'JKAnime',
      RemoteProvider.latAnime => 'LatAnime',
      RemoteProvider.justAnime => 'JustAnime',
      RemoteProvider.aniPm => 'ani.pm',
      RemoteProvider.animeFlv => 'AnimeFLV',
      RemoteProvider.facebook => 'Facebook',
      RemoteProvider.internetArchive => 'Internet Archive',
      RemoteProvider.bilibili => 'BiliBili',
      RemoteProvider.youtube => 'YouTube',
      RemoteProvider.catalog => 'Catalogo',
    };
  }
}

SourceType sourceTypeFromId(Object? value) {
  return '$value'.trim().toLowerCase() == 'remote'
      ? SourceType.remote
      : SourceType.local;
}

RemoteProvider? remoteProviderFromId(Object? value) {
  final normalized = '$value'.trim().toLowerCase();
  for (final provider in RemoteProvider.values) {
    if (provider.id == normalized) {
      return provider;
    }
  }
  return null;
}

enum VideoScaleMode {
  fit('fit', 'FIT', 'Normal'),
  stretch('stretch', 'STR', 'Stretch');

  const VideoScaleMode(this.id, this.buttonLabel, this.dialogLabel);

  final String id;
  final String buttonLabel;
  final String dialogLabel;

  VideoScaleMode get next {
    final values = VideoScaleMode.values;
    return values[(index + 1) % values.length];
  }
}

VideoScaleMode videoScaleModeFromId(Object? value) {
  return switch ('$value'.trim().toLowerCase()) {
    'stretch' || 'fill' => VideoScaleMode.stretch,
    _ => VideoScaleMode.fit,
  };
}

enum AnimeSkipSegmentType {
  opening('op', 'Opening'),
  ending('ed', 'Ending'),
  mixedOpening('mixed-op', 'Opening mezclado'),
  mixedEnding('mixed-ed', 'Ending mezclado'),
  recap('recap', 'Resumen');

  const AnimeSkipSegmentType(this.id, this.label);

  final String id;
  final String label;
}

AnimeSkipSegmentType? animeSkipSegmentTypeFromId(Object? value) {
  final normalized = '$value'.trim().toLowerCase();
  for (final type in AnimeSkipSegmentType.values) {
    if (type.id == normalized) {
      return type;
    }
  }
  return null;
}

enum AnimeAv1PlaybackMode {
  subHls('sub-hls', 'SUB', 'Hard Sub'),
  dubHls('dub-hls', 'DUB', 'Dub');

  const AnimeAv1PlaybackMode(this.id, this.buttonLabel, this.dialogLabel);

  final String id;
  final String buttonLabel;
  final String dialogLabel;
}

AnimeAv1PlaybackMode animeAv1PlaybackModeFromId(Object? value) {
  return switch ('$value'.trim().toLowerCase()) {
    'dub-hls' || 'dub' => AnimeAv1PlaybackMode.dubHls,
    _ => AnimeAv1PlaybackMode.subHls,
  };
}

enum JkAnimeServerPreference {
  desu('desu', 'Desu'),
  magi('magi', 'Magi'),
  streamWish('streamwish', 'StreamWish'),
  mp4upload('mp4upload', 'MP4Upload'),
  vidhide('vidhide', 'VidHide'),
  mixDrop('mixdrop', 'MixDrop'),
  voe('voe', 'VOE'),
  filemoon('filemoon', 'FileMoon'),
  doodstream('doodstream', 'Doodstream'),
  streamTape('stape', 'StreamTape');

  const JkAnimeServerPreference(this.id, this.label);

  final String id;
  final String label;
}

JkAnimeServerPreference jkAnimeServerPreferenceFromId(Object? value) {
  final normalized = '$value'.trim().toLowerCase();
  return switch (normalized) {
    String text
        when text.contains('streamwish') ||
            text.contains('stream wish') ||
            text.contains('sfastwish') ||
            text.contains('flaswish') ||
            text == 'sw' =>
      JkAnimeServerPreference.streamWish,
    String text when text.contains('mixdrop') || text.contains('mix drop') =>
      JkAnimeServerPreference.mixDrop,
    String text
        when text.contains('mp4upload') || text.contains('mp4 upload') =>
      JkAnimeServerPreference.mp4upload,
    String text when text.contains('filemoon') =>
      JkAnimeServerPreference.filemoon,
    String text when text == 'voe' || text.contains('voe.sx') =>
      JkAnimeServerPreference.voe,
    String text when text.contains('streamtape') || text.contains('stape') =>
      JkAnimeServerPreference.streamTape,
    String text
        when text.contains('doodstream') ||
            text.contains('dood') ||
            text.contains('dsvplay') =>
      JkAnimeServerPreference.doodstream,
    String text when text.contains('desu') => JkAnimeServerPreference.desu,
    String text when text.contains('magi') => JkAnimeServerPreference.magi,
    String text when text.contains('vidhide') || text.contains('vid hide') =>
      JkAnimeServerPreference.vidhide,
    _ => JkAnimeServerPreference.desu,
  };
}

enum LatAnimeServerPreference {
  uqload('uqload', 'Uqload'),
  mp4upload('mp4upload', 'MP4Upload'),
  doodstream('doodstream', 'Doodstream'),
  yourUpload('yourupload', 'YourUpload');

  const LatAnimeServerPreference(this.id, this.label);

  final String id;
  final String label;
}

enum JustAnimePlaybackMode {
  sub('sub', 'SUB', 'Subtitulado'),
  dub('dub', 'DUB', 'Doblado');

  const JustAnimePlaybackMode(this.id, this.buttonLabel, this.dialogLabel);
  final String id;
  final String buttonLabel;
  final String dialogLabel;
}

enum AniPmPlaybackMode {
  sub('sub', 'SUB', 'Subtitulado'),
  dub('dub', 'DUB', 'Doblado');

  const AniPmPlaybackMode(this.id, this.buttonLabel, this.dialogLabel);
  final String id;
  final String buttonLabel;
  final String dialogLabel;
}

AniPmPlaybackMode aniPmPlaybackModeFromId(Object? value) =>
    '$value'.trim().toLowerCase() == 'dub'
        ? AniPmPlaybackMode.dub
        : AniPmPlaybackMode.sub;

JustAnimePlaybackMode justAnimePlaybackModeFromId(Object? value) =>
    '$value'.trim().toLowerCase() == 'dub'
        ? JustAnimePlaybackMode.dub
        : JustAnimePlaybackMode.sub;

enum JustAnimeServerPreference {
  momo('momo', 'Momo'),
  neko('neko', 'Neko'),
  gigi('gigi', 'Gigi');

  const JustAnimeServerPreference(this.id, this.label);
  final String id;
  final String label;
}

JustAnimeServerPreference justAnimeServerPreferenceFromId(Object? value) =>
    switch ('$value'.trim().toLowerCase()) {
      String text when text.contains('gigi') || text.contains('animegg') =>
        JustAnimeServerPreference.gigi,
      String text when text.contains('neko') || text.contains('anineko') =>
        JustAnimeServerPreference.neko,
      _ => JustAnimeServerPreference.momo,
    };

LatAnimeServerPreference latAnimeServerPreferenceFromId(Object? value) {
  final normalized = '$value'.trim().toLowerCase();
  return switch (normalized) {
    String text
        when text.contains('mp4upload') || text.contains('mp4 upload') =>
      LatAnimeServerPreference.mp4upload,
    String text when text.contains('dood') || text.contains('dsvplay') =>
      LatAnimeServerPreference.doodstream,
    String text
        when text.contains('yourupload') ||
            text.contains('your upload') ||
            text.contains('vidcache') =>
      LatAnimeServerPreference.yourUpload,
    _ => LatAnimeServerPreference.uqload,
  };
}

enum FacebookPlaybackMode {
  sub('sub', 'SUB', 'Subtitulado'),
  dub('dub', 'DUB', 'Latino');

  const FacebookPlaybackMode(this.id, this.buttonLabel, this.dialogLabel);

  final String id;
  final String buttonLabel;
  final String dialogLabel;
}

FacebookPlaybackMode facebookPlaybackModeFromId(Object? value) {
  return switch ('$value'.trim().toLowerCase()) {
    'dub' || 'lat' || 'latino' => FacebookPlaybackMode.dub,
    _ => FacebookPlaybackMode.sub,
  };
}

enum FacebookPlaybackOption {
  first('option-1', 'Opcion 1'),
  second('option-2', 'Opcion 2');

  const FacebookPlaybackOption(this.id, this.label);

  final String id;
  final String label;
}

FacebookPlaybackOption facebookPlaybackOptionFromId(Object? value) {
  return switch ('$value'.trim().toLowerCase()) {
    '2' ||
    'opcion-2' ||
    'opcion 2' ||
    'option-2' ||
    'option 2' =>
      FacebookPlaybackOption.second,
    _ => FacebookPlaybackOption.first,
  };
}

enum YoutubePlaybackMode {
  sub('sub', 'SUB', 'Sub esp'),
  dub('dub', 'DUB', 'Latino');

  const YoutubePlaybackMode(this.id, this.buttonLabel, this.dialogLabel);

  final String id;
  final String buttonLabel;
  final String dialogLabel;
}

YoutubePlaybackMode youtubePlaybackModeFromId(Object? value) {
  return switch ('$value'.trim().toLowerCase()) {
    'dub' || 'lat' || 'latino' => YoutubePlaybackMode.dub,
    _ => YoutubePlaybackMode.sub,
  };
}

enum YoutubePlaybackOption {
  first('option-1', 'Opcion 1'),
  second('option-2', 'Opcion 2');

  const YoutubePlaybackOption(this.id, this.label);

  final String id;
  final String label;
}

YoutubePlaybackOption youtubePlaybackOptionFromId(Object? value) {
  return switch ('$value'.trim().toLowerCase()) {
    '2' ||
    'opcion-2' ||
    'opcion 2' ||
    'option-2' ||
    'option 2' =>
      YoutubePlaybackOption.second,
    _ => YoutubePlaybackOption.first,
  };
}

enum AndroidVideoViewMode {
  automatic('auto', 'Auto'),
  texture('texture', 'TextureView'),
  surface('surface', 'SurfaceView');

  const AndroidVideoViewMode(this.id, this.label);

  final String id;
  final String label;
}

AndroidVideoViewMode androidVideoViewModeFromId(Object? value) {
  return switch ('$value'.trim().toLowerCase()) {
    'texture' || 'textureview' => AndroidVideoViewMode.texture,
    'surface' ||
    'surfaceview' ||
    'platform' ||
    'platformview' =>
      AndroidVideoViewMode.surface,
    _ => AndroidVideoViewMode.automatic,
  };
}

class EpisodeItem {
  const EpisodeItem({
    required this.seriesName,
    required this.episodeIndex,
    required this.episodeNumber,
    required this.displayName,
    required this.relativePath,
    required this.filePath,
    required this.sourceType,
    this.seriesStateKey = '',
    this.episodeTag = '',
    this.provider,
    this.slug = '',
    this.watchUrl = '',
    this.releaseYear = 0,
    this.imageUrl = '',
    this.description = '',
    this.airDateIso = '',
    this.durationLabel = '',
  });

  final String seriesName;
  final String seriesStateKey;
  final int episodeIndex;
  final int episodeNumber;
  final String displayName;
  final String relativePath;
  final String filePath;
  final SourceType sourceType;
  final String episodeTag;
  final RemoteProvider? provider;
  final String slug;
  final String watchUrl;
  final int releaseYear;
  final String imageUrl;
  final String description;
  final String airDateIso;
  final String durationLabel;

  bool get isRemote => sourceType == SourceType.remote;

  factory EpisodeItem.fromJson(Map<String, dynamic> json) {
    return EpisodeItem(
      seriesName: _readString(json['seriesName']),
      seriesStateKey: _readString(json['seriesStateKey']),
      episodeIndex: _readInt(json['episodeIndex']),
      episodeNumber: _readInt(json['episodeNumber'],
          fallback: _readInt(json['episodeIndex']) + 1),
      displayName: _readString(json['displayName']),
      relativePath: _readString(json['relativePath']),
      filePath: _readString(json['filePath']),
      sourceType: sourceTypeFromId(json['sourceType']),
      episodeTag: _readString(json['episodeTag']),
      provider: remoteProviderFromId(json['provider']),
      slug: _readString(json['slug']),
      watchUrl: _readString(json['watchUrl']),
      releaseYear: _readInt(json['releaseYear']),
      imageUrl: _readString(json['imageUrl']),
      description: _readString(json['description']),
      airDateIso: _readString(json['airDateIso']),
      durationLabel: _readString(json['durationLabel']),
    );
  }

  EpisodeItem copyWith({
    String? seriesName,
    String? seriesStateKey,
    int? episodeIndex,
    int? episodeNumber,
    String? displayName,
    String? relativePath,
    String? filePath,
    SourceType? sourceType,
    String? episodeTag,
    RemoteProvider? provider,
    bool clearProvider = false,
    String? slug,
    String? watchUrl,
    int? releaseYear,
    String? imageUrl,
    String? description,
    String? airDateIso,
    String? durationLabel,
  }) {
    return EpisodeItem(
      seriesName: seriesName ?? this.seriesName,
      seriesStateKey: seriesStateKey ?? this.seriesStateKey,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      displayName: displayName ?? this.displayName,
      relativePath: relativePath ?? this.relativePath,
      filePath: filePath ?? this.filePath,
      sourceType: sourceType ?? this.sourceType,
      episodeTag: episodeTag ?? this.episodeTag,
      provider: clearProvider ? null : provider ?? this.provider,
      slug: slug ?? this.slug,
      watchUrl: watchUrl ?? this.watchUrl,
      releaseYear: releaseYear ?? this.releaseYear,
      imageUrl: imageUrl ?? this.imageUrl,
      description: description ?? this.description,
      airDateIso: airDateIso ?? this.airDateIso,
      durationLabel: durationLabel ?? this.durationLabel,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'seriesName': seriesName,
      'seriesStateKey': seriesStateKey,
      'episodeIndex': episodeIndex,
      'episodeNumber': episodeNumber,
      'displayName': displayName,
      'relativePath': relativePath,
      'filePath': filePath,
      'sourceType': sourceType.id,
      'episodeTag': episodeTag,
      'provider': provider?.id,
      'slug': slug,
      'watchUrl': watchUrl,
      'releaseYear': releaseYear,
      'imageUrl': imageUrl,
      'description': description,
      'airDateIso': airDateIso,
      'durationLabel': durationLabel,
    };
  }
}

class SeriesItem {
  const SeriesItem({
    required this.name,
    required this.sourceType,
    required this.episodeCount,
    required this.episodes,
    this.seriesStateKey = '',
    this.provider,
    this.slug = '',
    this.watchUrl = '',
    this.imageUrl = '',
    this.backgroundUrl = '',
    this.logoUrl = '',
    this.trailerUrl = '',
    this.description = '',
    this.rating = '',
    this.releaseYear = 0,
    this.format = '',
    this.catalogId = 0,
    this.japaneseTitle = '',
    this.aliases = const [],
    this.cast = const [],
  });

  final String name;
  final String seriesStateKey;
  final SourceType sourceType;
  final RemoteProvider? provider;
  final String slug;
  final String watchUrl;
  final int episodeCount;
  final String imageUrl;
  final String backgroundUrl;
  final String logoUrl;
  final String trailerUrl;
  final String description;
  final String rating;
  final List<EpisodeItem> episodes;
  final int releaseYear;
  final String format;
  final int catalogId;
  final String japaneseTitle;
  final List<String> aliases;
  final List<String> cast;

  String get stableKey {
    final explicit = seriesStateKey.trim();
    return explicit.isNotEmpty ? explicit : normalizeSeriesKey(name);
  }

  bool get isRemote => sourceType == SourceType.remote;

  factory SeriesItem.fromJson(Map<String, dynamic> json) {
    final episodes = _readList(json['episodes'])
        .whereType<Map>()
        .map((entry) => EpisodeItem.fromJson(Map<String, dynamic>.from(entry)))
        .toList();
    return SeriesItem(
      name: _readString(json['name']),
      seriesStateKey: _readString(json['seriesStateKey']),
      sourceType: sourceTypeFromId(json['sourceType']),
      provider: remoteProviderFromId(json['provider']),
      slug: _readString(json['slug']),
      watchUrl: _readString(json['watchUrl']),
      episodeCount: _readInt(json['episodeCount'], fallback: episodes.length),
      imageUrl: _readString(json['imageUrl']),
      backgroundUrl: _readString(json['backgroundUrl']),
      logoUrl: _readString(json['logoUrl']),
      trailerUrl: _readString(json['trailerUrl']),
      description: _readString(json['description']),
      rating: _readString(json['rating']),
      episodes: episodes,
      releaseYear: _readInt(json['releaseYear']),
      format: _readString(json['format']),
      catalogId: _readInt(json['catalogId']),
      japaneseTitle: _readString(json['japaneseTitle']),
      aliases: _readStringList(json['aliases']),
      cast: _readStringList(json['cast']),
    );
  }

  SeriesItem copyWith({
    String? name,
    String? seriesStateKey,
    SourceType? sourceType,
    RemoteProvider? provider,
    bool clearProvider = false,
    String? slug,
    String? watchUrl,
    int? episodeCount,
    String? imageUrl,
    String? backgroundUrl,
    String? logoUrl,
    String? trailerUrl,
    String? description,
    String? rating,
    List<EpisodeItem>? episodes,
    int? releaseYear,
    String? format,
    int? catalogId,
    String? japaneseTitle,
    List<String>? aliases,
    List<String>? cast,
  }) {
    return SeriesItem(
      name: name ?? this.name,
      seriesStateKey: seriesStateKey ?? this.seriesStateKey,
      sourceType: sourceType ?? this.sourceType,
      provider: clearProvider ? null : provider ?? this.provider,
      slug: slug ?? this.slug,
      watchUrl: watchUrl ?? this.watchUrl,
      episodeCount: episodeCount ?? this.episodeCount,
      imageUrl: imageUrl ?? this.imageUrl,
      backgroundUrl: backgroundUrl ?? this.backgroundUrl,
      logoUrl: logoUrl ?? this.logoUrl,
      trailerUrl: trailerUrl ?? this.trailerUrl,
      description: description ?? this.description,
      rating: rating ?? this.rating,
      episodes: episodes ?? this.episodes,
      releaseYear: releaseYear ?? this.releaseYear,
      format: format ?? this.format,
      catalogId: catalogId ?? this.catalogId,
      japaneseTitle: japaneseTitle ?? this.japaneseTitle,
      aliases: aliases ?? this.aliases,
      cast: cast ?? this.cast,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'seriesStateKey': seriesStateKey,
      'sourceType': sourceType.id,
      'provider': provider?.id,
      'slug': slug,
      'watchUrl': watchUrl,
      'episodeCount': episodeCount,
      'imageUrl': imageUrl,
      'backgroundUrl': backgroundUrl,
      'logoUrl': logoUrl,
      'trailerUrl': trailerUrl,
      'description': description,
      'rating': rating,
      'episodes': episodes.map((episode) => episode.toJson()).toList(),
      'releaseYear': releaseYear,
      'format': format,
      'catalogId': catalogId,
      'japaneseTitle': japaneseTitle,
      'aliases': aliases,
      'cast': cast,
    };
  }
}

class SeriesEpisodeMetadata {
  const SeriesEpisodeMetadata({
    required this.episodeNumber,
    this.title = '',
    this.description = '',
    this.imageUrl = '',
    this.durationLabel = '',
    this.airDateIso = '',
  });

  final int episodeNumber;
  final String title;
  final String description;
  final String imageUrl;
  final String durationLabel;
  final String airDateIso;

  factory SeriesEpisodeMetadata.fromJson(Map<String, dynamic> json) {
    return SeriesEpisodeMetadata(
      episodeNumber: _readInt(json['episodeNumber']),
      title: _readString(json['title']),
      description: _readString(json['description']),
      imageUrl: _readString(json['imageUrl']),
      durationLabel: _readString(json['durationLabel']),
      airDateIso: _readString(json['airDateIso']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'episodeNumber': episodeNumber,
      'title': title,
      'description': description,
      'imageUrl': imageUrl,
      'durationLabel': durationLabel,
      'airDateIso': airDateIso,
    };
  }
}

class RemoteSearchCandidate {
  const RemoteSearchCandidate({
    required this.provider,
    required this.slug,
    required this.title,
    this.watchUrl = '',
    this.seriesUrl = '',
    this.imageUrl = '',
    this.backgroundUrl = '',
    this.logoUrl = '',
    this.trailerUrl = '',
    this.description = '',
    this.rating = '',
    this.episodeCount = 0,
    this.format = '',
    this.japaneseTitle = '',
    this.aliases = const [],
    this.releaseYear = 0,
    this.airDateIso = '',
    this.catalogId = 0,
    this.cast = const [],
    this.episodeDetails = const [],
    this.relationLabel = '',
  });

  final RemoteProvider provider;
  final String slug;
  final String title;
  final String watchUrl;
  final String seriesUrl;
  final String imageUrl;
  final String backgroundUrl;
  final String logoUrl;
  final String trailerUrl;
  final String description;
  final String rating;
  final int episodeCount;
  final String format;
  final String japaneseTitle;
  final List<String> aliases;
  final int releaseYear;
  final String airDateIso;
  final int catalogId;
  final List<String> cast;
  final List<SeriesEpisodeMetadata> episodeDetails;
  final String relationLabel;

  SeriesItem toSeries({required Iterable<String> existingNames}) {
    final name = uniqueSeriesName(title, existingNames, provider.label);
    final stateKey = normalizeSeriesKey(name);
    final detailsByEpisode = {
      for (final detail in episodeDetails)
        if (detail.episodeNumber >= 0) detail.episodeNumber: detail,
    };
    final explicitEpisodeNumbers = detailsByEpisode.keys.toList()..sort();
    final count = episodeCount > 0
        ? episodeCount
        : provider == RemoteProvider.catalog
            ? explicitEpisodeNumbers.length
            : 1;
    final episodeNumbers = explicitEpisodeNumbers.isNotEmpty
        ? [
            ...explicitEpisodeNumbers,
            if (explicitEpisodeNumbers.length < count)
              for (var episodeNumber = 1;
                  episodeNumber <= count;
                  episodeNumber += 1)
                if (!detailsByEpisode.containsKey(episodeNumber)) episodeNumber,
          ]
        : List.generate(count, (index) => index + 1);
    final episodes = episodeNumbers.asMap().entries.map((entry) {
      final index = entry.key;
      final episodeNumber = entry.value;
      final detail = detailsByEpisode[episodeNumber];
      final episodeLabel =
          episodeNumber == 0 ? 'Episodio 0' : 'Episodio $episodeNumber';
      return EpisodeItem(
        seriesName: name,
        seriesStateKey: stateKey,
        episodeIndex: index,
        episodeNumber: episodeNumber,
        displayName:
            detail?.title.isNotEmpty == true ? detail!.title : episodeLabel,
        relativePath: episodeLabel,
        filePath: watchUrl,
        sourceType: SourceType.remote,
        provider: provider,
        slug: slug,
        watchUrl: watchUrl,
        releaseYear: releaseYear,
        imageUrl:
            detail?.imageUrl.isNotEmpty == true ? detail!.imageUrl : imageUrl,
        description: detail?.description ?? '',
        airDateIso: detail?.airDateIso ?? '',
        durationLabel: detail?.durationLabel ?? '',
      );
    }).toList();

    return SeriesItem(
      name: name,
      seriesStateKey: stateKey,
      sourceType: SourceType.remote,
      provider: provider,
      slug: slug,
      watchUrl: watchUrl,
      episodeCount: episodes.length,
      imageUrl: imageUrl,
      backgroundUrl: backgroundUrl,
      logoUrl: logoUrl,
      trailerUrl: trailerUrl,
      description: description,
      rating: rating,
      episodes: episodes,
      releaseYear: releaseYear,
      format: format,
      catalogId: catalogId,
      japaneseTitle: japaneseTitle,
      aliases: aliases,
      cast: cast,
    );
  }
}

class RemoteDirectStream {
  const RemoteDirectStream({
    required this.playbackUrl,
    required this.playbackKind,
    required this.pageUrl,
    this.availableModes = const {},
    this.availableServers = const {},
    this.selectedMode = '',
    this.provider,
    this.server = '',
    this.subtitleTracks = const [],
    this.httpHeaders = const {},
  });

  final String playbackUrl;
  final String playbackKind;
  final String pageUrl;
  final Set<String> availableModes;
  final Set<String> availableServers;
  final String selectedMode;
  final RemoteProvider? provider;
  final String server;
  final List<RemoteSubtitleTrack> subtitleTracks;
  final Map<String, String> httpHeaders;

  RemoteDirectStream copyWith({
    String? playbackUrl,
    String? playbackKind,
    String? pageUrl,
    Set<String>? availableModes,
    Set<String>? availableServers,
    String? selectedMode,
    RemoteProvider? provider,
    String? server,
    List<RemoteSubtitleTrack>? subtitleTracks,
    Map<String, String>? httpHeaders,
  }) {
    return RemoteDirectStream(
      playbackUrl: playbackUrl ?? this.playbackUrl,
      playbackKind: playbackKind ?? this.playbackKind,
      pageUrl: pageUrl ?? this.pageUrl,
      availableModes: availableModes ?? this.availableModes,
      availableServers: availableServers ?? this.availableServers,
      selectedMode: selectedMode ?? this.selectedMode,
      provider: provider ?? this.provider,
      server: server ?? this.server,
      subtitleTracks: subtitleTracks ?? this.subtitleTracks,
      httpHeaders: httpHeaders ?? this.httpHeaders,
    );
  }
}

class RemoteSubtitleTrack {
  const RemoteSubtitleTrack({
    required this.url,
    this.label = '',
    this.language = '',
    this.mimeType = '',
    this.isDefault = false,
  });

  final String url;
  final String label;
  final String language;
  final String mimeType;
  final bool isDefault;
}

class SeriesPlaybackPreference {
  const SeriesPlaybackPreference({
    this.provider,
    this.animeAv1Mode = '',
    this.animeKaiMode = '',
    this.jkAnimeServer = '',
    this.latAnimeServer = '',
    this.justAnimeMode = '',
    this.justAnimeServer = '',
    this.aniPmMode = '',
    this.aniPmServer = '',
    this.facebookMode = '',
    this.facebookOption = '',
    this.youtubeMode = '',
    this.youtubeOption = '',
    this.videoScaleMode = '',
  });

  final RemoteProvider? provider;
  final String animeAv1Mode;
  final String animeKaiMode;
  final String jkAnimeServer;
  final String latAnimeServer;
  final String justAnimeMode;
  final String justAnimeServer;
  final String aniPmMode;
  final String aniPmServer;
  final String facebookMode;
  final String facebookOption;
  final String youtubeMode;
  final String youtubeOption;
  final String videoScaleMode;

  factory SeriesPlaybackPreference.fromJson(Map<String, dynamic> json) {
    final rawVideoScaleMode = _readString(json['videoScaleMode']);
    final rawProvider = remoteProviderFromId(json['provider']);
    return SeriesPlaybackPreference(
      provider: rawProvider == RemoteProvider.animeKai ? null : rawProvider,
      animeAv1Mode: _normalizeOptionalAnimeAv1Mode(json['animeAv1Mode']),
      animeKaiMode: _readString(json['animeKaiMode']),
      jkAnimeServer: _normalizeOptionalJkAnimeServer(json['jkAnimeServer']),
      latAnimeServer: _normalizeOptionalLatAnimeServer(json['latAnimeServer']),
      justAnimeMode: _readString(json['justAnimeMode']),
      justAnimeServer: _readString(json['justAnimeServer']),
      aniPmMode: _readString(json['aniPmMode']),
      aniPmServer: _readString(json['aniPmServer']),
      facebookMode: _normalizeOptionalFacebookMode(json['facebookMode']),
      facebookOption: _normalizeOptionalFacebookOption(json['facebookOption']),
      youtubeMode: _normalizeOptionalYoutubeMode(json['youtubeMode']),
      youtubeOption: _normalizeOptionalYoutubeOption(json['youtubeOption']),
      videoScaleMode: rawVideoScaleMode.trim().isEmpty
          ? ''
          : videoScaleModeFromId(rawVideoScaleMode).id,
    );
  }

  SeriesPlaybackPreference copyWith({
    RemoteProvider? provider,
    bool clearProvider = false,
    String? animeAv1Mode,
    String? animeKaiMode,
    String? jkAnimeServer,
    String? latAnimeServer,
    String? justAnimeMode,
    String? justAnimeServer,
    String? aniPmMode,
    String? aniPmServer,
    String? facebookMode,
    String? facebookOption,
    String? youtubeMode,
    String? youtubeOption,
    String? videoScaleMode,
  }) {
    return SeriesPlaybackPreference(
      provider: clearProvider ? null : provider ?? this.provider,
      animeAv1Mode: animeAv1Mode == null
          ? this.animeAv1Mode
          : _normalizeOptionalAnimeAv1Mode(animeAv1Mode),
      animeKaiMode: animeKaiMode ?? this.animeKaiMode,
      jkAnimeServer: jkAnimeServer == null
          ? this.jkAnimeServer
          : _normalizeOptionalJkAnimeServer(jkAnimeServer),
      latAnimeServer: latAnimeServer == null
          ? this.latAnimeServer
          : _normalizeOptionalLatAnimeServer(latAnimeServer),
      justAnimeMode: justAnimeMode ?? this.justAnimeMode,
      justAnimeServer: justAnimeServer ?? this.justAnimeServer,
      aniPmMode: aniPmMode ?? this.aniPmMode,
      aniPmServer: aniPmServer ?? this.aniPmServer,
      facebookMode: facebookMode == null
          ? this.facebookMode
          : _normalizeOptionalFacebookMode(facebookMode),
      facebookOption: facebookOption == null
          ? this.facebookOption
          : _normalizeOptionalFacebookOption(facebookOption),
      youtubeMode: youtubeMode == null
          ? this.youtubeMode
          : _normalizeOptionalYoutubeMode(youtubeMode),
      youtubeOption: youtubeOption == null
          ? this.youtubeOption
          : _normalizeOptionalYoutubeOption(youtubeOption),
      videoScaleMode: videoScaleMode == null
          ? this.videoScaleMode
          : videoScaleMode.trim().isEmpty
              ? ''
              : videoScaleModeFromId(videoScaleMode).id,
    );
  }

  bool get isMeaningful {
    return provider != null ||
        animeAv1Mode.trim().isNotEmpty ||
        animeKaiMode.trim().isNotEmpty ||
        jkAnimeServer.trim().isNotEmpty ||
        latAnimeServer.trim().isNotEmpty ||
        justAnimeMode.trim().isNotEmpty ||
        justAnimeServer.trim().isNotEmpty ||
        aniPmMode.trim().isNotEmpty ||
        aniPmServer.trim().isNotEmpty ||
        facebookMode.trim().isNotEmpty ||
        facebookOption.trim().isNotEmpty ||
        youtubeMode.trim().isNotEmpty ||
        youtubeOption.trim().isNotEmpty ||
        videoScaleMode.trim().isNotEmpty;
  }

  Map<String, dynamic> toJson() {
    return {
      'provider': provider?.id,
      'animeAv1Mode': _normalizeOptionalAnimeAv1Mode(animeAv1Mode),
      'animeKaiMode': animeKaiMode,
      'jkAnimeServer': _normalizeOptionalJkAnimeServer(jkAnimeServer),
      'latAnimeServer': _normalizeOptionalLatAnimeServer(latAnimeServer),
      'justAnimeMode': justAnimePlaybackModeFromId(justAnimeMode).id,
      'justAnimeServer': justAnimeServerPreferenceFromId(justAnimeServer).id,
      'aniPmMode': aniPmPlaybackModeFromId(aniPmMode).id,
      'aniPmServer': aniPmServer.trim(),
      'facebookMode': _normalizeOptionalFacebookMode(facebookMode),
      'facebookOption': _normalizeOptionalFacebookOption(facebookOption),
      'youtubeMode': _normalizeOptionalYoutubeMode(youtubeMode),
      'youtubeOption': _normalizeOptionalYoutubeOption(youtubeOption),
      'videoScaleMode': videoScaleMode.trim().isEmpty
          ? ''
          : videoScaleModeFromId(videoScaleMode).id,
    };
  }
}

class MyAnimeListAuthState {
  const MyAnimeListAuthState({
    this.accessToken = '',
    this.refreshToken = '',
    this.expiresAtMs = 0,
    this.userId = 0,
    this.userName = '',
    this.userPictureUrl = '',
    this.connectedAtMs = 0,
    this.lastSyncAtMs = 0,
    this.lastSyncStatus = '',
    this.lastSyncError = '',
  });

  final String accessToken;
  final String refreshToken;
  final int expiresAtMs;
  final int userId;
  final String userName;
  final String userPictureUrl;
  final int connectedAtMs;
  final int lastSyncAtMs;
  final String lastSyncStatus;
  final String lastSyncError;

  bool get isConnected =>
      accessToken.trim().isNotEmpty &&
      refreshToken.trim().isNotEmpty &&
      userId > 0;

  factory MyAnimeListAuthState.fromJson(Map<String, dynamic> json) {
    return MyAnimeListAuthState(
      accessToken: _readString(json['accessToken']),
      refreshToken: _readString(json['refreshToken']),
      expiresAtMs: _readInt(json['expiresAtMs']),
      userId: _readInt(json['userId']),
      userName: _readString(json['userName']),
      userPictureUrl: _readString(json['userPictureUrl']),
      connectedAtMs: _readInt(json['connectedAtMs']),
      lastSyncAtMs: _readInt(json['lastSyncAtMs']),
      lastSyncStatus: _readString(json['lastSyncStatus']),
      lastSyncError: _readString(json['lastSyncError']),
    );
  }

  MyAnimeListAuthState copyWith({
    String? accessToken,
    String? refreshToken,
    int? expiresAtMs,
    int? userId,
    String? userName,
    String? userPictureUrl,
    int? connectedAtMs,
    int? lastSyncAtMs,
    String? lastSyncStatus,
    String? lastSyncError,
  }) {
    return MyAnimeListAuthState(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAtMs: expiresAtMs ?? this.expiresAtMs,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userPictureUrl: userPictureUrl ?? this.userPictureUrl,
      connectedAtMs: connectedAtMs ?? this.connectedAtMs,
      lastSyncAtMs: lastSyncAtMs ?? this.lastSyncAtMs,
      lastSyncStatus: lastSyncStatus ?? this.lastSyncStatus,
      lastSyncError: lastSyncError ?? this.lastSyncError,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'expiresAtMs': expiresAtMs,
      'userId': userId,
      'userName': userName,
      'userPictureUrl': userPictureUrl,
      'connectedAtMs': connectedAtMs,
      'lastSyncAtMs': lastSyncAtMs,
      'lastSyncStatus': lastSyncStatus,
      'lastSyncError': lastSyncError,
    };
  }
}

class SimklAuthState {
  const SimklAuthState({
    this.accessToken = '',
    this.userId = 0,
    this.userName = '',
    this.userAvatarUrl = '',
    this.connectedAtMs = 0,
    this.lastSyncAtMs = 0,
    this.lastSyncStatus = '',
    this.lastSyncError = '',
  });

  final String accessToken;
  final int userId;
  final String userName;
  final String userAvatarUrl;
  final int connectedAtMs;
  final int lastSyncAtMs;
  final String lastSyncStatus;
  final String lastSyncError;

  bool get isConnected => accessToken.trim().isNotEmpty && userId > 0;

  factory SimklAuthState.fromJson(Map<String, dynamic> json) {
    return SimklAuthState(
      accessToken: _readString(json['accessToken']),
      userId: _readInt(json['userId']),
      userName: _readString(json['userName']),
      userAvatarUrl: _readString(json['userAvatarUrl']),
      connectedAtMs: _readInt(json['connectedAtMs']),
      lastSyncAtMs: _readInt(json['lastSyncAtMs']),
      lastSyncStatus: _readString(json['lastSyncStatus']),
      lastSyncError: _readString(json['lastSyncError']),
    );
  }

  SimklAuthState copyWith({
    String? accessToken,
    int? userId,
    String? userName,
    String? userAvatarUrl,
    int? connectedAtMs,
    int? lastSyncAtMs,
    String? lastSyncStatus,
    String? lastSyncError,
  }) {
    return SimklAuthState(
      accessToken: accessToken ?? this.accessToken,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userAvatarUrl: userAvatarUrl ?? this.userAvatarUrl,
      connectedAtMs: connectedAtMs ?? this.connectedAtMs,
      lastSyncAtMs: lastSyncAtMs ?? this.lastSyncAtMs,
      lastSyncStatus: lastSyncStatus ?? this.lastSyncStatus,
      lastSyncError: lastSyncError ?? this.lastSyncError,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'userId': userId,
      'userName': userName,
      'userAvatarUrl': userAvatarUrl,
      'connectedAtMs': connectedAtMs,
      'lastSyncAtMs': lastSyncAtMs,
      'lastSyncStatus': lastSyncStatus,
      'lastSyncError': lastSyncError,
    };
  }
}

class EpisodePlaybackRecord {
  static const int completionThresholdPercent = 97;

  const EpisodePlaybackRecord({
    this.positionMs = 0,
    this.durationMs = 0,
    this.completed = false,
    this.remoteProgressPercent = 0,
    this.updatedAtMs = 0,
  });

  final int positionMs;
  final int durationMs;
  final bool completed;
  final double remoteProgressPercent;
  final int updatedAtMs;

  factory EpisodePlaybackRecord.normalized({
    int positionMs = 0,
    int durationMs = 0,
    bool completed = false,
    double remoteProgressPercent = 0,
    int updatedAtMs = 0,
  }) {
    final normalizedDuration = durationMs < 0 ? 0 : durationMs;
    final rawPosition = positionMs < 0 ? 0 : positionMs;
    final isCompleted = completed ||
        (normalizedDuration > 0 &&
            rawPosition * 100 >=
                normalizedDuration * completionThresholdPercent);
    return EpisodePlaybackRecord(
      positionMs: isCompleted && normalizedDuration > 0
          ? normalizedDuration
          : rawPosition,
      durationMs: normalizedDuration,
      completed: isCompleted,
      remoteProgressPercent: remoteProgressPercent.clamp(0, 100).toDouble(),
      updatedAtMs: updatedAtMs < 0 ? 0 : updatedAtMs,
    );
  }

  factory EpisodePlaybackRecord.fromJson(Map<String, dynamic> json) {
    return EpisodePlaybackRecord.normalized(
      positionMs: _readInt(json['positionMs']),
      durationMs: _readInt(json['durationMs']),
      completed: _readBool(json['completed']),
      remoteProgressPercent:
          double.tryParse('${json['remoteProgressPercent'] ?? 0}') ?? 0,
      updatedAtMs: _readInt(json['updatedAtMs']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'positionMs': positionMs,
      'durationMs': durationMs,
      'completed': completed,
      'remoteProgressPercent': remoteProgressPercent,
      'updatedAtMs': updatedAtMs,
    };
  }
}

class FillerMetadataRecord {
  const FillerMetadataRecord({
    this.status = 'missing',
    this.provider = 'animefillerlist',
    this.showSlug = '',
    this.showName = '',
    this.episodeMap = const {},
  });

  final String status;
  final String provider;
  final String showSlug;
  final String showName;
  final Map<String, String> episodeMap;

  bool get found => status == 'found' && episodeMap.isNotEmpty;

  factory FillerMetadataRecord.fromJson(Map<String, dynamic> json) {
    return FillerMetadataRecord(
      status: _readString(json['status'], fallback: 'missing'),
      provider: _readString(json['provider'], fallback: 'animefillerlist'),
      showSlug: _readString(json['showSlug']),
      showName: _readString(json['showName']),
      episodeMap: _readStringMap(json['episodeMap']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'status': status,
      'provider': provider,
      'showSlug': showSlug,
      'showName': showName,
      'episodeMap': episodeMap,
    };
  }
}

class CandidateVisualCacheEntry {
  const CandidateVisualCacheEntry({
    this.imageUrl = '',
    this.backgroundUrl = '',
    this.logoUrl = '',
    this.trailerUrl = '',
    this.description = '',
    this.rating = '',
    this.japaneseTitle = '',
    this.aliases = const [],
    this.cast = const [],
    this.episodeDetails = const [],
    this.cachedAtMs = 0,
  });

  final String imageUrl;
  final String backgroundUrl;
  final String logoUrl;
  final String trailerUrl;
  final String description;
  final String rating;
  final String japaneseTitle;
  final List<String> aliases;
  final List<String> cast;
  final List<SeriesEpisodeMetadata> episodeDetails;
  final int cachedAtMs;

  bool get hasMeaningfulContent =>
      imageUrl.isNotEmpty ||
      backgroundUrl.isNotEmpty ||
      logoUrl.isNotEmpty ||
      trailerUrl.isNotEmpty ||
      description.isNotEmpty ||
      rating.isNotEmpty ||
      japaneseTitle.isNotEmpty ||
      aliases.isNotEmpty ||
      cast.isNotEmpty ||
      episodeDetails.isNotEmpty;

  factory CandidateVisualCacheEntry.fromJson(Map<String, dynamic> json) {
    return CandidateVisualCacheEntry(
      imageUrl: _readString(json['imageUrl']),
      backgroundUrl: _readString(json['backgroundUrl']),
      logoUrl: _readString(json['logoUrl']),
      trailerUrl: _readString(json['trailerUrl']),
      description: _readString(json['description']),
      rating: _readString(json['rating']),
      japaneseTitle: _readString(json['japaneseTitle']),
      aliases: _readStringList(json['aliases']),
      cast: _readStringList(json['cast']),
      episodeDetails: _readEpisodeMetadataList(json['episodeDetails']),
      cachedAtMs: _readInt(json['cachedAtMs']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'imageUrl': imageUrl,
      'backgroundUrl': backgroundUrl,
      'logoUrl': logoUrl,
      'trailerUrl': trailerUrl,
      'description': description,
      'rating': rating,
      'japaneseTitle': japaneseTitle,
      'aliases': aliases,
      'cast': cast,
      'episodeDetails':
          episodeDetails.map((episode) => episode.toJson()).toList(),
      'cachedAtMs': cachedAtMs,
    };
  }
}

List<SeriesEpisodeMetadata> _readEpisodeMetadataList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value
      .whereType<Map>()
      .map((entry) => SeriesEpisodeMetadata.fromJson(
            entry.map((key, value) => MapEntry('$key', value)),
          ))
      .where((entry) => entry.episodeNumber >= 0)
      .toList(growable: false);
}

class PlaylistPlaybackOrder {
  const PlaylistPlaybackOrder._();

  static const tvSerial = 'tv_serial';
  static const tvRandom = 'tv_random';
  static const tv = tvSerial;
  static const series = tvRandom;

  static String normalize(Object? value) {
    return switch ('$value'.trim().toLowerCase()) {
      'series' ||
      'tv_random' ||
      'tv-random' ||
      'tvrandom' ||
      'random' =>
        tvRandom,
      _ => tvSerial,
    };
  }
}

class PlaylistState {
  const PlaylistState({
    required this.id,
    required this.name,
    this.selectedSeries = const {},
    this.progress = const {},
    this.lastPlayedSeriesName = '',
    this.playbackOrder = PlaylistPlaybackOrder.tv,
  });

  final String id;
  final String name;
  final Set<String> selectedSeries;
  final Map<String, int> progress;
  final String lastPlayedSeriesName;
  final String playbackOrder;

  factory PlaylistState.defaultPlaylist() {
    return const PlaylistState(id: 'default', name: 'Playlist principal');
  }

  factory PlaylistState.fromJson(Map<String, dynamic> json) {
    final rawProgress =
        json['progress'] is Map ? json['progress'] as Map : const {};
    return PlaylistState(
      id: _readString(json['id'], fallback: 'default'),
      name: _readString(json['name'], fallback: 'Playlist principal'),
      selectedSeries: _readStringList(json['selectedSeries']).toSet(),
      progress:
          rawProgress.map((key, value) => MapEntry('$key', _readInt(value))),
      lastPlayedSeriesName: _readString(json['lastPlayedSeriesName']),
      playbackOrder: PlaylistPlaybackOrder.normalize(json['playbackOrder']),
    );
  }

  PlaylistState copyWith({
    String? id,
    String? name,
    Set<String>? selectedSeries,
    Map<String, int>? progress,
    String? lastPlayedSeriesName,
    String? playbackOrder,
  }) {
    return PlaylistState(
      id: id ?? this.id,
      name: name ?? this.name,
      selectedSeries: selectedSeries ?? this.selectedSeries,
      progress: progress ?? this.progress,
      lastPlayedSeriesName: lastPlayedSeriesName ?? this.lastPlayedSeriesName,
      playbackOrder: playbackOrder == null
          ? this.playbackOrder
          : PlaylistPlaybackOrder.normalize(playbackOrder),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'selectedSeries': selectedSeries.toList()..sort(),
      'progress': progress,
      'lastPlayedSeriesName': lastPlayedSeriesName,
      'playbackOrder': PlaylistPlaybackOrder.normalize(playbackOrder),
    };
  }
}

class UserProfileState {
  const UserProfileState({
    this.id = 'principal',
    this.name = 'Principal',
    this.avatarPresetId = 'avatar_01',
    this.playlists = const [
      PlaylistState(id: 'default', name: 'Playlist principal')
    ],
    this.activePlaylistId = 'default',
    this.favoriteSeries = const {},
    this.watchlistSeries = const {},
    this.watchingSeries = const {},
    this.abandonedSeries = const {},
    this.completedSeries = const {},
    this.externalNoStatusSeries = const {},
    this.episodePlayback = const {},
    this.preferredRemoteProvider,
    this.seriesPlaybackPreferences = const {},
    this.currentEntry,
    this.myAnimeListAuth = const MyAnimeListAuthState(),
    this.myAnimeListMappings = const {},
    this.simklAuth = const SimklAuthState(),
    this.simklMappings = const {},
  });

  final String id;
  final String name;
  final String avatarPresetId;
  final List<PlaylistState> playlists;
  final String activePlaylistId;
  final Set<String> favoriteSeries;
  final Set<String> watchlistSeries;
  final Set<String> watchingSeries;
  final Set<String> abandonedSeries;
  final Set<String> completedSeries;
  final Set<String> externalNoStatusSeries;
  final Map<String, EpisodePlaybackRecord> episodePlayback;
  final RemoteProvider? preferredRemoteProvider;
  final Map<String, SeriesPlaybackPreference> seriesPlaybackPreferences;
  final EpisodeItem? currentEntry;
  final MyAnimeListAuthState myAnimeListAuth;
  final Map<String, int> myAnimeListMappings;
  final SimklAuthState simklAuth;
  final Map<String, int> simklMappings;

  PlaylistState get activePlaylist {
    return playlists.firstWhere(
      (playlist) => playlist.id == activePlaylistId,
      orElse: () => playlists.first,
    );
  }

  factory UserProfileState.fromJson(Map<String, dynamic> json) {
    final playlists = _readList(json['playlists'])
        .whereType<Map>()
        .map(
            (entry) => PlaylistState.fromJson(Map<String, dynamic>.from(entry)))
        .toList();
    final normalizedPlaylists =
        playlists.isEmpty ? [PlaylistState.defaultPlaylist()] : playlists;
    final activeId = _readString(json['activePlaylistId']);
    final preferredProvider =
        remoteProviderFromId(json['preferredRemoteProvider']);
    return UserProfileState(
      id: _readString(json['id'], fallback: 'principal'),
      name: _readString(json['name'], fallback: 'Principal'),
      avatarPresetId:
          _readString(json['avatarPresetId'], fallback: 'avatar_01'),
      playlists: normalizedPlaylists,
      activePlaylistId:
          normalizedPlaylists.any((playlist) => playlist.id == activeId)
              ? activeId
              : normalizedPlaylists.first.id,
      favoriteSeries: _readStringList(json['favoriteSeries']).toSet(),
      watchlistSeries: _readStringList(json['watchlistSeries']).toSet(),
      watchingSeries: _readStringList(json['watchingSeries']).toSet(),
      abandonedSeries: _readStringList(json['abandonedSeries']).toSet(),
      completedSeries: _readStringList(json['completedSeries']).toSet(),
      externalNoStatusSeries:
          _readStringList(json['externalNoStatusSeries']).toSet(),
      episodePlayback: _readEpisodePlaybackMap(json['episodePlayback']),
      preferredRemoteProvider: preferredProvider == RemoteProvider.animeKai
          ? null
          : preferredProvider,
      seriesPlaybackPreferences:
          _readSeriesPlaybackPreferenceMap(json['seriesPlaybackPreferences']),
      currentEntry: json['currentEntry'] is Map
          ? EpisodeItem.fromJson(
              Map<String, dynamic>.from(json['currentEntry'] as Map))
          : null,
      myAnimeListAuth: json['myAnimeListAuth'] is Map
          ? MyAnimeListAuthState.fromJson(
              Map<String, dynamic>.from(json['myAnimeListAuth'] as Map))
          : const MyAnimeListAuthState(),
      myAnimeListMappings: _readIntMap(json['myAnimeListMappings']),
      simklAuth: json['simklAuth'] is Map
          ? SimklAuthState.fromJson(
              Map<String, dynamic>.from(json['simklAuth'] as Map))
          : const SimklAuthState(),
      simklMappings: _readIntMap(json['simklMappings']),
    );
  }

  UserProfileState copyWith({
    String? id,
    String? name,
    String? avatarPresetId,
    List<PlaylistState>? playlists,
    String? activePlaylistId,
    Set<String>? favoriteSeries,
    Set<String>? watchlistSeries,
    Set<String>? watchingSeries,
    Set<String>? abandonedSeries,
    Set<String>? completedSeries,
    Set<String>? externalNoStatusSeries,
    Map<String, EpisodePlaybackRecord>? episodePlayback,
    RemoteProvider? preferredRemoteProvider,
    bool clearPreferredRemoteProvider = false,
    Map<String, SeriesPlaybackPreference>? seriesPlaybackPreferences,
    EpisodeItem? currentEntry,
    bool clearCurrentEntry = false,
    MyAnimeListAuthState? myAnimeListAuth,
    Map<String, int>? myAnimeListMappings,
    bool clearMyAnimeList = false,
    SimklAuthState? simklAuth,
    Map<String, int>? simklMappings,
    bool clearSimkl = false,
  }) {
    final nextPlaylists = playlists ?? this.playlists;
    final requestedActive = activePlaylistId ?? this.activePlaylistId;
    return UserProfileState(
      id: id ?? this.id,
      name: name ?? this.name,
      avatarPresetId: avatarPresetId ?? this.avatarPresetId,
      playlists: nextPlaylists,
      activePlaylistId:
          nextPlaylists.any((playlist) => playlist.id == requestedActive)
              ? requestedActive
              : nextPlaylists.first.id,
      favoriteSeries: favoriteSeries ?? this.favoriteSeries,
      watchlistSeries: watchlistSeries ?? this.watchlistSeries,
      watchingSeries: watchingSeries ?? this.watchingSeries,
      abandonedSeries: abandonedSeries ?? this.abandonedSeries,
      completedSeries: completedSeries ?? this.completedSeries,
      externalNoStatusSeries:
          externalNoStatusSeries ?? this.externalNoStatusSeries,
      episodePlayback: episodePlayback ?? this.episodePlayback,
      preferredRemoteProvider: clearPreferredRemoteProvider
          ? null
          : preferredRemoteProvider ?? this.preferredRemoteProvider,
      seriesPlaybackPreferences:
          seriesPlaybackPreferences ?? this.seriesPlaybackPreferences,
      currentEntry:
          clearCurrentEntry ? null : currentEntry ?? this.currentEntry,
      myAnimeListAuth: clearMyAnimeList
          ? const MyAnimeListAuthState()
          : myAnimeListAuth ?? this.myAnimeListAuth,
      myAnimeListMappings: clearMyAnimeList
          ? const {}
          : myAnimeListMappings ?? this.myAnimeListMappings,
      simklAuth:
          clearSimkl ? const SimklAuthState() : simklAuth ?? this.simklAuth,
      simklMappings:
          clearSimkl ? const {} : simklMappings ?? this.simklMappings,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'avatarPresetId': avatarPresetId,
      'playlists': playlists.map((playlist) => playlist.toJson()).toList(),
      'activePlaylistId': activePlaylistId,
      'favoriteSeries': favoriteSeries.toList()..sort(),
      'watchlistSeries': watchlistSeries.toList()..sort(),
      'watchingSeries': watchingSeries.toList()..sort(),
      'abandonedSeries': abandonedSeries.toList()..sort(),
      'completedSeries': completedSeries.toList()..sort(),
      'externalNoStatusSeries': externalNoStatusSeries.toList()..sort(),
      'episodePlayback': episodePlayback.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'preferredRemoteProvider': preferredRemoteProvider?.id,
      'seriesPlaybackPreferences': seriesPlaybackPreferences.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'currentEntry': currentEntry?.toJson(),
      'myAnimeListAuth': myAnimeListAuth.toJson(),
      'myAnimeListMappings': myAnimeListMappings,
      'simklAuth': simklAuth.toJson(),
      'simklMappings': simklMappings,
    };
  }
}

class AppState {
  static const schemaVersion = 1;

  const AppState({
    this.rootPaths = const [],
    this.remoteLibrary = const [],
    this.showSeriesUpcomingCards = true,
    this.showPlaylistUpcomingCards = true,
    this.skipMixedEpisodes = false,
    this.skipFillerEpisodes = false,
    this.skipOpeningSegments = false,
    this.skipEndingSegments = false,
    this.skipMixedOpeningSegments = false,
    this.skipMixedEndingSegments = false,
    this.skipRecapSegments = false,
    this.overscanHorizontal = 0,
    this.overscanTop = 0,
    this.overscanBottom = 0,
    this.androidVideoViewMode = AndroidVideoViewMode.automatic,
    this.fillerCache = const {},
    this.visualCache = const {},
    this.myAnimeListClientId = '',
    this.myAnimeListClientSecret = '',
    this.simklClientId = '',
    this.profiles = const [UserProfileState()],
    this.activeProfileId = '',
    this.defaultProfileId = '',
  });

  final List<String> rootPaths;
  final List<SeriesItem> remoteLibrary;
  final bool showSeriesUpcomingCards;
  final bool showPlaylistUpcomingCards;
  final bool skipMixedEpisodes;
  final bool skipFillerEpisodes;
  final bool skipOpeningSegments;
  final bool skipEndingSegments;
  final bool skipMixedOpeningSegments;
  final bool skipMixedEndingSegments;
  final bool skipRecapSegments;
  final double overscanHorizontal;
  final double overscanTop;
  final double overscanBottom;
  final AndroidVideoViewMode androidVideoViewMode;
  final Map<String, FillerMetadataRecord> fillerCache;
  final Map<String, CandidateVisualCacheEntry> visualCache;
  final String myAnimeListClientId;
  final String myAnimeListClientSecret;
  final String simklClientId;
  final List<UserProfileState> profiles;
  final String activeProfileId;
  final String defaultProfileId;

  factory AppState.initial() {
    return const AppState();
  }

  factory AppState.fromJson(Map<String, dynamic> json) {
    final legacyProfile = json['profile'] is Map
        ? UserProfileState.fromJson(
            Map<String, dynamic>.from(json['profile'] as Map))
        : const UserProfileState();
    final parsedProfiles = _readList(json['profiles'])
        .whereType<Map>()
        .map((entry) =>
            UserProfileState.fromJson(Map<String, dynamic>.from(entry)))
        .toList();
    final rootPlayback = _readEpisodePlaybackMap(json['episodePlayback']);
    final migratedProfile =
        rootPlayback.isEmpty || legacyProfile.episodePlayback.isNotEmpty
            ? legacyProfile
            : legacyProfile.copyWith(episodePlayback: rootPlayback);
    final profiles = _normalizeProfiles(
        parsedProfiles.isEmpty ? [migratedProfile] : parsedProfiles);
    return AppState(
      rootPaths: _readStringList(json['rootPaths']),
      remoteLibrary: _readList(json['remoteLibrary'])
          .whereType<Map>()
          .map((entry) => SeriesItem.fromJson(Map<String, dynamic>.from(entry)))
          .where(
              (series) => series.name.isNotEmpty && series.episodes.isNotEmpty)
          .toList(),
      showSeriesUpcomingCards:
          _readBool(json['showSeriesUpcomingCards'], fallback: true),
      showPlaylistUpcomingCards:
          _readBool(json['showPlaylistUpcomingCards'], fallback: true),
      skipMixedEpisodes: _readBool(json['skipMixedEpisodes']),
      skipFillerEpisodes: _readBool(json['skipFillerEpisodes']),
      skipOpeningSegments: _readBool(json['skipOpeningSegments']),
      skipEndingSegments: _readBool(json['skipEndingSegments']),
      skipMixedOpeningSegments: _readBool(json['skipMixedOpeningSegments']),
      skipMixedEndingSegments: _readBool(json['skipMixedEndingSegments']),
      skipRecapSegments: _readBool(json['skipRecapSegments']),
      overscanHorizontal: _readDouble(json['overscanHorizontal']),
      overscanTop: _readDouble(json['overscanTop']),
      overscanBottom: _readDouble(json['overscanBottom']),
      androidVideoViewMode:
          androidVideoViewModeFromId(json['androidVideoViewMode']),
      fillerCache: _readFillerCache(json['fillerCache']),
      visualCache: _readCandidateVisualCache(json['visualCache']),
      myAnimeListClientId: _readString(json['myAnimeListClientId']),
      myAnimeListClientSecret: _readString(json['myAnimeListClientSecret']),
      simklClientId: _readString(json['simklClientId']),
      profiles: profiles,
      activeProfileId: _resolveProfileId(
        profiles,
        _readString(json['activeProfileId']),
      ),
      defaultProfileId: _resolveProfileId(
        profiles,
        _readString(json['defaultProfileId']),
        allowEmpty: true,
      ),
    );
  }

  UserProfileState get profile {
    if (profiles.isEmpty) {
      return const UserProfileState();
    }
    return profiles.firstWhere(
      (entry) => entry.id == activeProfileId,
      orElse: () => profiles.firstWhere(
        (entry) => entry.id == defaultProfileId,
        orElse: () => profiles.first,
      ),
    );
  }

  PlaylistState get activePlaylist => profile.activePlaylist;

  AppState copyWith({
    List<String>? rootPaths,
    List<SeriesItem>? remoteLibrary,
    bool? showSeriesUpcomingCards,
    bool? showPlaylistUpcomingCards,
    bool? skipMixedEpisodes,
    bool? skipFillerEpisodes,
    bool? skipOpeningSegments,
    bool? skipEndingSegments,
    bool? skipMixedOpeningSegments,
    bool? skipMixedEndingSegments,
    bool? skipRecapSegments,
    double? overscanHorizontal,
    double? overscanTop,
    double? overscanBottom,
    AndroidVideoViewMode? androidVideoViewMode,
    Map<String, FillerMetadataRecord>? fillerCache,
    Map<String, CandidateVisualCacheEntry>? visualCache,
    String? myAnimeListClientId,
    String? myAnimeListClientSecret,
    String? simklClientId,
    List<UserProfileState>? profiles,
    String? activeProfileId,
    String? defaultProfileId,
    UserProfileState? profile,
  }) {
    final baseProfiles = _normalizeProfiles(profiles ?? this.profiles);
    final nextProfiles = profile == null
        ? baseProfiles
        : _replaceProfile(baseProfiles, profile, this.profile.id);
    final resolvedActive = _resolveProfileId(
      nextProfiles,
      activeProfileId ?? this.activeProfileId,
    );
    return AppState(
      rootPaths: rootPaths ?? this.rootPaths,
      remoteLibrary: remoteLibrary ?? this.remoteLibrary,
      showSeriesUpcomingCards:
          showSeriesUpcomingCards ?? this.showSeriesUpcomingCards,
      showPlaylistUpcomingCards:
          showPlaylistUpcomingCards ?? this.showPlaylistUpcomingCards,
      skipMixedEpisodes: skipMixedEpisodes ?? this.skipMixedEpisodes,
      skipFillerEpisodes: skipFillerEpisodes ?? this.skipFillerEpisodes,
      skipOpeningSegments: skipOpeningSegments ?? this.skipOpeningSegments,
      skipEndingSegments: skipEndingSegments ?? this.skipEndingSegments,
      skipMixedOpeningSegments:
          skipMixedOpeningSegments ?? this.skipMixedOpeningSegments,
      skipMixedEndingSegments:
          skipMixedEndingSegments ?? this.skipMixedEndingSegments,
      skipRecapSegments: skipRecapSegments ?? this.skipRecapSegments,
      overscanHorizontal: overscanHorizontal ?? this.overscanHorizontal,
      overscanTop: overscanTop ?? this.overscanTop,
      overscanBottom: overscanBottom ?? this.overscanBottom,
      androidVideoViewMode: androidVideoViewMode ?? this.androidVideoViewMode,
      fillerCache: fillerCache ?? this.fillerCache,
      visualCache: visualCache ?? this.visualCache,
      myAnimeListClientId: myAnimeListClientId ?? this.myAnimeListClientId,
      myAnimeListClientSecret:
          myAnimeListClientSecret ?? this.myAnimeListClientSecret,
      simklClientId: simklClientId ?? this.simklClientId,
      profiles: nextProfiles,
      activeProfileId: resolvedActive,
      defaultProfileId: _resolveProfileId(
        nextProfiles,
        defaultProfileId ?? this.defaultProfileId,
        allowEmpty: true,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'rootPaths': rootPaths,
      'remoteLibrary': remoteLibrary.map((series) => series.toJson()).toList(),
      'showSeriesUpcomingCards': showSeriesUpcomingCards,
      'showPlaylistUpcomingCards': showPlaylistUpcomingCards,
      'skipMixedEpisodes': skipMixedEpisodes,
      'skipFillerEpisodes': skipFillerEpisodes,
      'skipOpeningSegments': skipOpeningSegments,
      'skipEndingSegments': skipEndingSegments,
      'skipMixedOpeningSegments': skipMixedOpeningSegments,
      'skipMixedEndingSegments': skipMixedEndingSegments,
      'skipRecapSegments': skipRecapSegments,
      'overscanHorizontal': overscanHorizontal,
      'overscanTop': overscanTop,
      'overscanBottom': overscanBottom,
      'androidVideoViewMode': androidVideoViewMode.id,
      'fillerCache': fillerCache.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'visualCache': visualCache.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'myAnimeListClientId': myAnimeListClientId,
      'myAnimeListClientSecret': myAnimeListClientSecret,
      'simklClientId': simklClientId,
      'profiles': profiles.map((profile) => profile.toJson()).toList(),
      'activeProfileId': activeProfileId,
      'defaultProfileId': defaultProfileId,
    };
  }

  Set<AnimeSkipSegmentType> get enabledAnimeSkipSegmentTypes {
    return {
      if (skipOpeningSegments) AnimeSkipSegmentType.opening,
      if (skipEndingSegments) AnimeSkipSegmentType.ending,
      if (skipMixedOpeningSegments) AnimeSkipSegmentType.mixedOpening,
      if (skipMixedEndingSegments) AnimeSkipSegmentType.mixedEnding,
      if (skipRecapSegments) AnimeSkipSegmentType.recap,
    };
  }

  Set<AnimeSkipSegmentType> get animeSkipLookupSegmentTypes {
    return {
      AnimeSkipSegmentType.opening,
      AnimeSkipSegmentType.ending,
      if (skipMixedOpeningSegments) AnimeSkipSegmentType.mixedOpening,
      if (skipMixedEndingSegments) AnimeSkipSegmentType.mixedEnding,
      if (skipRecapSegments) AnimeSkipSegmentType.recap,
    };
  }
}

List<UserProfileState> _normalizeProfiles(List<UserProfileState> profiles) {
  if (profiles.isEmpty) {
    return const [UserProfileState()];
  }
  final seen = <String>{};
  final normalized = <UserProfileState>[];
  for (var index = 0; index < profiles.length; index += 1) {
    final profile = profiles[index];
    final fallbackId = 'perfil_${index + 1}';
    final id = profile.id.trim().isEmpty ? fallbackId : profile.id.trim();
    if (seen.add(id)) {
      normalized.add(profile.id == id ? profile : profile.copyWith(id: id));
    }
  }
  return normalized.isEmpty ? const [UserProfileState()] : normalized;
}

List<UserProfileState> _replaceProfile(
  List<UserProfileState> profiles,
  UserProfileState profile,
  String activeProfileId,
) {
  final targetId = activeProfileId.trim().isEmpty
      ? profile.id.trim()
      : activeProfileId.trim();
  var replaced = false;
  final next = profiles.map((entry) {
    if (entry.id == targetId || entry.id == profile.id) {
      replaced = true;
      return profile;
    }
    return entry;
  }).toList();
  if (!replaced) {
    next.add(profile);
  }
  return _normalizeProfiles(next);
}

String _resolveProfileId(
  List<UserProfileState> profiles,
  String requested, {
  bool allowEmpty = false,
}) {
  final normalized = requested.trim();
  if (normalized.isNotEmpty &&
      profiles.any((entry) => entry.id == normalized)) {
    return normalized;
  }
  if (allowEmpty) {
    return '';
  }
  return profiles.isEmpty ? '' : profiles.first.id;
}

String createPlaylistId() {
  return 'playlist-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
}

String normalizeSeriesKey(String value) {
  return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

String uniqueSeriesName(
    String title, Iterable<String> existingNames, String suffix) {
  final cleanTitle = title.trim().isEmpty ? 'Serie $suffix' : title.trim();
  final existing = existingNames.map(normalizeSeriesKey).toSet();
  if (!existing.contains(normalizeSeriesKey(cleanTitle))) {
    return cleanTitle;
  }
  var candidate = '$cleanTitle ($suffix)';
  var counter = 2;
  while (existing.contains(normalizeSeriesKey(candidate))) {
    candidate = '$cleanTitle ($suffix $counter)';
    counter += 1;
  }
  return candidate;
}

List<dynamic> _readList(Object? value) {
  return value is List ? value : const [];
}

List<String> _readStringList(Object? value) {
  return _readList(value)
      .map((entry) => '$entry'.trim())
      .where((entry) => entry.isNotEmpty)
      .toList();
}

Map<String, String> _readStringMap(Object? value) {
  if (value is! Map) {
    return const {};
  }
  final result = <String, String>{};
  value.forEach((key, rawValue) {
    final normalizedKey = '$key'.trim();
    final normalizedValue = '$rawValue'.trim();
    if (normalizedKey.isNotEmpty && normalizedValue.isNotEmpty) {
      result[normalizedKey] = normalizedValue;
    }
  });
  return result;
}

Map<String, int> _readIntMap(Object? value) {
  if (value is! Map) {
    return const {};
  }
  final result = <String, int>{};
  value.forEach((key, rawValue) {
    final normalizedKey = '$key'.trim();
    final normalizedValue = _readInt(rawValue);
    if (normalizedKey.isNotEmpty && normalizedValue > 0) {
      result[normalizedKey] = normalizedValue;
    }
  });
  return result;
}

Map<String, FillerMetadataRecord> _readFillerCache(Object? value) {
  if (value is! Map) {
    return const {};
  }
  final result = <String, FillerMetadataRecord>{};
  value.forEach((key, rawValue) {
    final normalizedKey = '$key'.trim();
    if (normalizedKey.isEmpty || rawValue is! Map) {
      return;
    }
    result[normalizedKey] =
        FillerMetadataRecord.fromJson(Map<String, dynamic>.from(rawValue));
  });
  return result;
}

Map<String, CandidateVisualCacheEntry> _readCandidateVisualCache(
    Object? value) {
  if (value is! Map) {
    return const {};
  }
  final result = <String, CandidateVisualCacheEntry>{};
  value.forEach((key, rawValue) {
    final normalizedKey = '$key'.trim();
    if (normalizedKey.isEmpty || rawValue is! Map) {
      return;
    }
    final entry = CandidateVisualCacheEntry.fromJson(
      Map<String, dynamic>.from(rawValue),
    );
    if (entry.hasMeaningfulContent) {
      result[normalizedKey] = entry;
    }
  });
  return result;
}

Map<String, EpisodePlaybackRecord> _readEpisodePlaybackMap(Object? value) {
  if (value is! Map) {
    return const {};
  }
  final result = <String, EpisodePlaybackRecord>{};
  value.forEach((key, rawValue) {
    final normalizedKey = '$key'.trim();
    if (normalizedKey.isEmpty || rawValue is! Map) {
      return;
    }
    result[normalizedKey] = EpisodePlaybackRecord.fromJson(
      Map<String, dynamic>.from(rawValue),
    );
  });
  return result;
}

Map<String, SeriesPlaybackPreference> _readSeriesPlaybackPreferenceMap(
    Object? value) {
  if (value is! Map) {
    return const {};
  }
  final result = <String, SeriesPlaybackPreference>{};
  value.forEach((key, rawValue) {
    final normalizedKey = '$key'.trim();
    if (normalizedKey.isEmpty || rawValue is! Map) {
      return;
    }
    final preference = SeriesPlaybackPreference.fromJson(
      Map<String, dynamic>.from(rawValue),
    );
    if (preference.isMeaningful) {
      result[normalizedKey] = preference;
    }
  });
  return result;
}

String _readString(Object? value, {String fallback = ''}) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  return fallback;
}

String _normalizeOptionalAnimeAv1Mode(Object? value) {
  final raw = _readString(value);
  return raw.isEmpty ? '' : animeAv1PlaybackModeFromId(raw).id;
}

String _normalizeOptionalJkAnimeServer(Object? value) {
  final raw = _readString(value);
  return raw.isEmpty ? '' : jkAnimeServerPreferenceFromId(raw).id;
}

String _normalizeOptionalLatAnimeServer(Object? value) {
  final raw = _readString(value);
  return raw.isEmpty ? '' : latAnimeServerPreferenceFromId(raw).id;
}

String _normalizeOptionalFacebookMode(Object? value) {
  final raw = _readString(value);
  return raw.isEmpty ? '' : facebookPlaybackModeFromId(raw).id;
}

String _normalizeOptionalFacebookOption(Object? value) {
  final raw = _readString(value);
  return raw.isEmpty ? '' : facebookPlaybackOptionFromId(raw).id;
}

String _normalizeOptionalYoutubeMode(Object? value) {
  final raw = _readString(value);
  return raw.isEmpty ? '' : youtubePlaybackModeFromId(raw).id;
}

String _normalizeOptionalYoutubeOption(Object? value) {
  final raw = _readString(value);
  return raw.isEmpty ? '' : youtubePlaybackOptionFromId(raw).id;
}

int _readInt(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.truncate();
  }
  return int.tryParse('$value') ?? fallback;
}

double _readDouble(Object? value, {double fallback = 0}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse('$value') ?? fallback;
}

bool _readBool(Object? value, {bool fallback = false}) {
  return value is bool ? value : fallback;
}
