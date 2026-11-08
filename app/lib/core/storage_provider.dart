import 'dart:io';

import 'package:flutter/services.dart';

class VolumeStats {
  final String volumeLabel;
  final String mountPath;
  final int totalBytes;
  final int freeBytes;
  final bool isHardwareBacked;

  VolumeStats({
    required this.volumeLabel,
    required this.mountPath,
    required this.totalBytes,
    required this.freeBytes,
    required this.isHardwareBacked,
  }) {
    if (totalBytes <= 0 || freeBytes < 0 || freeBytes > totalBytes) {
      throw ArgumentError('Invalid volume capacity');
    }
  }

  double get freeSpaceRatio => freeBytes / totalBytes;
}

abstract class ExternalVolumeProvider {
  Future<VolumeStats> getVolumeStats(String volumeId);
}

/// Deterministic capacity data for directory fixtures and the Windows demo.
class SimulatedVolumeProvider implements ExternalVolumeProvider {
  static const defaultFreeSpaceRatio = 0.68;

  final int simulatedTotalBytes;
  final int simulatedFreeBytes;

  const SimulatedVolumeProvider({
    this.simulatedTotalBytes = 1000000000000,
    this.simulatedFreeBytes = 680000000000,
  });

  @override
  Future<VolumeStats> getVolumeStats(String volumeId) async {
    final segments =
        Directory(volumeId).uri.pathSegments.where((s) => s.isNotEmpty);
    return VolumeStats(
      volumeLabel: segments.isEmpty ? 'Simulated volume' : segments.last,
      mountPath: volumeId,
      totalBytes: simulatedTotalBytes,
      freeBytes: simulatedFreeBytes,
      isHardwareBacked: false,
    );
  }
}

/// Contract for a future native SAF / security-scoped volume implementation.
/// A missing native implementation fails explicitly; it never presents demo data
/// as physical device telemetry.
class PlatformChannelVolumeProvider implements ExternalVolumeProvider {
  static const channelName = 'com.sandisk.flashguard/volume';
  final MethodChannel channel;

  const PlatformChannelVolumeProvider({
    this.channel = const MethodChannel(channelName),
  });

  @override
  Future<VolumeStats> getVolumeStats(String volumeId) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'getVolumeStats',
      {'volumeId': volumeId},
    );
    if (result == null) {
      throw const FormatException('Native volume statistics were not returned');
    }
    final total = result['totalBytes'];
    final free = result['freeBytes'];
    if (total is! num || free is! num) {
      throw const FormatException('Native volume capacity is missing');
    }
    return VolumeStats(
      volumeLabel: result['volumeLabel'] as String? ?? volumeId,
      mountPath: volumeId,
      totalBytes: total.toInt(),
      freeBytes: free.toInt(),
      isHardwareBacked: true,
    );
  }
}
