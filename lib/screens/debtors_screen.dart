import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class DebtorModel {
  final String id;
  final String name;
  final String username;
  double debt;
  final String status;

  DebtorModel({
    required this.id,
    required this.name,
    required this.username,
    required this.debt,
    required this.status,
  });
}

class DebtorsScreen extends StatefulWidget {
  // ملاحظة: هذا البراميتر كان موجوداً في النسخة الأصلية لكنه لا يُستخدم،
  // لأن InAppWebView ينشئ الـ controller الخاص به في onWebViewCreated.
  // أبقيناه للتوافق مع مكان الاستدعاء، والـ controller الفعلي هو _webController.
  final InAppWebViewController? webViewController;

  const DebtorsScreen({super.key, this.webViewController});

  @override
  State<DebtorsScreen> createState() => _DebtorsScreenState();
}

class _DebtorsScreenState extends State<DebtorsScreen> {
  InAppWebViewController? _webController;

  final String debtorsUrl =
      "https://smart-radius.com/smart_a/users?filter_status=FilterWithDebts";

  List<DebtorModel> allDebtors = [];
  List<DebtorModel> filteredDebtors = [];

  bool isProcessing = true;
  String loadingStatus = "جاري فتح صفحة المديونيات وسحب القائمة...";
  bool shouldScrapeOnLoad = true;
  bool showBrowserPreview = true;

  final TextEditingController _searchController = TextEditingController();

  // إصلاح 1: بديل آمن لـ Timer.periodic مع async.
  // كل عملية تأخذ رقماً، وأي عملية قديمة تُلغى بتغيير الرقم،
  // ولا يوجد Timer يبقى يعمل بعد dispose.
  int _operationId = 0;
  bool _isScraping = false;
  bool _isPaying = false;

  @override
  void dispose() {
    // إلغاء كل الحلقات غير المتزامنة المعلقة، وعدم ترك controller
    // قديم يمكن أن يُستخدم بعد إزالة الشاشة من الشجرة.
    _operationId++;
    _webController = null;
    _searchController.dispose();
    super.dispose();
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  void _applyFilterLocked(String query) {
    // يحسب القائمة المصفاة فقط، من غير setState، حتى لا يُستدعى
    // setState داخل setState أخرى (كان يحدث في فرع نجاح السداد الكامل).
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      filteredDebtors = List.from(allDebtors);
    } else {
      filteredDebtors = allDebtors.where((d) {
        return d.name.toLowerCase().contains(q) ||
            d.username.toLowerCase().contains(q) ||
            d.id.toLowerCase().contains(q);
      }).toList();
    }
  }

  void _filterList(String query) {
    _safeSetState(() {
      _applyFilterLocked(query);
    });
  }

