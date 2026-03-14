import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alnitak_flutter/main.dart';

void main() {
  testWidgets('App 启动并显示主框架', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
