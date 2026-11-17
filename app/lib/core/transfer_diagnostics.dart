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

/// Logical write counts exclude filesystem metadata, caches, and device writes.
class TransferDiagnostics {
  int sourceHashMicros = 0;
  int recoveryValidationMicros = 0;
  int copyCheckpointMicros = 0;
  int verificationMicros = 0;
  int finalVerificationMicros = 0;
  int copyBytesWritten = 0;
  int checkpointMetadataBytesWritten = 0;

  Map<String, int> toJson() => {
        'sourceHashMicros': sourceHashMicros,
        'recoveryValidationMicros': recoveryValidationMicros,
        'copyCheckpointMicros': copyCheckpointMicros,
        'verificationMicros': verificationMicros,
        'finalVerificationMicros': finalVerificationMicros,
        'copyBytesWritten': copyBytesWritten,
        'checkpointMetadataBytesWritten': checkpointMetadataBytesWritten,
      };
}
