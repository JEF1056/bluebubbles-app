import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:universal_io/io.dart';

enum PlayerState { initialized, playing, paused, stopped }

enum FinishMode { loop, pause, stop }

class PlayerController extends ChangeNotifier {
  final StreamController<PlayerState> _stateController = StreamController<PlayerState>.broadcast();
  final StreamController<void> _completionController = StreamController<void>.broadcast();
  final StreamController<int> _durationController = StreamController<int>.broadcast();

  PlayerState playerState = PlayerState.stopped;
  int maxDuration = 0;

  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;
  Stream<void> get onCompletion => _completionController.stream;
  Stream<int> get onCurrentDurationChanged => _durationController.stream;

  Future<void> preparePlayer({
    required String path,
    double? volume,
    bool shouldExtractWaveform = true,
    int noOfSamples = 100,
  }) async {}

  void setFinishMode({FinishMode finishMode = FinishMode.stop}) {}

  Future<void> startPlayer() async {}

  Future<void> pausePlayer() async {}

  Future<void> stopPlayer() async {}

  @override
  void dispose() {
    _stateController.close();
    _completionController.close();
    _durationController.close();
    super.dispose();
  }
}

class RecorderSettings {
  final int? sampleRate;
  final int? bitRate;
  const RecorderSettings({this.sampleRate, this.bitRate});
}

class RecorderController extends ChangeNotifier {
  bool isRecording = false;
  final StreamController<Duration> _currentDurationController = StreamController<Duration>.broadcast();

  Stream<Duration> get onCurrentDuration => _currentDurationController.stream;

  Future<void> record({String? path, RecorderSettings? recorderSettings}) async {}

  Future<String?> stop([bool callReset = true]) async => null;

  @override
  void dispose() {
    _currentDurationController.close();
    super.dispose();
  }
}

class PlayerWaveStyle {
  final Color fixedWaveColor;
  final Color liveWaveColor;
  final StrokeCap waveCap;
  final double waveThickness;
  final double seekLineThickness;
  final bool showSeekLine;
  const PlayerWaveStyle({
    this.fixedWaveColor = Colors.grey,
    this.liveWaveColor = Colors.white,
    this.waveCap = StrokeCap.round,
    this.waveThickness = 3.0,
    this.seekLineThickness = 2.0,
    this.showSeekLine = true,
  });
}

class WaveStyle {
  final Color waveColor;
  final StrokeCap waveCap;
  final double spacing;
  final bool showBottom;
  final bool extendWaveform;
  final bool showMiddleLine;
  const WaveStyle({
    this.waveColor = Colors.white,
    this.waveCap = StrokeCap.round,
    this.spacing = 4.0,
    this.showBottom = true,
    this.extendWaveform = false,
    this.showMiddleLine = true,
  });
}

class AudioFileWaveforms extends StatelessWidget {
  final Size size;
  final PlayerController playerController;
  final EdgeInsets padding;
  final PlayerWaveStyle playerWaveStyle;
  const AudioFileWaveforms({
    super.key,
    required this.size,
    required this.playerController,
    this.padding = EdgeInsets.zero,
    this.playerWaveStyle = const PlayerWaveStyle(),
  });
  @override
  Widget build(BuildContext context) => SizedBox.fromSize(size: size);
}

class AudioWaveforms extends StatelessWidget {
  final Size size;
  final RecorderController recorderController;
  final EdgeInsets padding;
  final WaveStyle waveStyle;
  final BoxDecoration? decoration;
  const AudioWaveforms({
    super.key,
    required this.size,
    required this.recorderController,
    this.padding = EdgeInsets.zero,
    this.waveStyle = const WaveStyle(),
    this.decoration,
  });
  @override
  Widget build(BuildContext context) => SizedBox.fromSize(size: size);
}

class ReturnCode {
  static bool isSuccess(dynamic returnCode) => false;
}

class FFmpegSession {
  Future<ReturnCode?> getReturnCode() async => null;
  Future<String?> getAllLogsAsString([int? waitTimeout]) async => null;
}

class FFmpegKit {
  static Future<FFmpegSession> execute(String command) async => FFmpegSession();
}

class SaverGallery {
  static Future<dynamic> saveImage(
    Uint8List imageBytes, {
    int quality = 80,
    required String fileName,
    String? albumPath,
    required bool skipIfExists,
  }) async =>
      null;

  static Future<dynamic> saveFile({
    required String filePath,
    required String fileName,
    String? albumPath,
    required bool skipIfExists,
  }) async =>
      null;
}

enum PermissionState { notDetermined, restricted, denied, authorized, limited }

extension PermissionStateExt on PermissionState {
  bool get hasAccess => this == PermissionState.authorized || this == PermissionState.limited;
}

enum AssetType { other, image, video, audio }

enum OrderOptionType { createDate, updateDate }

class OrderOption {
  final OrderOptionType type;
  final bool asc;
  const OrderOption({this.type = OrderOptionType.createDate, this.asc = false});
}

class FilterOptionGroup {
  final List<OrderOption> orders;
  const FilterOptionGroup({this.orders = const []});
}

class AssetEntity {
  String get id => '';
  AssetType get type => AssetType.other;
  String? get mimeType => null;
  DateTime get modifiedDateTime => DateTime.fromMillisecondsSinceEpoch(0);
  Future<File?> get file async => null;
}

class AssetPathEntity {
  Future<List<AssetEntity>> getAssetListRange({required int start, required int end}) async => [];
}

class PhotoManager {
  static Future<PermissionState> requestPermissionExtend() async => PermissionState.denied;
  static Future<List<AssetPathEntity>> getAssetPathList({
    bool onlyAll = false,
    FilterOptionGroup? filterOption,
  }) async =>
      [];
  static Future<void> presentLimited() async {}
}
