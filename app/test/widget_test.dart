import 'package:flutter_test/flutter_test.dart';
import 'package:flashguard_ai/main.dart';

void main() {
  testWidgets('dashboard exposes the local audit action', (tester) async {
    await tester.pumpWidget(const FlashGuardApp());
    expect(find.text('Run Verified Offload & Health Audit'), findsOneWidget);
  });
}
