enum TransferState {
  pending,
  hashingSource,
  copying,
  checkpointed,
  verifying,
  promoting,
  committed,
  paused,
  cancelled,
  failed
}

class TransferTransition {
  final TransferState from;
  final TransferState to;
  const TransferTransition(this.from, this.to);
  @override
  String toString() => '${from.name} -> ${to.name}';
}

/// In-memory lifecycle. Checkpoint metadata has a separate disk protocol.
class TransferStateMachine {
  static const Map<TransferState, Set<TransferState>> allowed = {
    TransferState.pending: {
      TransferState.hashingSource,
      TransferState.cancelled,
      TransferState.failed
    },
    TransferState.hashingSource: {
      TransferState.copying,
      TransferState.verifying,
      TransferState.cancelled,
      TransferState.failed
    },
    TransferState.copying: {
      TransferState.checkpointed,
      TransferState.verifying,
      TransferState.paused,
      TransferState.cancelled,
      TransferState.failed
    },
    TransferState.checkpointed: {
      TransferState.copying,
      TransferState.verifying,
      TransferState.paused,
      TransferState.cancelled,
      TransferState.failed
    },
    TransferState.verifying: {
      TransferState.promoting,
      TransferState.committed,
      TransferState.failed
    },
    TransferState.promoting: {TransferState.committed, TransferState.failed},
    TransferState.paused: {
      TransferState.copying,
      TransferState.cancelled,
      TransferState.failed
    },
    TransferState.committed: {},
    TransferState.cancelled: {},
    TransferState.failed: {},
  };
  TransferState state = TransferState.pending;
  final List<TransferTransition> history = [];
  void transition(TransferState next) {
    if (!allowed[state]!.contains(next)) {
      throw StateError(
          'Invalid transfer transition: ${state.name} -> ${next.name}');
    }
    history.add(TransferTransition(state, next));
    state = next;
  }
}

class TransferCancelledException implements Exception {
  const TransferCancelledException();
}
