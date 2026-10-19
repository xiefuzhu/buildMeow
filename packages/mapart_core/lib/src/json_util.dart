/// Small helpers for reading `dynamic` JSON without tripping the strict-cast
/// analyzer settings used by this package.
library;

Map<String, dynamic> asMap(Object? value) {
  if (value is! Map) {
    throw FormatException('expected a JSON object, got ${value.runtimeType}');
  }
  return value.cast<String, dynamic>();
}

List<Object?> asList(Object? value) {
  if (value is! List) {
    throw FormatException('expected a JSON array, got ${value.runtimeType}');
  }
  return value.cast<Object?>();
}

int asInt(Object? value) {
  if (value is! num) {
    throw FormatException('expected a JSON number, got ${value.runtimeType}');
  }
  return value.toInt();
}

String asString(Object? value) {
  if (value is! String) {
    throw FormatException('expected a JSON string, got ${value.runtimeType}');
  }
  return value;
}

bool asBool(Object? value) {
  if (value is! bool) {
    throw FormatException('expected a JSON boolean, got ${value.runtimeType}');
  }
  return value;
}

/// Reads `{"key": "value", ...}` into a string map.
Map<String, String> asStringMap(Object? value) {
  if (value == null) return const <String, String>{};
  final map = asMap(value);
  return map.map((key, value) => MapEntry(key, asString(value)));
}
