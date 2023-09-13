import 'dart:collection';

import 'package:appstream/appstream.dart';
import 'package:flutter/foundation.dart';
import 'package:snowball_stemmer/snowball_stemmer.dart';

import '/l10n.dart';
import 'appstream_utils.dart';

class _CachedComponent {
  final AppstreamComponent component;
  final String id;
  final String name;
  final List<String> keywords;
  final List<String> summary;
  final List<String> description;
  final String origin;
  final String package;
  final List<String> mediaTypes;

  _CachedComponent(
      this.component,
      this.id,
      this.name,
      this.keywords,
      this.summary,
      this.description,
      this.origin,
      this.package,
      this.mediaTypes);

  factory _CachedComponent.fromAppstream(AppstreamComponent component) {
    final id = component.getId();
    final name = component.getLocalizedName().toLowerCase();
    const origin = '';
    final package = component.getPackage();
    final mediaTypes = component.getLocalizedMediaTypes();

    final keywords =
        component.getLocalizedKeywords().map((e) => e.toLowerCase()).toList();

    final nonWordCharacters = RegExp('\\W');

    final summary = component
        .getLocalizedSummary()
        .toLowerCase()
        .split(nonWordCharacters)
        .toList();

    final description = component
        .getLocalizedDescription()
        .toLowerCase()
        .split(nonWordCharacters)
        .toList();

    return _CachedComponent(component, id, name, keywords, summary, description,
        origin, package, mediaTypes);
  }

  int match(List<String> tokens) {
    int score = _MatchScore.none.value;

    for (final token in tokens) {
      if (id.contains(token)) {
        score |= _MatchScore.id.value;
      }
      if (name.contains(token)) {
        score |= _MatchScore.name.value;
      }
      if (keywords.contains(token)) {
        score |= _MatchScore.keyword.value;
      }
      if (summary.contains(token)) {
        score |= _MatchScore.summary.value;
      }
      if (description.contains(token)) {
        score |= _MatchScore.description.value;
      }
      if (origin.contains(token)) {
        score |= _MatchScore.origin.value;
      }
      if (package.contains(token)) {
        score |= _MatchScore.pkgName.value;
      }
      if (mediaTypes.any((e) => e.contains(token))) {
        score |= _MatchScore.mediaType.value;
      }
      if (score == _MatchScore.all.value) break;
    }
    return score;
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedComponent && component.id == other.component.id;

  @override
  int get hashCode => component.id.hashCode;
}

enum _MatchScore {
  none(0),
  mediaType(1 << 0),
  pkgName(1 << 1),
  origin(1 << 2),
  description(1 << 3),
  summary(1 << 4),
  keyword(1 << 5),
  name(1 << 6),
  id(1 << 7),
  all(1 << 0 | 1 << 1 | 1 << 2 | 1 << 3 | 1 << 4 | 1 << 5 | 1 << 6 | 1 << 7);

  final int value;

  const _MatchScore(this.value);
}

class _ScoredComponent {
  final int score;
  final AppstreamComponent component;

  const _ScoredComponent(this.score, this.component);
}

class AppstreamService {
  final AppstreamPool _pool;
  late final Future<void> _loader = _pool.load().then((_) => _populateCache());

  // TODO: cache AppstreamPool
  AppstreamService({@visibleForTesting AppstreamPool? pool})
      : _pool = pool ?? AppstreamPool() {
    PlatformDispatcher.instance.onLocaleChanged = () async {
      await _loader;
      _populateCache();
    };
  }

  final HashSet<_CachedComponent> _cache = HashSet<_CachedComponent>();

  @visibleForTesting
  int get cacheSize => _cache.length;

  void _populateCache() {
    _cache.clear();
    for (final component in _pool.components) {
      _cache.add(_CachedComponent.fromAppstream(component));
    }
  }

  List<String> get _greyList =>
      lookupAppLocalizations(PlatformDispatcher.instance.locale)
          .appstreamSearchGreylist
          .split(';');

  Future<void> init() async => _loader;

  static final stemmersMap = <String, Algorithm>{
    'ar': Algorithm.arabic,
    'hy': Algorithm.armenian,
    'eu': Algorithm.basque,
    'ca': Algorithm.catalan,
    'da': Algorithm.danish,
    'nl': Algorithm.dutch,
    'en': Algorithm.english,
    'fi': Algorithm.finnish,
    'fr': Algorithm.french,
    'de': Algorithm.german,
    'el': Algorithm.greek,
    'hi': Algorithm.hindi,
    'hu': Algorithm.hungarian,
    'id': Algorithm.indonesian,
    'ga': Algorithm.irish,
    'it': Algorithm.italian,
    'lt': Algorithm.lithuanian,
    'ne': Algorithm.nepali,
    'nb': Algorithm.norwegian,
    'pt': Algorithm.portuguese,
    'ro': Algorithm.romanian,
    'ru': Algorithm.russian,
    'sr': Algorithm.serbian,
    'es': Algorithm.spanish,
    'sv': Algorithm.swedish,
    'ta': Algorithm.tamil,
    'tr': Algorithm.turkish,
    'yi': Algorithm.yiddish,
  };

  // Re-implementation of as_pool_build_search_tokens()
  // (https://www.freedesktop.org/software/appstream/docs/api/appstream-AsPool.html#as-pool-build-search-tokens)
  List<String> _buildSearchTokens(String search) {
    final words = search.toLowerCase().split(RegExp(r'\s'));
    // Filter out too generic search terms
    words.removeWhere((element) => _greyList.contains(element));
    if (words.isEmpty) {
      words.addAll(search.toLowerCase().split(RegExp(r'\s')));
    }
    // Filter out short tokens, and those containing markup
    words.removeWhere(
      (element) => element.length <= 1 || element.contains(RegExp(r'[<>()]')),
    );
    // Extract only the common stems from the tokens
    final algorithm =
        stemmersMap[PlatformDispatcher.instance.locale.languageCode];
    if (algorithm != null) {
      final stemmer = SnowballStemmer(algorithm);
      return words.map((element) => stemmer.stem(element)).toSet().toList();
    } else {
      return words;
    }
  }

  // Re-implementation of as_pool_search()
  // (https://www.freedesktop.org/software/appstream/docs/api/appstream-AsPool.html#as-pool-search)
  Future<List<AppstreamComponent>> search(String search) async {
    final tokens = _buildSearchTokens(search);
    await _loader;
    if (tokens.isEmpty) {
      if (search.length <= 1) {
        // Search query too broad, matching everything
        return _pool.components;
      } else {
        // No valid search tokens
        return [];
      }
    }
    final scored = <_ScoredComponent>[];
    for (final entry in _cache) {
      final score = entry.match(tokens);
      if (score > 0) {
        scored.add(_ScoredComponent(score, entry.component));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((e) => e.component).toList();
  }
}