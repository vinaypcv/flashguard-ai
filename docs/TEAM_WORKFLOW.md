# Sandisk Flutter Team AI Workflow Playbook

## 1. Spec-First, Agent-Second
Never prompt Claude Code or Cursor directly from a vague Jira ticket. Write a 20-line `SPEC.md` defining **data invariants** (e.g., atomic `.part` writes, background `Isolate` boundaries) first.

## 2. Deterministic Fault-Injection Loop
Before asking for PR review, run `/verify-storage-pr`. The `flashguard-chaos` fixture tests create a virtual drive with a truncated MP4 and exact JPEG duplicates. The Flutter tests independently verify the matching Dart behavior.

## 3. Code Review Checklist for AI-Generated Dart
- [ ] Are all `File` / `RandomAccessFile` calls inside `Isolate.run` or async streams?
- [ ] Are `TextEditingController` and `StreamSubscription` instances disposed properly?
- [ ] Are binary file checks inspecting magic bytes rather than string extensions?
