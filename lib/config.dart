/// FamilyMap 全局配置
/// 
/// 所有服务器地址、端口、DNS 等配置统一在此文件管理
/// 修改域名/服务器时只需改这一个文件
class AppConfig {
  // ==================== 服务器配置 ====================
  
  /// 服务器域名（不带协议和端口）
  static const String serverHost = 'www.zhp98.fun';
  
  /// HTTP 端口
  static const int httpPort = 8090;
  
  /// WebSocket 端口（与 HTTP 相同）
  static const int wsPort = 8090;
  
  /// 是否使用 HTTPS
  static const bool useHttps = true;
  
  // ==================== DNS 配置 ====================
  
  /// 自定义 DNS 服务器（阿里云 DNS）
  /// 设为 null 则使用系统默认 DNS
  static const String? customDns = '223.5.5.5';
  
  // ==================== 派生配置（不需要修改） ====================
  
  /// 完整的 HTTP baseUrl
  static String get httpBaseUrl {
    final protocol = useHttps ? 'https' : 'http';
    return '$protocol://$serverHost:$httpPort';
  }
  
  /// WebSocket URL
  static String get wsUrl {
    final protocol = useHttps ? 'wss' : 'ws';
    return '$protocol://$serverHost:$wsPort';
  }
  
  /// 分享链接 baseUrl
  static String get shareBaseUrl {
    final protocol = useHttps ? 'https' : 'http';
    return '$protocol://$serverHost:$httpPort';
  }
}
