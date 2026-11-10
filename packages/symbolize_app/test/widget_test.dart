import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:symbolize_app/main.dart';

void main() {
  testWidgets('decodes a pasted trace with an explicit symbols file', (tester) async {
    await tester.pumpWidget(const SymbolizeApp());
    await tester.pumpAndSettle();

    // Switch to the explicit-file source mode.
    await tester.tap(find.text('.symbols file'));
    await tester.pumpAndSettle();

    final symbols = File('../symbolize/test/fixtures/app.macos.symbols').absolute.path;
    final trace = File('../symbolize/test/fixtures/trace.txt').readAsStringSync();

    await tester.enterText(find.byType(TextField).at(0), symbols);
    await tester.enterText(find.byType(TextField).at(1), trace);
    await tester.tap(find.widgetWithText(FilledButton, 'Symbolize'));
    await tester.pumpAndSettle();

    expect(find.textContaining('resolved'), findsWidgets);
    expect(find.textContaining('secondLevel'), findsWidgets);
  });
}
