import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import '../config.dart';

/// 自定义 DNS 解析的 HTTP 客户端
class DnsHttpClient {
  /// 创建支持自定义 DNS 的 HTTP 客户端
  static Future<http.Client> create() async {
    // 简化实现：直接使用默认客户端
    // DNS 解析由系统处理，如果需要自定义 DNS 可以使用 dns_over_https 包
    return http.Client();
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
