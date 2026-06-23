import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/api_service.dart';
import 'services/socket_service.dart';
import 'services/image_cache_service.dart';
import 'models/models.dart';
import 'screens/map_screen.dart';

/// 全局 ApiService 单例
final apiService = ApiService();

/// 全局导航 Key（用于认证过期时跳回登录页）
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 认证过期/强制登出时：清除 token 并跳回登录页
/// 使用防重入锁，避免多个并发 401 重复导航
bool _isHandlingExpired = false;
bool _navComplete = false;

Future<void> handleAuthExpired() async {
  if (_isHandlingExpired) return;
  _isHandlingExpired = true;
  _navComplete = false;
  try {
    debugPrint('[AuthExpired] 开始处理认证过期...');
    apiService.clearToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('familymap_user');
    SocketService.instance.disconnect();
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      await Navigator.of(ctx).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => SplashScreen(
          darkMode: false,
          onDarkModeChanged: (_) {},
        )),
        (route) => false,
      );
    }
    _navComplete = true;
    debugPrint('[AuthExpired] 已跳转登录页');
  } finally {
    // 等导航完成后才解锁
    _isHandlingExpired = false;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 初始化图片缓存服务（清理过期缓存）
  ImageCacheService.instance.init();
  runZonedGuarded(() {
    runApp(const FamilyMapApp());
  }, (error, stack) {
    debugPrint('[Zone] uncaught error: $error');
    if (error is AuthExpiredException) {
      // 只在用户已登录时才处理，避免登录流程中的异常误触发
      if (apiService.hasToken) {
        handleAuthExpired();
      }
    }
  });
}

class FamilyMapApp extends StatefulWidget {
  const FamilyMapApp({super.key});

  @override
  State<FamilyMapApp> createState() => _FamilyMapAppState();
}

class _FamilyMapAppState extends State<FamilyMapApp> {
  bool _darkMode = false;

  @override
  void initState() {
    super.initState();
    // 启动时立即从本地缓存恢复深色模式，避免白屏闪烁
    _loadDarkModeFromCache();
  }

  Future<void> _loadDarkModeFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getBool('cache_dark_mode');
    if (cached != null && cached != _darkMode && mounted) {
      setState(() => _darkMode = cached);
    }
  }

  // 全局暗黑模式切换器，子页面可以通过此回调通知主题变化
  void _toggleDarkMode(bool value) {
    setState(() => _darkMode = value);
    // 同步缓存到本地
    SharedPreferences.getInstance().then((p) => p.setBool('cache_dark_mode', value));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FamilyMap',
      debugShowCheckedModeBanner: false,
      theme: _darkMode ? _darkTheme : _lightTheme,
      home: SplashScreen(
        darkMode: _darkMode,
        onDarkModeChanged: _toggleDarkMode,
      ),
      navigatorKey: navigatorKey,
    );
  }

  static final _lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5)),
    useMaterial3: true,
    fontFamily: 'PingFang SC',
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Colors.black87,
      elevation: 0,
    ),
  );

  static final _darkTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F46E5),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
    fontFamily: 'PingFang SC',
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1E293B),
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    scaffoldBackgroundColor: const Color(0xFF0F172A),
    cardColor: const Color(0xFF1E293B),
  );
}

class SplashScreen extends StatefulWidget {
  final Function(bool) onDarkModeChanged;
  final bool darkMode;

  const SplashScreen({super.key, required this.onDarkModeChanged, this.darkMode = false});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLogin();
  }

  Future<void> _checkLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUser = prefs.getString('familymap_user');
    if (savedUser != null) {
      try {
        final json = _parseJson(savedUser);
        final user = AppUser.fromJson(json);
        apiService.setToken(user.token);
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => MapScreen(
              currentUser: user,
              darkMode: widget.darkMode,
              onDarkModeChanged: widget.onDarkModeChanged,
            )),
          );
        }
        return;
      } catch (_) {}
    }
  }

  Map<String, dynamic> _parseJson(String s) {
    return Map<String, dynamic>.from(const JsonDecoder().convert(s));
  }

  @override
  Widget build(BuildContext context) {
    return LoginPage(darkMode: widget.darkMode, onDarkModeChanged: widget.onDarkModeChanged);
  }
}

