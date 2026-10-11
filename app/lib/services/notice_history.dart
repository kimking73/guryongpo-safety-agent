import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 화면 알림(스낵바) 기록 (2026-10-12 사용자 요청): 알림은 위쪽에 짧게 3초만 보이고, 지난 알림은 종(알림 화면)에서 다시 본다.
/// 이 기기에만 최근 [max]개 저장한다 (서버로 보내지 않음)
class NoticeEntry {
  const NoticeEntry(this.text, this.at);
  final String text;
  final DateTime at;

  Map<String, String> toJson() => {'text': text, 'at': at.toIso8601String()};
  static NoticeEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    return at == null ? null : NoticeEntry('${j['text']}', at);
  }
}

class NoticeHistory {
  static const max = 30;
  static const _key = 'notice_history_v1';
  /// 최근 알림이 앞에
  static final entries = ValueNotifier<List<NoticeEntry>>(const []);
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final saved = [for (final j in jsonDecode(raw) as List) if (NoticeEntry.fromJson(j) case final e?) e];
      entries.value = [...entries.value, ...saved].take(max).toList();
    } catch (_) {
      // 기록이 깨졌으면 새로 쌓는다
    }
  }

  static void add(String text, {DateTime? at}) {
    final t = text.trim();
    if (t.isEmpty) return;
    entries.value = [NoticeEntry(t, at ?? DateTime.now()), ...entries.value].take(max).toList();
    _save();
  }

  static void clear() {
    entries.value = const [];
    _save();
  }

  static Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(_key, jsonEncode([for (final e in entries.value) e.toJson()]));
    } catch (_) {}
  }
}

/// 스낵바 내용의 글자 (Text · Text.rich 만, 그 밖은 null)
String? noticeText(Widget content) => switch (content) {
      Text(:final data?) => data,
      Text(:final textSpan?) => textSpan.toPlainText(),
      _ => null,
    };

/// 앱 전체 알림 창구 (2026-10-12 사용자 요청): 모든 스낵바를 짧고 좁게(가로 최대 [maxWidth]) 3초만 보이고,
/// 새 알림이 오면 이전 것을 바로 내린다(줄 세우지 않음). 보인 알림은 [NoticeHistory]에 남는다.
/// 위치(화면 위쪽)는 main.dart MaterialApp builder 의 snackBarTheme.insetPadding.
class NoticeMessenger extends ScaffoldMessenger {
  const NoticeMessenger({super.key, required super.child});
  static const shown = Duration(seconds: 3);
  static const maxWidth = 420.0;

  @override
  ScaffoldMessengerState createState() => _NoticeMessengerState();
}

class _NoticeMessengerState extends ScaffoldMessengerState {
  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(SnackBar snackBar,
      {AnimationStyle? snackBarAnimationStyle}) {
    if (noticeText(snackBar.content) case final t?) NoticeHistory.add(t);
    removeCurrentSnackBar();
    return super.showSnackBar(
      SnackBar(
        key: snackBar.key,
        content: snackBar.content,
        action: snackBar.action,
        onVisible: snackBar.onVisible,
        showCloseIcon: snackBar.showCloseIcon,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        duration: NoticeMessenger.shown,
        persist: false,   // [보기] 같은 버튼이 있어도 3초 뒤 내린다
      ),
      snackBarAnimationStyle: snackBarAnimationStyle,
    );
  }
}

/// 알림 화면(종)의 '지난 알림' 카드
class NoticeHistoryCard extends StatelessWidget {
  const NoticeHistoryCard({super.key});

  static String _hm(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext c) => ValueListenableBuilder<List<NoticeEntry>>(
        valueListenable: NoticeHistory.entries,
        builder: (_, list, __) => Card(
          child: ExpansionTile(
            leading: const Icon(Icons.history_rounded),
            title: Text('지난 알림 ${list.length}개', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(list.isEmpty ? '화면에 잠깐 떴던 알림이 여기에 남아요' : list.first.text,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            children: [
              for (final e in list)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.text, style: const TextStyle(fontSize: 15)),
                  trailing: Text(_hm(e.at), style: const TextStyle(fontSize: 13)),
                ),
              if (list.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: NoticeHistory.clear, child: const Text('기록 지우기')),
                ),
            ],
          ),
        ),
      );
}
