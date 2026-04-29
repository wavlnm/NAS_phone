import 'package:flutter_test/flutter_test.dart';

import 'package:nas_phone/main.dart';

void main() {
  testWidgets('renders NAS host probe shell', (tester) async {
    await tester.pumpWidget(const NasPhoneApp());

    expect(find.text('NAS Phone'), findsOneWidget);
    expect(find.text('连接你的 loal_NAS 宿主'), findsOneWidget);
    expect(find.text('宿主地址'), findsOneWidget);
    expect(find.text('探测宿主'), findsOneWidget);
    expect(find.text('尚未探测'), findsOneWidget);
  });
}