  // إصلاح 2: حلقة async متسلسلة بدل Timer.periodic(async).
  // النسخة القديمة كانت تشغّل evaluateJavascript فوق بعضها كل 600ms
  // حتى لو لم تنتهِ المكالمة السابقة، وكانت تتسرب بعد dispose.
  Future<void> _scrapeDebtorsFromPage() async {
    if (_webController == null || _isScraping) return;
    _isScraping = true;
    final int myOp = ++_operationId;

    _safeSetState(() {
      isProcessing = true;
      loadingStatus = "جاري قراءة جدول المشتركين المديونين...";
    });

    try {
      for (int attempt = 0; attempt < 30; attempt++) {
        if (!mounted || myOp != _operationId) return;
        if (_webController == null) break;

        final result = await _webController!.evaluateJavascript(source: r"""
          (function() {
            try {
              var rows = document.querySelectorAll('table tbody tr');
              if (!rows || rows.length === 0) return null;

              function firstNum(t) {
                // إصلاح مشكلة تضخيم المديونية:
                // الكود القديم كان يمسح كل شيء غير الأرقام من نص الخلية،
                // فيلصق رقمين مختلفين في رقم واحد، مثلاً "70 جنيه ... 210"
                // كانت تتحول إلى 70210.
                // الصح: نأخذ أول رقم فقط من الخلية، والفاصلة , آلاف، والنقطة . عشرية.
                var s = (t || '').replace(/[٠-٩]/g, function(d){ return String('٠١٢٣٤٥٦٧٨٩'.indexOf(d)); })
                                  .replace(/[۰-۹]/g, function(d){ return String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)); });
                var m = s.match(/[0-9]+(?:[.,][0-9]+)?/);
                if (!m) return '';
                return m[0].replace(/,/g, '');
              }

              var list = [];
              for (var r = 0; r < rows.length; r++) {
                var row = rows[r];
                var spans = row.querySelectorAll('span');
                var userId = '';
                for (var s = 0; s < spans.length; s++) {
                  var clickAttr = spans[s].getAttribute('x-on:click') || '';
                  var match = clickAttr.match(/showModelForModel\(['"](\d+)['"]\)/);
                  if (match) { userId = match[1]; break; }
                }
                if (!userId) continue;

                var cells = row.querySelectorAll('td');
                if (cells.length < 3) continue;
                var name = cells.length > 1 ? (cells[1].textContent || '').trim() : 'بدون اسم';
                var username = cells.length > 2 ? (cells[2].textContent || '').trim() : '';
                var statusText = cells.length > 5 ? (cells[5].textContent || '').trim() : '';

                var debtVal = 0.0;
                // أولاً: أول خلية فيها كلمة جنيه، وهي الأصح عادة.
                for (var i = 3; i < cells.length; i++) {
                  var cText = (cells[i].textContent || '').trim();
                  if (cText.indexOf('جنيه') !== -1 || cText.indexOf('جنية') !== -1 || cText.indexOf('ج.م') !== -1) {
                    var cleanNum = firstNum(cText);
                    if (cleanNum && parseFloat(cleanNum) > 0) { debtVal = parseFloat(cleanNum); break; }
                  }
                }
                // بديل فقط إن لم توجد خلية جنيه، ولا نأخذ أي رقم عشوائي من آخر عمود.
                if (debtVal === 0) {
                  for (var j = cells.length - 1; j >= 3; j--) {
                    var txt = (cells[j].textContent || '').trim();
                    if (txt.indexOf('-') !== -1 || txt.indexOf(':') !== -1 || txt.indexOf('GB') !== -1 || txt.indexOf('جيجا') !== -1) continue;
                    var clean = firstNum(txt);
                    if (clean && parseFloat(clean) > 0) { debtVal = parseFloat(clean); break; }
                  }
                }

                list.push({ id: userId, name: name, username: username, debt: debtVal, status: statusText });
              }
              if (list.length === 0) return null;
              return JSON.stringify(list);
            } catch (e) {
              return null;
            }
          })();
        """);

        if (!mounted || myOp != _operationId) return;

        if (result != null && result.toString() != "null") {
          // إصلاح 3: evaluateJavascript قد يعيد String أو List جاهزة حسب الإصدار.
          // النسخة القديمة كانت تفترض String دائماً وتفشل لو وصلت List.
          List<dynamic> decoded;
          if (result is List) {
            decoded = result;
          } else {
            decoded = jsonDecode(result.toString());
          }
          final loaded = decoded.map((item) {
            return DebtorModel(
              id: item['id'].toString(),
              name: item['name'].toString(),
              username: item['username'].toString(),
              debt: double.tryParse(item['debt'].toString()) ?? 0.0,
              status: item['status']?.toString() ?? '',
            );
          }).toList();

          _safeSetState(() {
            allDebtors = loaded;
            filteredDebtors = List.from(allDebtors);
            isProcessing = false;
            loadingStatus = "تم تحميل (${loaded.length}) مشتركين مديونين بنجاح";
          });
          return;
        }

        await Future.delayed(const Duration(milliseconds: 600));
      }

      // وصلنا هنا بعد انتهاء المحاولات دون جدول.
      _safeSetState(() {
        allDebtors = [];
        filteredDebtors = [];
        isProcessing = false;
        loadingStatus = "لا توجد مديونيات معلقة حالياً";
      });
    } catch (e) {
      _safeSetState(() {
        isProcessing = false;
        loadingStatus = "حدث خطأ أثناء معالجة البيانات";
      });
    } finally {
      _isScraping = false;
    }
  }

