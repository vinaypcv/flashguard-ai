import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/isolate_worker.dart';
import '../core/storage_provider.dart';

class FlashGuardDashboard extends StatefulWidget {
  const FlashGuardDashboard({super.key});

  @override
  State<FlashGuardDashboard> createState() => _FlashGuardDashboardState();
}

class _FlashGuardDashboardState extends State<FlashGuardDashboard> {
  final TextEditingController _sourceController = TextEditingController(
    text:
        '${Directory.systemTemp.path}/flashguard_virtual_drives/sandisk_extreme_ssd',
  );

  bool _isScanning = false;
  BatchOffloadSummary? _summary;
  String? _errorMessage;
  BatchOffloadJob? _activeJob;
  BatchProgressEvent? _currentProgress;
  StreamSubscription<BatchProgressEvent>? _progressSubscription;
  bool _isPaused = false;
  bool _isCancelling = false;

  Future<void> _executeVerifiedOffload() async {
    setState(() {
      _isScanning = true;
      _errorMessage = null;
      _currentProgress = null;
      _isPaused = false;
      _isCancelling = false;
    });

    try {
      final destPath = '${Directory.systemTemp.path}/flashguard_verified_vault';
      // The native bridge is intentionally not selected until mobile document
      // streams are implemented. Directory access remains a demo capability.
      final volume = await const SimulatedVolumeProvider()
          .getVolumeStats(_sourceController.text.trim());
      final job = await IsolateOffloadWorker.startVerifiedBatch(
        sourceDirPath: _sourceController.text.trim(),
        destDirPath: destPath,
        freeSpaceRatio: volume.freeSpaceRatio,
      );
      _activeJob = job;
      _progressSubscription = job.progress.listen((event) {
        if (!mounted) return;
        setState(() {
          _currentProgress = event;
          if (event.state == BatchProgressState.paused) _isPaused = true;
          if (event.state == BatchProgressState.resumed) _isPaused = false;
        });
      });
      final result = await job.done;
      if (!mounted) return;
      setState(() {
        _summary = result;
        _isScanning = false;
        _isPaused = false;
        _activeJob = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Storage I/O Fault: $e';
        _isScanning = false;
        _activeJob = null;
      });
    }
  }

  void _togglePause() {
    final job = _activeJob;
    if (job == null) return;
    if (_isPaused) {
      job.resume();
      setState(() => _isPaused = false);
    } else {
      job.pause();
      setState(() => _isPaused = true);
    }
  }

  void _cancelBatch() {
    _activeJob?.cancel();
    setState(() => _isCancelling = true);
  }

  @override
  void dispose() {
    _activeJob?.cancel();
    _progressSubscription?.cancel();
    _sourceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final health = _summary?.healthReport;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FlashGuard • Verified Storage Companion'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Drive Mount Selector Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connected External Volume',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _sourceController,
                    enabled: !_isScanning,
                    decoration: const InputDecoration(
                      labelText: 'Drive / SD Card Mount Path',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.sd_storage_outlined),
                    ),
                  ),
                  if (_isScanning) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isCancelling ? null : _togglePause,
                            icon: Icon(
                                _isPaused ? Icons.play_arrow : Icons.pause),
                            label: Text(_isPaused ? 'Resume' : 'Pause'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isCancelling ? null : _cancelBatch,
                            icon: const Icon(Icons.cancel_outlined),
                            label:
                                Text(_isCancelling ? 'Canceling…' : 'Cancel'),
                          ),
                        ),
                      ],
                    ),
                    if (_currentProgress != null) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: _currentProgress!.fraction.clamp(0, 1),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_isPaused ? 'Paused · ' : ''}'
                        'File ${_currentProgress!.fileIndex} of ${_currentProgress!.totalFiles}: '
                        '${_currentProgress!.relativePath} · '
                        '${_currentProgress!.bytesCopied} / ${_currentProgress!.totalBytes} bytes',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isScanning ? null : _executeVerifiedOffload,
                      icon: _isScanning
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_user_outlined),
                      label: Text(
                        _isScanning
                            ? 'Verifying Blocks & Container Headers...'
                            : 'Run Verified Offload & Health Audit',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],

          if (health != null && _summary != null) ...[
            const SizedBox(height: 20),
            // Drive Confidence Score Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: health.confidenceScore >= 85
                          ? Colors.green.shade700
                          : Colors.orange.shade700,
                      child: Text(
                        '${health.confidenceScore}',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Demo Confidence Score',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            health.diagnosticSummary,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Avg: ${health.averageMbps.toStringAsFixed(1)} MB/s • '
                            'Duplicates Found: ${_summary!.duplicateGroups.length} group(s)',
                            style: theme.textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),
            Text(
              'Per-File Cryptographic & Container Audit',
              style: theme.textTheme.titleMedium,
            ),
            Text(
              'Near-duplicate candidates: ${_summary!.mediaTags.where((tag) => tag.similarToFile != null).length}',
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 8),

            if (_summary!.cancelled)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.pause_circle_outline),
                  title: Text('Batch canceled safely'),
                  subtitle: Text(
                      'Completed files are retained; the active file can resume from its checkpoint.'),
                ),
              ),

            ..._summary!.failures.map((failure) => Card(
                  color: theme.colorScheme.errorContainer,
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(Icons.error_outline,
                        color: theme.colorScheme.onErrorContainer),
                    title: Text(failure.relativePath),
                    subtitle: Text(
                        'Transfer failed; other files continued. ${failure.message}'),
                  ),
                )),

            ..._summary!.results.map((file) {
              final mediaIsValid = file.isMediaStructurallyValid;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    mediaIsValid
                        ? Icons.check_circle
                        : Icons.warning_amber_rounded,
                    color: mediaIsValid ? Colors.green : Colors.orange,
                  ),
                  title: Text(file.relativePath),
                  subtitle: Text(
                    'Byte copy: ${file.byteForByteVerified ? 'VERIFIED' : 'UNVERIFIED'}\n'
                    'Media structure: ${file.mediaIntegrityLabel}\n'
                    'SHA-256: ${file.sha256Hash.substring(0, 16)}… • ${file.byteSize} B'
                    '${file.destinationFileName == file.fileName ? '' : '\nSaved as ${file.destinationFileName}'}'
                    '${file.resumeMessage == null ? '' : '\n${file.resumeMessage}'}',
                  ),
                  trailing: Chip(
                    label: Text(
                      file.byteForByteVerified
                          ? 'BYTES VERIFIED'
                          : 'COPY UNVERIFIED',
                    ),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
