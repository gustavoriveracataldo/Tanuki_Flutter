import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models.dart';

class RemoteWebResolver {
  const RemoteWebResolver({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const _channelName = 'tanuki/remote_web_resolver';

  final MethodChannel _channel;

  bool get isAvailable {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  Future<RemoteDirectStream?> resolveDirectStream({
    required EpisodeItem entry,
    required String pageUrl,
    String referer = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final targetUrl = pageUrl.trim();
    if (!isAvailable || targetUrl.isEmpty) {
      return null;
    }

    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'resolveRemoteStream',
        {
          'provider': entry.provider?.id ?? '',
          'pageUrl': targetUrl,
          'referer': referer.trim(),
          'preferredServer': preferredServer.trim(),
          'excludedServers': excludedServers.toList(growable: false),
          'timeoutMs': timeout.inMilliseconds,
        },
      ).timeout(timeout + const Duration(seconds: 3));
      if (raw == null) {
        return null;
      }

      final playbackUrl = _readString(raw['playbackUrl']);
      final playbackKind = _readString(raw['playbackKind']);
      final selectedMode = _readString(raw['selectedMode']);
      final page = _readString(raw['pageUrl']).isNotEmpty
          ? _readString(raw['pageUrl'])
          : targetUrl;
      if (playbackUrl.isEmpty || playbackKind.isEmpty) {
        final failedServer = _readString(raw['failedServer']).isNotEmpty
            ? _readString(raw['failedServer'])
            : _readString(raw['server']);
        if (failedServer.isNotEmpty) {
          return RemoteDirectStream(
            playbackUrl: '',
            playbackKind: '',
            pageUrl: page,
            availableModes: {
              selectedMode.isEmpty ? 'android-webview-timeout' : selectedMode
            },
            selectedMode:
                selectedMode.isEmpty ? 'android-webview-timeout' : selectedMode,
            provider: entry.provider,
            server: failedServer,
          );
        }
        return null;
      }

      return RemoteDirectStream(
        playbackUrl: playbackUrl,
        playbackKind: playbackKind,
        pageUrl: page,
        availableModes: {
          selectedMode.isEmpty ? 'android-webview' : selectedMode
        },
        selectedMode: selectedMode.isEmpty ? 'android-webview' : selectedMode,
        provider: entry.provider,
        server: _readString(raw['server']),
        subtitleTracks: _readSubtitleTracks(raw['subtitleTracks']),
        httpHeaders: _readStringMap(raw['httpHeaders']),
      );
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _readString(Object? value) =>
      '$value'.trim() == 'null' ? '' : '$value'.trim();

  static Map<String, String> _readStringMap(Object? value) {
    if (value is! Map) {
      return const {};
    }
    final result = <String, String>{};
    value.forEach((key, entry) {
      final name = _readString(key);
      final headerValue = _readString(entry);
      if (name.isNotEmpty && headerValue.isNotEmpty) {
        result[name] = headerValue;
      }
    });
    return result;
  }

  static List<RemoteSubtitleTrack> _readSubtitleTracks(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value
        .whereType<Map>()
        .map((entry) {
          final url = _readString(entry['url']);
          if (url.isEmpty) {
            return null;
          }
          return RemoteSubtitleTrack(
            url: url,
            label: _readString(entry['label']),
            language: _readString(entry['language']),
            mimeType: _readString(entry['mimeType']),
            isDefault: entry['isDefault'] == true,
          );
        })
        .whereType<RemoteSubtitleTrack>()
        .toList(growable: false);
  }
}
