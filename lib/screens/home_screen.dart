import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'debtors_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  double _progress = 0;

  final String initialUrl = "https://smart-radius.com/smart_a";

  // إصلاح متكامل مع debtors_screen:
  // شاشة المديونين كانت تتجاهل الـ controller الممرر لها وتستخدم WebView خاصة بها،
  // لذلك لم يعد تمريره هنا ضرورياً ولا يوحي بمشاركة جلسة غير حقيقية.
  // الجلستا تشتركان في الـ cookies والتخزين داخل نفس التطبيق، فيبقى تسجيل الدخول.
  void _openDebtors() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const DebtorsScreen()),
    );
  }

  void _showLoadError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('لوحة تحكم Smart Radius'),
          actions: [
            IconButton(
              icon: const Icon(Icons.request_quote_outlined),
              tooltip: 'العملاء المديونين',
              onPressed: _openDebtors,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'تحديث الصفحة',
              onPressed: () {
                _webViewController?.reload();
              },
            ),
          ],
        ),
        body: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                thirdPartyCookiesEnabled: true,
                useHybridComposition: true,
                preferredContentMode: UserPreferredContentMode.DESKTOP,
                // تحديث الـ user agent من Chrome 114 القديم.
                userAgent:
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
              },
              onLoadStart: (controller, url) {
                if (mounted) {
                  setState(() {
                    _isLoading = true;
                  });
                }
              },
              onProgressChanged: (controller, progress) {
                if (mounted) {
                  setState(() {
                    _progress = progress / 100;
                    if (progress == 100) {
                      _isLoading = false;
                    }
                  });
                }
              },
              onLoadStop: (controller, url) {
                if (mounted) {
                  setState(() {
                    _isLoading = false;
                  });
                }
              },
              // إصلاح: فشل التحميل كان يترك مؤشر التحميل معلقاً بلا رسالة.
              onLoadError: (controller, url, code, message) {
                if (mounted) {
                  setState(() {
                    _isLoading = false;
                  });
                }
                _showLoadError('تعذر تحميل الصفحة: $message');
              },
              onLoadHttpError: (controller, url, statusCode, description) {
                if (mounted) {
                  setState(() {
                    _isLoading = false;
                  });
                }
                _showLoadError(
                    'خطأ من الخادم ($statusCode): $description');
              },
            ),
            if (_isLoading)
              LinearProgressIndicator(
                value: _progress,
                backgroundColor: Colors.grey.shade200,
                color: Colors.amber,
                minHeight: 4,
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: const Color(0xFF2C3E50),
          foregroundColor: Colors.white,
          icon: const Icon(Icons.payments_outlined),
          label: const Text(
            'تحصيل المديونيات',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          onPressed: _openDebtors,
        ),
      ),
    );
  }
}
