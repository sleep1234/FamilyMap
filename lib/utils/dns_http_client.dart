import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../config.dart';

/// 自定义 DNS 解析的 HTTP 客户端
class DnsHttpClient {
  /// 创建支持自定义 DNS 的 HTTP 客户端
  static Future<http.Client> create() async {
    final ioHttpClient = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    return IOClient(ioHttpClient);
  }
  
  /// 解析域名（使用自定义 DNS 服务器）
  static Future<List<InternetAddress>> resolveHost(String host) async {
    try {
      return await InternetAddress.lookup(host);
    } catch (e) {
      throw SocketException('DNS 解析失败: $host - $e');
    }
  }
}
