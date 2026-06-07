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

  testWidgets('new order handles duplicate saved office ids', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    store.offices.addAll([
      Office(id: 'duplicate-office', name: 'Office A', phone: ''),
      Office(id: 'duplicate-office', name: 'Office B', phone: ''),
    ]);

    await tester.pumpWidget(SenoApp(store: store));
    await tester.tap(find.text('Create order'));
    await tester.pumpAndSettle();

    expect(find.text('New order'), findsOneWidget);
    expect(find.text('Product 1'), findsOneWidget);
  });
}
