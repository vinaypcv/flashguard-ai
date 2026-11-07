import 'dart:io';

import 'package:flutter/material.dart';

import '../core/isolate_worker.dart';

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

  Future<void> _executeVerifiedOffload() async {
    setState(() {
      _isScanning = true;
      _errorMessage = null;
    });

    try {
      final destPath = '${Directory.systemTemp.path}/flashguard_verified_vault';
      final result = await IsolateOffloadWorker.runVerifiedBatch(
        sourceDirPath: _sourceController.text.trim(),
        destDirPath: destPath,
      );
      if (!mounted) return;
      setState(() {
        _summary = result;
        _isScanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Storage I/O Fault: $e';
        _isScanning = false;
      });
    }
  }

  @override
  void dispose() {
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
                    decoration: const InputDecoration(
                      labelText: 'Drive / SD Card Mount Path',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.sd_storage_outlined),
                    ),
                  ),
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

            ..._summary!.results.map((file) {
              final isSafe = file.isCopyVerified;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    isSafe ? Icons.check_circle : Icons.warning_amber_rounded,
                    color: isSafe ? Colors.green : Colors.red,
                  ),
                  title: Text(file.fileName),
                  subtitle: Text(
                    'SHA-256: ${file.sha256Hash.substring(0, 16)}… • ${file.byteSize} B',
                  ),
                  trailing: Chip(
                    label: Text(
                      isSafe ? 'COPY VERIFIED' : file.status.name.toUpperCase(),
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