  void _showPaymentDialog(DebtorModel debtor) {
    final amountController = TextEditingController(
      text: debtor.debt > 0 ? debtor.debt.toStringAsFixed(0) : "",
    );

    showDialog(
      context: context,
      builder: (ctx) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text(
              'سداد مديونية: ${debtor.name}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'المبلغ المطلوب سداده: ${debtor.debt.toStringAsFixed(0)} جنيه',
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'المبلغ المدفوع',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  final paid = double.tryParse(amountController.text.trim());
                  if (paid == null || paid <= 0) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('يرجى إدخال مبلغ صحيح')),
                    );
                    return;
                  }
                  // إزالة التركيز قبل إغلاق الديالوج، حتى لا يُزال حقل
                  // نصي ما زال له dependents وهو مركز عليه.
                  FocusScope.of(ctx).unfocus();
                  Navigator.pop(ctx);
                  _executePaymentAutomation(debtor, paid);
                },
                child: const Text('تأكيد السداد'),
              ),
            ],
          ),
        );
      },
    ).then((_) {
      // إصلاح 4: الـ controller كان يتسرب في كل مرة يُفتح فيها الديالوج.
      amountController.dispose();
    });
  }

  Future<void> _executePaymentAutomation(
      DebtorModel debtor, double paidAmount) async {
    if (_webController == null || _isPaying) return;
    _isPaying = true;
    final int myOp = ++_operationId;

    final bool isPartialPayment = debtor.debt > 0 && paidAmount < debtor.debt;

    _safeSetState(() {
      isProcessing = true;
      showBrowserPreview = true;
      loadingStatus = "1/5 جاري فتح خيارات المشترك (${debtor.name})...";
      shouldScrapeOnLoad = isPartialPayment;
    });

    final String formattedAmount = paidAmount.toStringAsFixed(
        paidAmount.truncateToDouble() == paidAmount ? 0 : 2);

    try {
      // إصلاح 5: تمرير القيم بـ jsonEncode بدل interpolation مباشر.
      // النسخة القديمة كانت تنكسر لو احتوى الـ id على علامة اقتباس،
      // وهي ثغرة حقن JavaScript.
      await _webController!.evaluateJavascript(
        source:
            "window._targetDebtorId = ${jsonEncode(debtor.id)}; window._amountToPay = ${jsonEncode(formattedAmount)}; window._payResult = '';",
      );

      await _webController!.evaluateJavascript(source: r"""
        (function() {
          try {
            if (window._payTimer) clearInterval(window._payTimer);
            window._payStep = 1;
            window._payStatus = 'STEP_1';
            window._payResult = '';
            var targetId = window._targetDebtorId;
            var amountToPay = window._amountToPay;
            var waitTicks = 0;
            var step2Ticks = 0;

            // لا يوجد وضع يدوي هنا: البحث عن الزر واسع، والضغط يتم بـ click() عادي.

            window._payTimer = setInterval(function() {
              try {
                if (window._payStep === 1) {
                  var spans = document.querySelectorAll('span');
                  var gear = null;
                  for (var i = 0; i < spans.length; i++) {
                    var c = spans[i].getAttribute('x-on:click') || '';
                    if (c.indexOf('showModelForModel') !== -1 && c.indexOf(targetId) !== -1) {
                      gear = spans[i]; break;
                    }
                  }
                  if (gear) {
                    gear.scrollIntoView({ block: 'center' });
                    gear.click();
                    step2Ticks = 0;
                    window._payStep = 2;
                    window._payStatus = 'STEP_2';
                  }
                }
                else if (window._payStep === 2) {
                  // أتمتة كاملة: المشكلة الحقيقية كانت أن الكود القديم
                  // لم يكن يجد الزر أصلاً، وليست حماية من الموقع.
                  // لذلك البحث هنا واسع جداً ولا يعتمد على كلاس واحد
                  // ولا على الأيقونة ولا على حاوية modal محددة.
                  var inputsCheck = document.querySelectorAll('input');
                  var inputOpened = false;
                  for (var cIdx = 0; cIdx < inputsCheck.length; cIdx++) {
                    var wm = inputsCheck[cIdx].getAttribute('wire:model') ||
                             inputsCheck[cIdx].getAttribute('wire:model.defer') ||
                             inputsCheck[cIdx].getAttribute('wire:model.live') || '';
                    if (wm.indexOf('paid_price') !== -1 && inputsCheck[cIdx].offsetParent !== null) {
                      inputOpened = true; break;
                    }
                  }
                  if (inputOpened) {
                    window._payStep = 3;
                    window._payStatus = 'STEP_3';
                  } else {
                    // تطبيع النص العربي: إ/أ/آ -> ا، ة -> ه، وإزالة المسافات.
                    function normAr(t) {
                      return (t || '').replace(/[إأآ]/g, 'ا').replace(/ة/g, 'ه').replace(/\s+/g, '');
                    }
                    function isVisible(el) {
                      if (!el) return false;
                      if (el.offsetParent === null) return false;
                      var r = el.getBoundingClientRect();
                      return r.width > 0 && r.height > 0;
                    }
                    function findAddBtn() {
                      // 1) أي زر أو رابط نصه إضافة رصيد بأي شكل.
                      var els = document.querySelectorAll('button, a, [role="button"]');
                      for (var i = 0; i < els.length; i++) {
                        var t = normAr(els[i].textContent);
                        if ((t.indexOf('اضافهرصيد') !== -1 || t.indexOf('اضافه رصيد') !== -1) && isVisible(els[i])) return els[i];
                      }
                      // 2) أي عنصر فيه أيقونة النقود، حتى لو نصه مختلف.
                      var withCoin = document.querySelectorAll('i.bi-cash-coin');
                      for (var c = 0; c < withCoin.length; c++) {
                        var host = withCoin[c].closest('button, a, [role="button"]');
                        if (host && isVisible(host)) return host;
                      }
                      // 3) أي عنصر قابل للضغط ومرتبط بإضافة رصيد من خلال
                      // خاصية x-on:click أو wire:click أو onclick.
                      var all = document.querySelectorAll('[x-on\:click], [x-on\:click\.prevent], [wire\:click], [onclick]');
                      for (var k = 0; k < all.length; k++) {
                        var h = (all[k].getAttribute('x-on:click') || '') +
                                (all[k].getAttribute('x-on:click.prevent') || '') +
                                (all[k].getAttribute('wire:click') || '') +
                                (all[k].getAttribute('onclick') || '');
                        var ht = normAr(all[k].textContent);
                        if ((h.indexOf('paid') !== -1 || h.indexOf('balance') !== -1 || h.indexOf('add') !== -1 || ht.indexOf('رصيد') !== -1) && isVisible(all[k])) {
                          // لا نرجع الترس نفسه: الترس مرتبط بـ showModelForModel.
                          if (h.indexOf('showModelForModel') === -1) return all[k];
                        }
                      }
                      return null;
                    }
                    var targetAddBtn = findAddBtn();
                    if (targetAddBtn) {
                      // تسجيل تشخيصي: لو الضغط فشل لاحقاً، نعرف أي عنصر وجده الكود.
                      try {
                        window._foundAddBtn = targetAddBtn.tagName + '.' + (targetAddBtn.className || '') + ' :: ' + (targetAddBtn.textContent || '').trim();
                      } catch (e) {}
                      targetAddBtn.scrollIntoView({ block: 'center' });
                      targetAddBtn.click();
                      window._payStatus = 'STEP_2_CLICKED';
                    } else {
                      window._payStatus = 'STEP_2_SEARCHING';
                    }
                  }
                }
                else if (window._payStep === 3) {
                  var inputs = document.querySelectorAll('input');
                  var targetInput = null;
                  for (var k = 0; k < inputs.length; k++) {
                    var inp = inputs[k];
                    var wModel = inp.getAttribute('wire:model') ||
                                 inp.getAttribute('wire:model.defer') ||
                                 inp.getAttribute('wire:model.live') || '';
                    if (wModel.indexOf('paid_price') !== -1 && inp.offsetParent !== null) {
                      targetInput = inp; break;
                    }
                  }
                  if (targetInput) {
                    targetInput.focus();
                    var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                    if (nativeSetter) nativeSetter.call(targetInput, amountToPay);
                    else targetInput.value = amountToPay;
                    targetInput.dispatchEvent(new Event('input', { bubbles: true }));
                    targetInput.dispatchEvent(new Event('change', { bubbles: true }));
                    waitTicks = 0;
                    window._payStep = 35;
                  }
                }
                else if (window._payStep === 35) {
                  waitTicks++;
                  if (waitTicks >= 1) { window._payStep = 4; window._payStatus = 'STEP_4'; }
                }
                else if (window._payStep === 4) {
                  var sBtns = document.querySelectorAll('button.btn-success, button');
                  var saveBtn = null;
                  for (var m = 0; m < sBtns.length; m++) {
                    var sb = sBtns[m];
                    var wClick = sb.getAttribute('wire:click.prevent') || sb.getAttribute('wire:click') || '';
                    var sTxt = (sb.textContent || '').trim();
                    if ((wClick.indexOf('save') !== -1 || sTxt === 'حفظ') && sb.offsetParent !== null && !sb.disabled) {
                      saveBtn = sb; break;
                    }
                  }
                  if (saveBtn) {
                    saveBtn.click();
                    waitTicks = 0;
                    window._payStep = 45;
                  }
                }
                else if (window._payStep === 45) {
                  waitTicks++;
                  var bodyTxt = document.body ? (document.body.textContent || '') : '';
                  // إصلاح 6: لا نعتبر انتهاء المهلة نجاحاً.
                  // النجاح فقط عند ظهور نص الإيصال فعلاً.
                  if (bodyTxt.indexOf('المبلغ المدفوع هو') !== -1 || bodyTxt.indexOf('رصيد العميل قبل الاضافة') !== -1) {
                    window._payResult = 'success';
                    window._payStep = 5;
                    window._payStatus = 'STEP_5';
                  } else if (waitTicks >= 12) {
                    window._payStatus = 'ERROR: لم تظهر رسالة تأكيد السداد';
                    clearInterval(window._payTimer);
                  }
                }
                else if (window._payStep === 5) {
                  var cBtns = document.querySelectorAll('a.btn-sm.btn-danger, a.btn-danger, button.btn-danger');
                  for (var n = 0; n < cBtns.length; n++) {
                    var cb = cBtns[n];
                    var cTxt = (cb.textContent || '').trim();
                    if ((cTxt.indexOf('اغلاق') !== -1 || cTxt.indexOf('إغلاق') !== -1) && cb.offsetParent !== null) {
                      cb.click(); break;
                    }
                  }
                  clearInterval(window._payTimer);
                  window._payStep = 6;
                  window._payStatus = 'DONE';
                }
              } catch (innerErr) {
                window._payStatus = 'ERROR: ' + innerErr.message;
                clearInterval(window._payTimer);
              }
            }, 650);
          } catch (err) {
            window._payStatus = 'ERROR: ' + err.message;
          }
        })();
      """);

      // إصلاح 7: حلقة Dart متسلسلة بدل Timer.periodic(async) الثاني.
      String status = "";
      String payResult = "";
      for (int pollCount = 0; pollCount < 90; pollCount++) {
        if (!mounted || myOp != _operationId || _webController == null) return;
        await Future.delayed(const Duration(milliseconds: 650));
        if (!mounted || myOp != _operationId || _webController == null) return;

        final statusObj = await _webController!.evaluateJavascript(source: "window._payStatus;");
        final resultObj = await _webController!.evaluateJavascript(source: "window._payResult;");
        status = statusObj?.toString() ?? "";
        payResult = resultObj?.toString() ?? "";

        _safeSetState(() {
          if (status == "STEP_2_SEARCHING") {
            loadingStatus = "2/5 جاري البحث عن زر (إضافة رصيد)...";
          } else if (status == "STEP_2_CLICKED") {
            loadingStatus = "2/5 تم العثور على زر (إضافة رصيد) وجاري الضغط عليه...";
          } else if (status == "STEP_2") {
            loadingStatus = "2/5 جاري الضغط على زر (إضافة رصيد)...";
          } else if (status == "STEP_3") {
            loadingStatus = "3/5 جاري كتابة المبلغ ($formattedAmount جنيه)...";
          } else if (status == "STEP_4") {
            loadingStatus = "4/5 جاري الضغط على زر (حفظ)...";
          } else if (status == "STEP_5") {
            loadingStatus = "5/5 جاري إغلاق النافذة...";
          } else if (status.startsWith("ERROR:")) {
            loadingStatus = "خطأ: $status";
            isProcessing = false;
          }
        });

        if (status.startsWith("ERROR:")) break;
        if (status == "DONE") break;
      }

      if (status.startsWith("ERROR:")) {
        // لا نحذف العميل ولا ندّعي النجاح. نعيد تحميل القائمة للتحقق
        // من حالة السداد الحقيقية على السيرفر، لأن الحفظ ربما نجح
        // رغم عدم ظهور الإيصال في الصفحة.
        _safeSetState(() {
          isProcessing = true;
          shouldScrapeOnLoad = true;
          loadingStatus = "فشل التأكيد: جاري إعادة تحميل القائمة للتحقق من حالة السداد...";
        });
        if (mounted && _webController != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('توقفت العملية: $status'), backgroundColor: Colors.orange),
          );
          await _webController!.loadUrl(urlRequest: URLRequest(url: WebUri(debtorsUrl)));
        }
        return;
      }

      if (status == "DONE" && payResult == "success") {
        if (isPartialPayment) {
          _safeSetState(() {
            loadingStatus = "سداد جزئي: جاري عمل ريفريش للصفحة لتحديث المديونية المتبقية...";
            shouldScrapeOnLoad = true;
            isProcessing = true;
          });
          await _webController!.loadUrl(urlRequest: URLRequest(url: WebUri(debtorsUrl)));
        } else {
          _safeSetState(() {
            allDebtors.removeWhere((item) => item.id == debtor.id);
            _applyFilterLocked(_searchController.text);
            isProcessing = false;
            shouldScrapeOnLoad = false;
            loadingStatus = "تم سداد مديونية ${debtor.name} بالكامل بنجاح!";
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('تم سداد مديونية ${debtor.name} بالكامل بنجاح!'),
                backgroundColor: Colors.green,
              ),
            );
          }
          await _webController!.loadUrl(urlRequest: URLRequest(url: WebUri(debtorsUrl)));
        }
      } else {
        // انتهت المهلة دون DONE مؤكد: لا نحذف ولا ندّعي نجاحاً.
        await _webController!.evaluateJavascript(
            source: "if(window._payTimer) clearInterval(window._payTimer);");
        _safeSetState(() {
          isProcessing = false;
          loadingStatus = "توقفت العملية عند: $status (شاهد المتصفح بالأعلى)";
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('توقفت العملية عند الخطوة: $status'), backgroundColor: Colors.orange),
          );
        }
      }
    } finally {
      _isPaying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text('العملاء المديونين (${filteredDebtors.length})'),
          actions: [
            IconButton(
              icon: Icon(showBrowserPreview ? Icons.visibility : Icons.visibility_off),
              tooltip: 'إظهار/إخفاء المتصفح',
              onPressed: () {
                _safeSetState(() {
                  showBrowserPreview = !showBrowserPreview;
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'تحديث القائمة',
              onPressed: () {
                _safeSetState(() {
                  shouldScrapeOnLoad = true;
                  isProcessing = true;
                  loadingStatus = "جاري تحديث صفحة المديونيات...";
                });
                _webController?.reload();
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: isProcessing ? Colors.amber.shade100 : Colors.blueGrey.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  if (isProcessing)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  else
                    const Icon(Icons.info_outline, size: 18, color: Color(0xFF2C3E50)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      loadingStatus,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2C3E50),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // إصلاح خطأ '_dependents.isEmpty':
            // AnimatedContainer كان يزيل WebView من الشجرة عند إخفائه
            // (height = 0)، وWebView منصة أصلية لها dependents، فكان
            // إطار Flutter يرفض إزالتها وهي ما زالت مرتبطة.
            // الحل: WebView تبقى دائماً في الشجرة داخل Offstage،
            // ويتغير ارتفاع الحاوية فقط، فلا تُزال أبداً أثناء عمل الشاشة.
            SizedBox(
              height: showBrowserPreview ? 220 : 0,
              width: double.infinity,
              child: Offstage(
                offstage: !showBrowserPreview,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.grey.shade400, width: 2)),
                  ),
                  child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(debtorsUrl)),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  preferredContentMode: UserPreferredContentMode.DESKTOP,
                  userAgent:
                      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36",
                ),
                onWebViewCreated: (controller) {
                  _webController = controller;
                },
                onLoadStop: (controller, url) async {
                  if (shouldScrapeOnLoad && !_isScraping) {
                    await _scrapeDebtorsFromPage();
                  }
                },
                // إصلاح 8: قبل ذلك لو فشل التحميل أو انتهت الجلسة،
                // كان الكود ينتظر 12 ثانية ثم يقول "لا توجد مديونيات" خطأً.
                onLoadError: (controller, url, code, message) {
                  _safeSetState(() {
                    isProcessing = false;
                    loadingStatus = "فشل تحميل الصفحة ($code): تحقق من تسجيل الدخول والاتصال";
                  });
                },
                onLoadHttpError: (controller, url, statusCode, description) {
                  _safeSetState(() {
                    isProcessing = false;
                    loadingStatus = "خطأ من السيرفر ($statusCode): تحقق من تسجيل الدخول";
                  });
                },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: TextField(
                controller: _searchController,
                onChanged: _filterList,
                decoration: InputDecoration(
                  hintText: 'ابحث باسم المشترك أو اليوزر...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            _filterList('');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ),
            Expanded(
              child: filteredDebtors.isEmpty && !isProcessing
                  ? Center(
                      child: Text(
                        // إصلاح 9: رسالة مختلفة عند عدم مطابقة البحث.
                        _searchController.text.trim().isNotEmpty
                            ? 'لا توجد نتائج مطابقة للبحث'
                            : 'لا يوجد مشتركين مديونين حالياً',
                        style: const TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filteredDebtors.length,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemBuilder: (context, index) {
                        final debtor = filteredDebtors[index];
                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF2C3E50),
                              foregroundColor: Colors.white,
                              child: Text('${index + 1}'),
                            ),
                            title: Text(debtor.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (debtor.username.isNotEmpty)
                                  Text('اليوزر: ${debtor.username} ${debtor.status.isNotEmpty ? "(${debtor.status})" : ""}'),
                                Text(
                                  'المديونية: ${debtor.debt.toStringAsFixed(0)} جنيه',
                                  style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 15),
                                ),
                              ],
                            ),
                            trailing: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                              icon: const Icon(Icons.payments, size: 18),
                              label: const Text('سداد'),
                              onPressed: isProcessing ? null : () => _showPaymentDialog(debtor),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
