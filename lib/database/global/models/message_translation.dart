class MessageTranslation {
  final String text;
  final String sourceLanguage;
  final String targetLanguage;
  final String provider;
  final bool autoTranslated;
  final DateTime? dateTranslated;

  const MessageTranslation({
    required this.text,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.provider,
    required this.autoTranslated,
    this.dateTranslated,
  });

  factory MessageTranslation.fromJson(Map<String, dynamic> json) {
    final rawDate = json['dateTranslated'];
    DateTime? date;
    if (rawDate is int) {
      date = DateTime.fromMillisecondsSinceEpoch(rawDate, isUtc: true).toLocal();
    } else if (rawDate is String) {
      date = DateTime.tryParse(rawDate)?.toLocal();
    } else if (rawDate is DateTime) {
      date = rawDate;
    }
    return MessageTranslation(
      text: json['text']?.toString() ?? '',
      sourceLanguage: json['sourceLanguage']?.toString() ?? '',
      targetLanguage: json['targetLanguage']?.toString() ?? '',
      provider: json['provider']?.toString() ?? '',
      autoTranslated: json['autoTranslated'] == true,
      dateTranslated: date,
    );
  }

  Map<String, dynamic> toJson() => {
        'text': text,
        'sourceLanguage': sourceLanguage,
        'targetLanguage': targetLanguage,
        'provider': provider,
        'autoTranslated': autoTranslated,
        if (dateTranslated != null) 'dateTranslated': dateTranslated!.millisecondsSinceEpoch,
      };

  String get sourceLanguageName => languageName(sourceLanguage);

  static const Map<String, String> _exactNames = {
    'zh-cn': 'Chinese (Simplified)',
    'zh-sg': 'Chinese (Simplified)',
    'zh-hans': 'Chinese (Simplified)',
    'zh-tw': 'Chinese (Traditional)',
    'zh-hk': 'Chinese (Traditional)',
    'zh-mo': 'Chinese (Traditional)',
    'zh-hant': 'Chinese (Traditional)',
    'pt-br': 'Portuguese (Brazil)',
    'pt-pt': 'Portuguese (Portugal)',
  };

  static const Map<String, String> _baseNames = {
    'af': 'Afrikaans',
    'sq': 'Albanian',
    'am': 'Amharic',
    'ar': 'Arabic',
    'hy': 'Armenian',
    'az': 'Azerbaijani',
    'eu': 'Basque',
    'be': 'Belarusian',
    'bn': 'Bengali',
    'bs': 'Bosnian',
    'bg': 'Bulgarian',
    'ca': 'Catalan',
    'zh': 'Chinese',
    'hr': 'Croatian',
    'cs': 'Czech',
    'da': 'Danish',
    'nl': 'Dutch',
    'en': 'English',
    'et': 'Estonian',
    'fil': 'Filipino',
    'tl': 'Filipino',
    'fi': 'Finnish',
    'fr': 'French',
    'gl': 'Galician',
    'ka': 'Georgian',
    'de': 'German',
    'el': 'Greek',
    'gu': 'Gujarati',
    'ht': 'Haitian Creole',
    'he': 'Hebrew',
    'iw': 'Hebrew',
    'hi': 'Hindi',
    'hu': 'Hungarian',
    'is': 'Icelandic',
    'id': 'Indonesian',
    'ga': 'Irish',
    'it': 'Italian',
    'ja': 'Japanese',
    'kn': 'Kannada',
    'kk': 'Kazakh',
    'km': 'Khmer',
    'ko': 'Korean',
    'lo': 'Lao',
    'lv': 'Latvian',
    'lt': 'Lithuanian',
    'mk': 'Macedonian',
    'ms': 'Malay',
    'ml': 'Malayalam',
    'mt': 'Maltese',
    'mr': 'Marathi',
    'mn': 'Mongolian',
    'ne': 'Nepali',
    'no': 'Norwegian',
    'nb': 'Norwegian',
    'nn': 'Norwegian',
    'fa': 'Persian',
    'pl': 'Polish',
    'pt': 'Portuguese',
    'pa': 'Punjabi',
    'ro': 'Romanian',
    'ru': 'Russian',
    'sr': 'Serbian',
    'si': 'Sinhala',
    'sk': 'Slovak',
    'sl': 'Slovenian',
    'es': 'Spanish',
    'sw': 'Swahili',
    'sv': 'Swedish',
    'ta': 'Tamil',
    'te': 'Telugu',
    'th': 'Thai',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'ur': 'Urdu',
    'uz': 'Uzbek',
    'vi': 'Vietnamese',
    'cy': 'Welsh',
    'yi': 'Yiddish',
    'zu': 'Zulu',
  };

  static String languageName(String code) {
    final normalized = code.trim().replaceAll('_', '-').toLowerCase();
    if (normalized.isEmpty) return 'Unknown';
    final exact = _exactNames[normalized];
    if (exact != null) return exact;
    final base = normalized.split('-').first;
    return _baseNames[base] ?? code.toUpperCase();
  }
}