class LoginPage extends StatefulWidget {
  final bool darkMode;
  final Function(bool) onDarkModeChanged;

  const LoginPage({super.key, this.darkMode = false, required this.onDarkModeChanged});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isLoading = false;
  bool _isLoginMode = true; // true=登录, false=注册

  Future<void> _handleSubmit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty) {
      _showError('请输入用户名');
      return;
    }
    if (password.isEmpty) {
      _showError('请输入密码');
      return;
    }

    setState(() => _isLoading = true);
    try {
      late AppUser user;

      if (_isLoginMode) {
        user = await apiService.loginUser(username, password);
      } else {
        final name = _nameController.text.trim();
        if (name.isEmpty) {
          _showError('请输入昵称');
          setState(() => _isLoading = false);
          return;
        }
        user = await apiService.registerUser(username, password, name);
      }

      apiService.setToken(user.token);

      // 保存登录信息
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('familymap_user', const JsonEncoder().convert(user.toJson()));

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => MapScreen(
            currentUser: user,
            darkMode: widget.darkMode,
            onDarkModeChanged: widget.onDarkModeChanged,
          )),
        );
      }
    } on AuthExpiredException {
      if (mounted) await handleAuthExpired();
    } catch (e) {
      if (mounted) {
        String msg = e.toString();
        if (msg.contains('用户名或密码错误')) {
          msg = '用户名或密码错误';
        } else if (msg.contains('已被占用')) {
          msg = '用户名已被占用，换一个试试';
        } else if (msg.contains('至少')) {
          msg = msg.replaceAll(RegExp(r'.*error[:\s]*'), '');
        }
        _showError(msg);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4F46E5), Color(0xFF7C3AED), Color(0xFFEC4899)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'FamilyMap',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
                    textScaleFactor: 1.0,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '与家人朋友实时共享位置',
                    style: TextStyle(fontSize: 15, color: Colors.white70),
                    textScaleFactor: 1.0,
                  ),
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20)],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 登录/注册切换
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: () => setState(() => _isLoginMode = true),
                                style: TextButton.styleFrom(
                                  backgroundColor: _isLoginMode ? const Color(0xFF4F46E5) : Colors.transparent,
                                  foregroundColor: _isLoginMode ? Colors.white : const Color(0xFF64748B),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: const Text('登录', style: TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextButton(
                                onPressed: () => setState(() => _isLoginMode = false),
                                style: TextButton.styleFrom(
                                  backgroundColor: !_isLoginMode ? const Color(0xFF4F46E5) : Colors.transparent,
                                  foregroundColor: !_isLoginMode ? Colors.white : const Color(0xFF64748B),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: const Text('注册', style: TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // 用户名
                        const Text('用户名', style: TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _usernameController,
                          decoration: InputDecoration(
                            hintText: '输入用户名',
                            prefixIcon: const Icon(Icons.person_outline, size: 20),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFF4F46E5), width: 1.5),
                            ),
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),

                        // 密码
                        const Text('密码', style: TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: InputDecoration(
                            hintText: '输入密码',
                            prefixIcon: const Icon(Icons.lock_outline, size: 20),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFF4F46E5), width: 1.5),
                            ),
                          ),
                          textInputAction: _isLoginMode ? TextInputAction.go : TextInputAction.next,
                          onSubmitted: _isLoginMode ? (_) => _handleSubmit() : null,
                        ),

                        // 昵称（仅注册模式）
                        if (!_isLoginMode) ...[
                          const SizedBox(height: 12),
                          const Text('昵称', style: TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _nameController,
                            decoration: InputDecoration(
                              hintText: '显示给朋友的名字',
                              prefixIcon: const Icon(Icons.badge_outlined, size: 20),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: Color(0xFF4F46E5), width: 1.5),
                              ),
                            ),
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) => _handleSubmit(),
                          ),
                        ],

                        const SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: _isLoading ? null : _handleSubmit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4F46E5),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          child: _isLoading
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : Text(_isLoginMode ? '登录' : '注册', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
