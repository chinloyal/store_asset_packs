import 'package:flutter/foundation.dart';

/// Where a pack is in its delivery, with the same values on every platform.
///
/// Android maps Play Asset Delivery's `AssetPackStatus` one to one. iOS maps
/// On-Demand Resources and Background Assets onto the subset that applies to
/// them: [waitingForWifi], [requiresUserConfirmation] and [transferring] are
/// Android-only in practice.
enum AssetPackStatus {
  /// The pack is not on the device and no download has been requested.
  notInstalled,

  /// A download was requested and has not started yet.
  pending,

  /// The pack is downloading.
  downloading,

  /// The download finished and the files are being moved into place.
  transferring,

  /// The download is paused until the device is on Wi-Fi. Call
  /// [StoreAssetPacks.showCellularDataConfirmation] to ask the player to
  /// allow mobile data.
  waitingForWifi,

  /// Play needs the player's OK before downloading (for example because the
  /// app was not installed from Play, or the download is large). Call
  /// [StoreAssetPacks.showCellularDataConfirmation].
  requiresUserConfirmation,

  /// The pack is on the device; [StoreAssetPacks.getPackPath] returns its
  /// directory.
  completed,

  /// The download failed; see [AssetPackState.errorCode].
  failed,

  /// The download was canceled.
  canceled,

  /// The platform reported a status this plugin does not know.
  unknown,
}

/// The state of one asset pack.
@immutable
class AssetPackState {
  const AssetPackState({
    required this.name,
    required this.status,
    this.bytesDownloaded = 0,
    this.totalBytes = 0,
    this.progress = 0,
    this.errorCode,
    this.errorMessage,
  });

  /// Decodes the map the native side sends over the channel.
  factory AssetPackState.fromMap(Map<Object?, Object?> map) {
    final status = map['status'] as String?;
    return AssetPackState(
      name: map['name']! as String,
      status: AssetPackStatus.values.firstWhere(
        (s) => s.name == status,
        orElse: () => AssetPackStatus.unknown,
      ),
      bytesDownloaded: (map['bytesDownloaded'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      progress: ((map['progress'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
      errorCode: (map['errorCode'] as num?)?.toInt(),
      errorMessage: map['errorMessage'] as String?,
    );
  }

  /// The pack's name: the Play asset pack name, the ODR tag and the
  /// Background Assets asset-pack ID.
  final String name;

  final AssetPackStatus status;

  /// Bytes downloaded so far. 0 when the platform does not report bytes
  /// (iOS On-Demand Resources).
  final int bytesDownloaded;

  /// The pack's download size in bytes, or 0 when it is unknown.
  final int totalBytes;

  /// Download progress from 0 to 1. Always 1 once [status] is
  /// [AssetPackStatus.completed].
  final double progress;

  /// The platform's error code when [status] is [AssetPackStatus.failed],
  /// otherwise null. On Android it is Play's `AssetPackErrorCode` (negative
  /// values, e.g. -6 network error, -10 insufficient storage); on iOS it is
  /// the `NSError` code.
  final int? errorCode;

  /// A human-readable description of the error, when there is one. For logs,
  /// not for players.
  final String? errorMessage;

  /// Whether the pack's files can be read now.
  bool get isAvailable => status == AssetPackStatus.completed;

  Map<String, Object?> toMap() => {
    'name': name,
    'status': status.name,
    'bytesDownloaded': bytesDownloaded,
    'totalBytes': totalBytes,
    'progress': progress,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
  };

  @override
  bool operator ==(Object other) =>
      other is AssetPackState &&
      other.name == name &&
      other.status == status &&
      other.bytesDownloaded == bytesDownloaded &&
      other.totalBytes == totalBytes &&
      other.progress == progress &&
      other.errorCode == errorCode &&
      other.errorMessage == errorMessage;

  @override
  int get hashCode => Object.hash(
    name,
    status,
    bytesDownloaded,
    totalBytes,
    progress,
    errorCode,
    errorMessage,
  );

  @override
  String toString() =>
      'AssetPackState($name, ${status.name}, '
      '$bytesDownloaded/$totalBytes, ${(progress * 100).toStringAsFixed(0)}%'
      '${errorCode == null ? '' : ', error $errorCode'})';
}
