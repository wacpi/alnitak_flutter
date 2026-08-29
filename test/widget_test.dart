import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alnitak_flutter/main.dart';
import 'package:alnitak_flutter/utils/http_client.dart';

/// 测试用假网络适配器：所有请求立即返回 404。
///
/// HomePage.initState 会并发发起 4 个真实 API 请求（视频/分区/PGC 推荐），
/// 测试环境无网络会导致 Dio 超时 Timer 挂起，测试结束时触发
/// "A Timer is still pending" 失败。404 不会被 RetryInterceptor（仅 5xx/超时）
/// 或 DomainFallbackInterceptor（仅连接错误）拦截，页面 catch 分支正常兜底。
class _FakeResponseAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"code": 40400, "msg": "mock not found"}',
      404,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('App 启动并显示主框架', (WidgetTester tester) async {
    // 替换全局 Dio 适配器，屏蔽 HomePage 的启动网络请求
    HttpClient().dio.httpClientAdapter = _FakeResponseAdapter();

    await tester.pumpWidget(const MyApp());
    // 空转若干帧让 HomePage 的 4 个请求全部完成（fake 响应即时返回）
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}