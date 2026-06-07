import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:seno/main.dart';

void main() {
  testWidgets('Seno dashboard renders MVP shell', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    await store.load();

    await tester.pumpWidget(SenoApp(store: store));

    expect(find.text('Seno'), findsOneWidget);
    expect(find.text('Today workflow'), findsOneWidget);
    expect(find.text('Create order'), findsOneWidget);
  });
}
