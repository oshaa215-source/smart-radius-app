import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

// التعديل هنا بسيط: main لم تكن تحتاج async ولا ensureInitialized
// لأنه لا يوجد تهيئة غير متزامنة قبل runApp.
// لو أضفت لاحقاً تهيئة تحتاج await (مثلاً SharedPreferences أو Firebase)،
// أعد async و ensureInitialized معاً.
void main() {
  runApp(const SmartRadiusApp());
}

class SmartRadiusApp extends StatelessWidget {
  const SmartRadiusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'دفع سمارت',
      debugShowCheckedModeBanner: false,
      // اتجاه التطبيق عربي، والشاشات نفسها تستخدم Directionality RTL.
      // لو أردت ترجمة كاملة لعناصر Material (التواريخ وغيرها) بالعربية،
      // أضف flutter_localizations إلى pubspec.yaml و localizationsDelegates هنا.
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2C3E50),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2C3E50),
          foregroundColor: Colors.white,
          centerTitle: true,
          elevation: 2,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
