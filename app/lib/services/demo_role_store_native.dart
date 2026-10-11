/// 앱은 창이 하나라 메모리에만 둔다 (앱을 다시 열면 사용자 모드)
String? _value;

String? readWindowValue(String key) => _value;

void writeWindowValue(String key, String value) => _value = value;
