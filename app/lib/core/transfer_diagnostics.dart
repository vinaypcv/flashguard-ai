/// Optional observations for reproducible reliability experiments. A stage
/// reports a completed API boundary, not physical media persistence.
enum TransferProbeStage {
  blockFlushed,
  checkpointSaved,
  verificationStarted,
  verificationBlockRead,
  bytesVerified,
  promotionStarted,
  promoted,
  finalVerified,
}

class TransferProbe {
  final TransferProbeStage stage;
  final int offset;
  const TransferProbe(this.stage, this.offset);
}

/// Exclusive measured phases. Legacy aggregate fields below are not added to
/// this ledger; adding them would count overlapping intervals twice.
enum TransferPhase {
  setup,
  sourceHash,
  checkpointValidation,
  sourceRead,
  blockWrite,
  dataFlush,
  blockHash,
  checkpointSerialization,
  checkpointPersistence,
  tempVerification,
  sourceConsistency,
  mediaInspection,
  durability,
  promotion,
  finalVerification,
  existingCopyVerification,
  cleanup,
}

class PhaseMeasurement {
  int micros = 0;
  int operations = 0;
  int bytesRead = 0;
  int bytesWritten = 0;
  Map<String, int> toJson() => {
        'micros': micros,
        'operations': operations,
        'bytesRead': bytesRead,
        'bytesWritten': bytesWritten
      };
}

/// Logical write counts exclude filesystem metadata, caches, and device writes.
class TransferDiagnostics {
  final bool enabled;
  TransferDiagnostics({this.enabled = true});
  final Map<TransferPhase, PhaseMeasurement> _phases = {};
  int totalMicros = 0;
  int blockBytes = 0;
  int checkpointCount = 0;
  int resumedBytes = 0;
  int nativeFileSyncCount = 0;
  int directorySyncCount = 0;
  int sourceHashMicros = 0;
  int recoveryValidationMicros = 0;
  int copyCheckpointMicros = 0;
  int verificationMicros = 0;
  int finalVerificationMicros = 0;
  int copyBytesWritten = 0;
  int checkpointMetadataBytesWritten = 0;

  Stopwatch begin() => Stopwatch()..start();
  PhaseMeasurement phase(TransferPhase phase) =>
      _phases.putIfAbsent(phase, PhaseMeasurement.new);
  int finish(TransferPhase name, Stopwatch? timer) {
    if (timer == null) return 0;
    timer.stop();
    final value = phase(name);
    value.micros += timer.elapsedMicroseconds;
    value.operations++;
    return timer.elapsedMicroseconds;
  }

  void read(TransferPhase name, int bytes) => phase(name).bytesRead += bytes;
  void write(TransferPhase name, int bytes) =>
      phase(name).bytesWritten += bytes;
  int get accountedMicros =>
      _phases.values.fold(0, (sum, phase) => sum + phase.micros);

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'totalMicros': totalMicros,
        'blockBytes': blockBytes,
        'checkpointCount': checkpointCount,
        'resumedBytes': resumedBytes,
        'nativeFileSyncCount': nativeFileSyncCount,
        'directorySyncCount': directorySyncCount,
        'phases': {
          for (final entry in _phases.entries)
            entry.key.name: entry.value.toJson()
        },
        'accountedMicros': accountedMicros,
        'unattributedMicros': totalMicros - accountedMicros,
        'sourceHashMicros': sourceHashMicros,
        'recoveryValidationMicros': recoveryValidationMicros,
        'copyCheckpointMicros': copyCheckpointMicros,
        'verificationMicros': verificationMicros,
        'finalVerificationMicros': finalVerificationMicros,
        'copyBytesWritten': copyBytesWritten,
        'checkpointMetadataBytesWritten': checkpointMetadataBytesWritten,
      };
}
