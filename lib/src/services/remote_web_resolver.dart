import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models.dart';

class RemoteWebResolver {
  const RemoteWebResolver({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const _channelName = 'tanuki/remote_web_resolver';

  final MethodChannel _channel;

  void _debugResolver(String message) {
    assert(() {
      debugPrint('RemoteWebResolver: $message');
      return true;
    }());
  }

  String _debugUrlLabel(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return value;
    }
    final path =
        uri.path.length > 52 ? '${uri.path.substring(0, 52)}...' : uri.path;
    return '${uri.scheme}://${uri.host}$path';
  }

  String _debugStreamLabel(RemoteDirectStream? stream) {
    if (stream == null) {
      return 'null';
    }
    return 'provider=${stream.provider?.id ?? 'none'} '
        'kind=${stream.playbackKind} mode=${stream.selectedMode} '
        'server=${stream.server} url=${_debugUrlLabel(stream.playbackUrl)} '
        'page=${_debugUrlLabel(stream.pageUrl)} '
        'subs=${stream.subtitleTracks.length} '
        'headers=${stream.httpHeaders.keys.join(',')}';
  }

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
      _debugResolver(
        'skip available=$isAvailable page=${_debugUrlLabel(targetUrl)}',
      );
      return null;
    }

    try {
      _debugResolver(
        'invoke provider=${entry.provider?.id ?? 'none'} '
        'page=${_debugUrlLabel(targetUrl)} '
        'referer=${_debugUrlLabel(referer.trim())} '
        'preferredServer=${preferredServer.trim()} '
        'excludedServers=${excludedServers.join(',')} '
        'timeout=${timeout.inMilliseconds}ms',
      );
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
        _debugResolver('native returned null');
        return null;
      }
      _debugResolver('native keys=${raw.keys.join(',')}');

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
          final failed = RemoteDirectStream(
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
          _debugResolver('native failed server ${_debugStreamLabel(failed)}');
          return failed;
        }
        _debugResolver('native empty playback url/kind');
        return null;
      }

      final resolved = RemoteDirectStream(
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
      _debugResolver('native resolved ${_debugStreamLabel(resolved)}');
      return resolved;
    } on MissingPluginException catch (error) {
      debugPrint('RemoteWebResolver: missing plugin: $error');
      return null;
    } on TimeoutException catch (error) {
      debugPrint('RemoteWebResolver: timeout resolving $targetUrl: $error');
      return null;
    } catch (error, stackTrace) {
      debugPrint('RemoteWebResolver: failed resolving $targetUrl: $error');
      debugPrint('$stackTrace');
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
