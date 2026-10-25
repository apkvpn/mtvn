import 'package:flutter_test/flutter_test.dart';
import 'package:manoto_vpn/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const ManotoVpnApp());
    expect(find.byType(ManotoVpnApp), findsOneWidget);
  });
}
