import 'dart:async';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ImageDiskCache {
  ImageDiskCache._();

  static final ImageDiskCache instance = ImageDiskCache._();

  final Map<String, Future<io.File?>> _pending = {};

  Future<io.File?> getFile(
    String url, {
    Duration ttl = const Duration(days: 14),
  }) {
    final normalized = url.trim();
    if (!normalized.startsWith('http://') &&
        !normalized.startsWith('https://')) {
      return Future.value(null);
    }
    return _pending.putIfAbsent(normalized, () async {
      try {
        return await _getFile(normalized, ttl: ttl);
      } finally {
        _pending.remove(normalized);
      }
    });
  }

  Future<io.File?> _getFile(String url, {required Duration ttl}) async {
    final directory = await getApplicationSupportDirectory();
    final cacheDirectory = io.Directory('${directory.path}/image_cache');
    if (!await cacheDirectory.exists()) {
      await cacheDirectory.create(recursive: true);
    }
    final file = io.File('${cacheDirectory.path}/${_cacheFileName(url)}');
    if (await file.exists()) {
      final modified = await file.lastModified();
      if (DateTime.now().difference(modified) <= ttl) {
        return file;
      }
    }

    final response = await http.get(
      Uri.parse(url),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/146 Safari/537.36',
      },
    ).timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return await file.exists() ? file : null;
    }
    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.startsWith('image/') || response.bodyBytes.isEmpty) {
      return await file.exists() ? file : null;
    }
    await file.writeAsBytes(response.bodyBytes, flush: false);
    return file;
  }

  String _cacheFileName(String url) {
    final hash = _fnv1a64(url);
    final extension = _extensionFromUrl(url);
    return '$hash$extension';
  }

  String _extensionFromUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.png')) return '.png';
    if (path.endsWith('.webp')) return '.webp';
    if (path.endsWith('.gif')) return '.gif';
    return '.jpg';
  }

  String _fnv1a64(String value) {
    var hash = 0xcbf29ce484222325;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
