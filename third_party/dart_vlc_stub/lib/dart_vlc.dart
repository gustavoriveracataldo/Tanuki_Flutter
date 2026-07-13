import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

class DartVLC {
  static void initialize() {}
}

class Player {
  Player({
    required this.id,
    List<String> commandlineArguments = const [],
  });

  final int id;
  final _positionController = StreamController<PositionState>.broadcast();
  final _playbackController = StreamController<PlaybackState>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _videoDimensionsController =
      StreamController<VideoDimensions>.broadcast();

  PositionState position = const PositionState();
  PlaybackState playback = const PlaybackState();

  Stream<PositionState> get positionStream => _positionController.stream;
  Stream<PlaybackState> get playbackStream => _playbackController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<VideoDimensions> get videoDimensionsStream =>
      _videoDimensionsController.stream;

  void setUserAgent(String userAgent) {}

  void open(Media media, {bool autoStart = true}) {
    playback = PlaybackState(isPlaying: autoStart);
    _playbackController.add(playback);
  }

  void play() {
    playback = const PlaybackState(isPlaying: true);
    _playbackController.add(playback);
  }

  void playOrPause() {
    playback = PlaybackState(isPlaying: !playback.isPlaying);
    _playbackController.add(playback);
  }

  void seek(Duration position) {
    this.position = PositionState(
      position: position,
      duration: this.position.duration,
    );
    _positionController.add(this.position);
  }

  void stop() {
    playback = const PlaybackState();
    _playbackController.add(playback);
  }

  void dispose() {
    _positionController.close();
    _playbackController.close();
    _errorController.close();
    _videoDimensionsController.close();
  }
}

class Media {
  Media.network(this.resource, {this.startTime}) : file = null;

  Media.file(File file, {this.startTime})
      : resource = file.path,
        file = file;

  final String resource;
  final File? file;
  final Duration? startTime;
}

class PositionState {
  const PositionState({
    this.position,
    this.duration,
  });

  final Duration? position;
  final Duration? duration;
}

class PlaybackState {
  const PlaybackState({
    this.isPlaying = false,
    this.isCompleted = false,
  });

  final bool isPlaying;
  final bool isCompleted;
}

class VideoDimensions {
  const VideoDimensions({
    this.width = 0,
    this.height = 0,
  });

  final int width;
  final int height;
}

class Video extends StatelessWidget {
  const Video({
    super.key,
    required this.player,
    this.fit,
    this.showControls = true,
  });

  final Player player;
  final BoxFit? fit;
  final bool showControls;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
