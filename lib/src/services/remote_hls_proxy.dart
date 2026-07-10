import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

class RemoteHlsProxy {
  HttpServer? _server;
  HttpClient? _client;
  Uri? _playlistUri;
  Map<String, String> _headers = const {};

  Future<String> start(
    String playlistUrl, {
    Map<String, String>? headers,
  }) async {
    await dispose();
    _playlistUri = Uri.parse(playlistUrl);
    _headers = Map<String, String>.from(headers ?? const {});
    _client = HttpClient();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(_serve(server));
    return 'http://127.0.0.1:${server.port}/playlist.m3u8';
  }

  Future<void> dispose() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
    _client?.close(force: true);
    _client = null;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path == '/playlist.m3u8') {
        await _servePlaylist(request.response);
        return;
      }
      final encoded = request.uri.queryParameters['url'] ?? '';
      final upstream = Uri.tryParse(encoded);
      if (upstream == null || !upstream.hasScheme) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      await _serveMedia(request, upstream);
    } catch (error) {
      debugPrint('RemoteHlsProxy: request failed ${request.uri} error=$error');
      request.response.statusCode = HttpStatus.badGateway;
      request.response.write(error);
      await request.response.close();
    }
  }

  Future<void> _servePlaylist(HttpResponse response) async {
    final playlistUri = _playlistUri;
    final client = _client;
    if (playlistUri == null || client == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    final upstreamRequest = await client.getUrl(playlistUri);
    _applyHeaders(upstreamRequest.headers);
    final upstreamResponse = await upstreamRequest.close();
    debugPrint(
      'RemoteHlsProxy: playlist upstream=${upstreamResponse.statusCode} '
      'url=$playlistUri',
    );
    if (upstreamResponse.statusCode < 200 ||
        upstreamResponse.statusCode >= 300) {
      response.statusCode = upstreamResponse.statusCode;
      await upstreamResponse.drain<void>();
      await response.close();
      return;
    }
    final source = await utf8.decoder.bind(upstreamResponse).join();
    final rewritten = rewriteHlsPlaylist(
      source,
      playlistUri: playlistUri,
      localOrigin: 'http://127.0.0.1:${_server!.port}',
    );
    response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
      charset: 'utf-8',
    );
    response.write(rewritten);
    await response.close();
  }

  Future<void> _serveMedia(HttpRequest request, Uri upstream) async {
    final client = _client;
    if (client == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final upstreamRequest = await client.getUrl(upstream);
    _applyHeaders(upstreamRequest.headers);
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.isNotEmpty) {
      upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
    }
    final upstreamResponse = await upstreamRequest.close();
    request.response.statusCode = upstreamResponse.statusCode;
    request.response.headers.contentType = request.uri.path.endsWith('.mp4')
        ? ContentType('video', 'mp4')
        : ContentType('video', 'iso.segment');
    final contentRange =
        upstreamResponse.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, contentRange);
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in upstreamResponse) {
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  void _applyHeaders(HttpHeaders target) {
    for (final entry in _headers.entries) {
      target.set(entry.key, entry.value);
    }
  }
}

String rewriteHlsPlaylist(
  String source, {
  required Uri playlistUri,
  required String localOrigin,
}) {
  String localUrl(String value, {required bool initialization}) {
    final upstream = playlistUri.resolve(value);
    final extension = initialization ? 'mp4' : 'm4s';
    return '$localOrigin/media.$extension?url='
        '${Uri.encodeQueryComponent(upstream.toString())}';
  }

  final mapPattern = RegExp(r'URI="([^"]+)"');
  return source.split('\n').map((line) {
    if (line.startsWith('#EXT-X-MAP:')) {
      return line.replaceAllMapped(
        mapPattern,
        (match) => 'URI="${localUrl(match.group(1)!, initialization: true)}"',
      );
    }
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      return line;
    }
    return localUrl(trimmed, initialization: false);
  }).join('\n');
}

bool shouldProxyZillaHls(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.host.toLowerCase() == 'player.zilla-networks.com' &&
      uri.path.startsWith('/m3u8/');
}
