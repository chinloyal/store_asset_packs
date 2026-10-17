import 'config.dart';

/// Textual edits to an XML property list's top-level dictionary. Only the
/// edited key's entry changes; comments, formatting and every other key stay
/// byte for byte.
class PlistText {
  PlistText(this.text) {
    _scan();
  }

  String text;

  /// Top-level entries: key name → (start of `<key>`, end of its value).
  final _entries = <String, ({int keyStart, int valueStart, int valueEnd})>{};
  late int _dictEnd; // index of the top-level `</dict>`
  String _indent = '\t';

  static final _token = RegExp(
    r'<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<(/?)([A-Za-z]+)[^>]*?(/?)>',
  );

  void _scan() {
    _entries.clear();
    var depth = 0; // depth 1 = inside the top-level <dict>
    String? pendingKey;
    int? pendingKeyStart;
    int? valueStart;
    var valueDepth = 0;
    var sawDict = false;
    for (final m in _token.allMatches(text)) {
      final tag = m[2];
      if (tag == null) continue; // comment, declaration, doctype
      final closing = m[1] == '/';
      final selfClosing = m[3] == '/';
      if (tag == 'plist') continue;
      if (!closing && !selfClosing && tag == 'dict' && !sawDict) {
        sawDict = true;
        depth = 1;
        continue;
      }
      if (!sawDict) continue;
      if (depth == 1 && closing && tag == 'dict') {
        _dictEnd = m.start;
        return;
      }
      if (depth == 1 && tag == 'key' && !closing) {
        final end = text.indexOf('</key>', m.end);
        pendingKey = _unescape(text.substring(m.end, end));
        pendingKeyStart = m.start;
        final lineStart = text.lastIndexOf('\n', m.start) + 1;
        final lead = text.substring(lineStart, m.start);
        if (lead.trim().isEmpty && _entries.isEmpty) _indent = lead;
        continue;
      }
      if (tag == 'key') continue; // its closing tag, or a nested key
      if (pendingKey != null && valueStart == null && !closing) {
        valueStart = m.start;
        if (selfClosing) {
          _entries[pendingKey] = (
            keyStart: pendingKeyStart!,
            valueStart: m.start,
            valueEnd: m.end,
          );
          pendingKey = valueStart = null;
          continue;
        }
        valueDepth = 1;
        depth++;
        continue;
      }
      if (selfClosing) continue;
      if (closing) {
        depth--;
        if (valueStart != null && --valueDepth == 0) {
          _entries[pendingKey!] = (
            keyStart: pendingKeyStart!,
            valueStart: valueStart,
            valueEnd: m.end,
          );
          pendingKey = valueStart = null;
        }
      } else {
        depth++;
        if (valueStart != null) valueDepth++;
      }
    }
    throw ToolException('Not an XML property list with a top-level <dict>.');
  }

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static String escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// The XML of [key]'s value, or null.
  String? value(String key) {
    final e = _entries[key];
    return e == null ? null : text.substring(e.valueStart, e.valueEnd);
  }

  /// Sets [key] to [valueXml] (e.g. `<true/>`). Replaces only the value of an
  /// existing entry; otherwise appends the entry at the end of the dict.
  void set(String key, String valueXml) {
    final e = _entries[key];
    if (e != null) {
      if (text.substring(e.valueStart, e.valueEnd) == valueXml) return;
      text = text.replaceRange(e.valueStart, e.valueEnd, valueXml);
    } else {
      _insert('$_indent<key>${escape(key)}</key>\n$_indent$valueXml\n');
    }
    _scan();
  }

  /// Adds `<string>[item]</string>` to the array at [key], creating it.
  void addString(String key, String item) {
    final element = '<string>${escape(item)}</string>';
    final e = _entries[key];
    if (e == null) {
      _insert(
        '$_indent<key>${escape(key)}</key>\n$_indent<array>\n'
        '$_indent$_indent$element\n$_indent</array>\n',
      );
    } else {
      final v = text.substring(e.valueStart, e.valueEnd);
      if (v.contains(element)) return;
      if (RegExp(r'^<array\s*/>$').hasMatch(v)) {
        text = text.replaceRange(
          e.valueStart,
          e.valueEnd,
          '<array>\n$_indent$_indent$element\n$_indent</array>',
        );
      } else if (v.startsWith('<array')) {
        final close = e.valueStart + v.lastIndexOf('</array>');
        final lineStart = text.lastIndexOf('\n', close) + 1;
        final closeIndent = text.substring(lineStart, close);
        if (closeIndent.trim().isEmpty) {
          text = text.replaceRange(
            lineStart,
            lineStart,
            '$closeIndent$_indent$element\n',
          );
        } else {
          text = text.replaceRange(close, close, element);
        }
      } else {
        throw ToolException('$key is not an array.');
      }
    }
    _scan();
  }

  void _insert(String entry) {
    final lineStart = text.lastIndexOf('\n', _dictEnd) + 1;
    final at = text.substring(lineStart, _dictEnd).trim().isEmpty
        ? lineStart
        : _dictEnd;
    text = text.replaceRange(at, at, at == lineStart ? entry : '\n$entry');
  }
}
