import "package:flutter_test/flutter_test.dart";
import "package:adshield/main.dart";

void main() {
  testWidgets("应用能正常渲染首页", (WidgetTester tester) async {
    await tester.pumpWidget(const AdShieldApp());
    expect(find.byType(AdShieldApp), findsOneWidget);
  });
}
