import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:bluebubbles/database/html/attachment.dart';
import 'package:bluebubbles/database/html/chat.dart';
import 'package:bluebubbles/database/html/contact_v2.dart';
import 'package:bluebubbles/database/html/custom_group.dart';
import 'package:bluebubbles/database/html/fcm_data.dart';
import 'package:bluebubbles/database/html/handle.dart';
import 'package:bluebubbles/database/html/idb_persistence.dart';
import 'package:bluebubbles/database/html/message.dart';
import 'package:bluebubbles/database/html/theme.dart';
import 'package:bluebubbles/database/html/theme_entry.dart';
import 'package:bluebubbles/database/html/theme_object.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:idb_shim/idb_shim.dart' show IdbFactory;

enum TxMode { read, write }

enum PutMode { put, insert, update }

class Order {
  static const int descending = 1;
  static const int caseSensitive = 2;
  static const int unsigned = 4;
  static const int nullsLast = 8;
  static const int nullsAsZero = 16;
}

class UniqueViolationException implements Exception {
  final String message;
  UniqueViolationException([this.message = 'Unique constraint violation']);
  @override
  String toString() => 'UniqueViolationException: $message';
}

class ObjectBoxException implements Exception {
  final String message;
  ObjectBoxException(this.message);
  @override
  String toString() => 'ObjectBoxException: $message';
}

// ============================================================================
// Query Conditions & Properties
// ============================================================================

abstract class Condition<T> {
  const Condition();

  bool matches(T entity);

  void _collectParams<D>(QueryProperty<T, D> prop, String? alias, List<void Function(D)> setters, List<void Function(List<D>)> listSetters) {}

  Condition<T> and(Condition<T> other) => _BinaryCondition<T>(this, other, true);
  Condition<T> or(Condition<T> other) => _BinaryCondition<T>(this, other, false);

  Condition<T> operator &(Condition<T> other) => and(other);
  Condition<T> operator |(Condition<T> other) => or(other);
}

class _BinaryCondition<T> extends Condition<T> {
  final Condition<T> left;
  final Condition<T> right;
  final bool isAnd;
  const _BinaryCondition(this.left, this.right, this.isAnd);

  @override
  bool matches(T entity) => isAnd ? (left.matches(entity) && right.matches(entity)) : (left.matches(entity) || right.matches(entity));

  @override
  void _collectParams<D>(QueryProperty<T, D> prop, String? alias, List<void Function(D)> setters, List<void Function(List<D>)> listSetters) {
    left._collectParams<D>(prop, alias, setters, listSetters);
    right._collectParams<D>(prop, alias, setters, listSetters);
  }
}

class _PredicateCondition<T, D> extends Condition<T> {
  final QueryProperty<T, D> prop;
  final String? alias;
  final bool isEquality;
  D? value;
  List<D>? values;
  final bool Function(D? actual, D? target, List<D>? list) test;

  _PredicateCondition(this.prop, this.test, {this.value, this.values, this.alias, this.isEquality = false});

  @override
  bool matches(T entity) => test(prop.getter(entity), value, values);

  @override
  void _collectParams<P>(QueryProperty<T, P> targetProp, String? targetAlias, List<void Function(P)> setters, List<void Function(List<P>)> listSetters) {
    if (identical(prop, targetProp) && (targetAlias == null || targetAlias == alias)) {
      setters.add((P v) => value = v as D);
      listSetters.add((List<P> vs) => values = vs.cast<D>());
    }
  }
}

class QueryProperty<EntityT, DartT> {
  final String name;
  final DartT? Function(EntityT entity) getter;
  const QueryProperty(this.name, this.getter);

  Condition<EntityT> isNull({String? alias}) =>
      _PredicateCondition<EntityT, DartT>(this, (a, _, __) => a == null, alias: alias);

  Condition<EntityT> notNull({String? alias}) =>
      _PredicateCondition<EntityT, DartT>(this, (a, _, __) => a != null, alias: alias);
}

class QueryIntegerProperty<EntityT> extends QueryProperty<EntityT, int> {
  const QueryIntegerProperty(super.name, super.getter);

  Condition<EntityT> _cmp(int p, bool Function(int a, int t) fn, {String? alias, bool isEquality = false}) =>
      _PredicateCondition<EntityT, int>(this, (a, t, _) => a != null && t != null && fn(a, t),
          value: p, alias: alias, isEquality: isEquality);

  Condition<EntityT> equals(int p, {String? alias}) => _cmp(p, (a, t) => a == t, alias: alias, isEquality: true);
  Condition<EntityT> notEquals(int p, {String? alias}) => _cmp(p, (a, t) => a != t, alias: alias);
  Condition<EntityT> greaterThan(int p, {String? alias}) => _cmp(p, (a, t) => a > t, alias: alias);
  Condition<EntityT> greaterOrEqual(int p, {String? alias}) => _cmp(p, (a, t) => a >= t, alias: alias);
  Condition<EntityT> lessThan(int p, {String? alias}) => _cmp(p, (a, t) => a < t, alias: alias);
  Condition<EntityT> lessOrEqual(int p, {String? alias}) => _cmp(p, (a, t) => a <= t, alias: alias);

  Condition<EntityT> between(int p1, int p2, {String? alias}) {
    final lo = p1 <= p2 ? p1 : p2;
    final hi = p1 <= p2 ? p2 : p1;
    return _PredicateCondition<EntityT, int>(this, (a, _, __) => a != null && a >= lo && a <= hi, alias: alias);
  }

  Condition<EntityT> oneOf(List<int> list, {String? alias}) => _PredicateCondition<EntityT, int>(
        this,
        (a, _, l) => a != null && l != null && l.contains(a),
        values: List<int>.from(list),
        alias: alias,
      );

  Condition<EntityT> notOneOf(List<int> list, {String? alias}) => _PredicateCondition<EntityT, int>(
        this,
        (a, _, l) => a != null && (l == null || !l.contains(a)),
        values: List<int>.from(list),
        alias: alias,
      );
}

class QueryDateProperty<EntityT> extends QueryIntegerProperty<EntityT> {
  const QueryDateProperty(super.name, super.getter);
}

class QueryStringProperty<EntityT> extends QueryProperty<EntityT, String> {
  const QueryStringProperty(super.name, super.getter);

  static String _norm(String s, bool cs) => cs ? s : s.toLowerCase();

  Condition<EntityT> _cmp(
    String p,
    bool Function(String a, String t) fn, {
    bool caseSensitive = true,
    String? alias,
    bool isEquality = false,
  }) =>
      _PredicateCondition<EntityT, String>(
        this,
        (a, t, _) => a != null && t != null && fn(_norm(a, caseSensitive), _norm(t, caseSensitive)),
        value: p,
        alias: alias,
        isEquality: isEquality,
      );

  Condition<EntityT> equals(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a == t, caseSensitive: caseSensitive, alias: alias, isEquality: caseSensitive);
  Condition<EntityT> notEquals(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a != t, caseSensitive: caseSensitive, alias: alias);
  Condition<EntityT> contains(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a.contains(t), caseSensitive: caseSensitive, alias: alias);
  Condition<EntityT> startsWith(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a.startsWith(t), caseSensitive: caseSensitive, alias: alias);
  Condition<EntityT> endsWith(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a.endsWith(t), caseSensitive: caseSensitive, alias: alias);
  Condition<EntityT> greaterThan(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a.compareTo(t) > 0, caseSensitive: caseSensitive, alias: alias);
  Condition<EntityT> greaterOrEqual(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a.compareTo(t) >= 0, caseSensitive: caseSensitive, alias: alias);
  Condition<EntityT> lessThan(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a.compareTo(t) < 0, caseSensitive: caseSensitive, alias: alias);
  Condition<EntityT> lessOrEqual(String p, {bool caseSensitive = true, String? alias}) =>
      _cmp(p, (a, t) => a.compareTo(t) <= 0, caseSensitive: caseSensitive, alias: alias);

  Condition<EntityT> oneOf(List<String> list, {bool caseSensitive = true, String? alias}) =>
      _PredicateCondition<EntityT, String>(
        this,
        (a, _, l) => a != null && l != null && l.any((item) => _norm(item, caseSensitive) == _norm(a, caseSensitive)),
        values: List<String>.from(list),
        alias: alias,
      );

  Condition<EntityT> notOneOf(List<String> list, {bool caseSensitive = true, String? alias}) =>
      _PredicateCondition<EntityT, String>(
        this,
        (a, _, l) => a != null && (l == null || !l.any((item) => _norm(item, caseSensitive) == _norm(a, caseSensitive))),
        values: List<String>.from(list),
        alias: alias,
      );
}

class QueryBooleanProperty<EntityT> extends QueryProperty<EntityT, bool> {
  const QueryBooleanProperty(super.name, super.getter);

  Condition<EntityT> equals(bool p, {String? alias}) =>
      _PredicateCondition<EntityT, bool>(this, (a, t, _) => a != null && a == t, value: p, alias: alias);

  Condition<EntityT> notEquals(bool p, {String? alias}) =>
      _PredicateCondition<EntityT, bool>(this, (a, t, _) => a != null && a != t, value: p, alias: alias);
}

class QueryStringVectorProperty<EntityT> extends QueryProperty<EntityT, List<String>> {
  const QueryStringVectorProperty(super.name, super.getter);
}

class QueryRelationToOne<EntityT, TargetT> extends QueryIntegerProperty<EntityT> {
  final ToOne<TargetT> Function(EntityT entity) relationGetter;

  QueryRelationToOne(String name, this.relationGetter)
      : super(name, (e) {
          final id = relationGetter(e).targetId;
          return id > 0 ? id : null;
        });
}

class QueryRelationToMany<EntityT, TargetT> {
  final String name;
  final ToMany<TargetT> Function(EntityT entity) getter;
  const QueryRelationToMany(this.name, this.getter);
}

class QueryBacklinkToMany<SourceT, EntityT> {
  final QueryRelationToOne<SourceT, EntityT>? toOne;
  final QueryRelationToMany<SourceT, EntityT>? toMany;
  const QueryBacklinkToMany(this.toOne) : toMany = null;
  const QueryBacklinkToMany.many(this.toMany) : toOne = null;
}

// ============================================================================
// QueryParam, PropertyQuery, QueryBuilder, Query
// ============================================================================

class QueryParam<D> {
  final List<void Function(D)> _setters;
  final List<void Function(List<D>)> _listSetters;

  QueryParam._(this._setters, this._listSetters);

  set value(D val) {
    for (final s in _setters) {
      s(val);
    }
  }

  set values(List<D> vals) {
    for (final s in _listSetters) {
      s(vals);
    }
  }
}

class PropertyQuery<T> {
  final List<dynamic> _entities;
  final dynamic Function(dynamic) _getter;
  bool distinct = false;
  bool caseSensitive = true;

  PropertyQuery._(this._entities, this._getter);

  List<T> find({T? replaceNullWith}) {
    final out = <T>[];
    final seen = <Object?>{};
    for (final entity in _entities) {
      final raw = _getter(entity);
      final val = raw ?? replaceNullWith;
      if (val == null) continue;
      final typed = val as T;
      if (distinct) {
        final key = (typed is String && !caseSensitive) ? typed.toLowerCase() : typed;
        if (!seen.add(key)) continue;
      }
      out.add(typed);
    }
    return out;
  }

  T? findFirst({T? replaceNullWith}) {
    final list = find(replaceNullWith: replaceNullWith);
    return list.isEmpty ? null : list.first;
  }

  int count() => find().length;

  void close() {}
}

class _OrderSpec<T> {
  final QueryProperty<T, dynamic> prop;
  final int flags;
  const _OrderSpec(this.prop, this.flags);
}

abstract class _LinkClause {
  bool matchesEntity(dynamic entity);
  void collectTypes(Set<Type> out);
  void collectParams<E, D>(QueryProperty<E, D> prop, String? alias, List<void Function(D)> setters, List<void Function(List<D>)> listSetters);
}

class _TypedLinkClause<EntityT, TargetT> extends _LinkClause {
  final _QueryBuilder<TargetT> targetBuilder;
  final bool Function(EntityT entity, bool Function(TargetT) targetMatches) matcher;

  _TypedLinkClause(this.targetBuilder, this.matcher);

  @override
  bool matchesEntity(dynamic entity) {
    if (entity is! EntityT) return false;
    return matcher(entity, targetBuilder._matchesEntity);
  }

  @override
  void collectTypes(Set<Type> out) => targetBuilder._fillQueriedEntities(out);

  @override
  void collectParams<E, D>(QueryProperty<E, D> prop, String? alias, List<void Function(D)> setters, List<void Function(List<D>)> listSetters) {
    if (TargetT == E) {
      targetBuilder._queryCondition?._collectParams(prop as QueryProperty<TargetT, D>, alias, setters, listSetters);
    }
    for (final sub in targetBuilder._links) {
      sub.collectParams<E, D>(prop, alias, setters, listSetters);
    }
  }
}

class _QueryBuilder<T> {
  final Store _store;
  final Condition<T>? _queryCondition;
  final List<_LinkClause> _links = [];

  _QueryBuilder(this._store, this._queryCondition);

  void _fillQueriedEntities(Set<Type> outEntities) {
    outEntities.add(T);
    for (final link in _links) {
      link.collectTypes(outEntities);
    }
  }

  bool _matchesEntity(T entity) {
    if (_queryCondition != null && !_queryCondition.matches(entity)) {
      return false;
    }
    for (final link in _links) {
      if (!link.matchesEntity(entity)) return false;
    }
    return true;
  }

  _QueryBuilder<TargetT> link<TargetT>(QueryRelationToOne<T, TargetT> rel, [Condition<TargetT>? qc]) {
    final child = _QueryBuilder<TargetT>(_store, qc);
    final targetBox = _store._boxOrNull<TargetT>();
    _links.add(_TypedLinkClause<T, TargetT>(child, (entity, test) {
      if (targetBox == null) return false;
      final id = rel.relationGetter(entity).targetId;
      if (id <= 0) return false;
      final target = targetBox.get(id);
      return target != null && test(target);
    }));
    return child;
  }

  _QueryBuilder<SourceT> backlink<SourceT>(QueryRelationToOne<SourceT, T> rel, [Condition<SourceT>? qc]) {
    final child = _QueryBuilder<SourceT>(_store, qc);
    final sourceBox = _store._boxOrNull<SourceT>();
    final selfBox = _store._boxOrNull<T>();
    _links.add(_TypedLinkClause<T, SourceT>(child, (entity, test) {
      if (sourceBox == null || selfBox == null) return false;
      final entityId = selfBox._idOf(entity);
      if (entityId == null || entityId <= 0) return false;
      for (final src in sourceBox._items.values) {
        if (rel.relationGetter(src).targetId == entityId && test(src)) {
          return true;
        }
      }
      return false;
    }));
    return child;
  }

  _QueryBuilder<TargetT> linkMany<TargetT>(QueryRelationToMany<T, TargetT> rel, [Condition<TargetT>? qc]) {
    final child = _QueryBuilder<TargetT>(_store, qc);
    final targetBox = _store._boxOrNull<TargetT>();
    _links.add(_TypedLinkClause<T, TargetT>(child, (entity, test) {
      if (targetBox == null) return false;
      final many = rel.getter(entity);
      for (final id in many._effectiveTargetIds()) {
        final target = targetBox.get(id);
        if (target != null && test(target)) return true;
      }
      return false;
    }));
    return child;
  }

  _QueryBuilder<SourceT> backlinkMany<SourceT>(QueryRelationToMany<SourceT, T> rel, [Condition<SourceT>? qc]) {
    final child = _QueryBuilder<SourceT>(_store, qc);
    final sourceBox = _store._boxOrNull<SourceT>();
    final selfBox = _store._boxOrNull<T>();
    _links.add(_TypedLinkClause<T, SourceT>(child, (entity, test) {
      if (sourceBox == null || selfBox == null) return false;
      final entityId = selfBox._idOf(entity);
      if (entityId == null || entityId <= 0) return false;
      for (final src in sourceBox._items.values) {
        if (rel.getter(src)._effectiveTargetIds().contains(entityId) && test(src)) {
          return true;
        }
      }
      return false;
    }));
    return child;
  }
}

class QueryBuilder<T> extends _QueryBuilder<T> {
  final Box<T> _box;
  final List<_OrderSpec<T>> _orders = [];

  QueryBuilder(this._box, Condition<T>? qc) : super(_box._store, qc);

  QueryBuilder<T> order<D>(QueryProperty<T, D> p, {int flags = 0}) {
    _orders.add(_OrderSpec<T>(p, flags));
    return this;
  }

  Query<T> build() => Query<T>._(_box, _queryCondition, List.of(_links), List.of(_orders));

  Stream<Query<T>> watch({bool triggerImmediately = false}) {
    final queriedEntities = HashSet<Type>();
    _fillQueriedEntities(queriedEntities);
    final query = build();
    late StreamSubscription<List<Type>> subscription;
    late StreamController<Query<T>> controller;

    void subscribe() {
      subscription = _store._entityChanges.listen((List<Type> entityTypes) {
        if (entityTypes.any(queriedEntities.contains) && !controller.isClosed) {
          controller.add(query);
        }
      });
    }

    controller = StreamController<Query<T>>(
      onListen: subscribe,
      onResume: () => subscription.resume(),
      onPause: () => subscription.pause(),
      onCancel: () => subscription.cancel(),
    );
    if (triggerImmediately) controller.add(query);
    return controller.stream;
  }
}

class Query<T> {
  final Box<T> _box;
  final Condition<T>? _condition;
  final List<_LinkClause> _links;
  final List<_OrderSpec<T>> _orders;

  int offset = 0;
  int limit = 0;

  Query._(this._box, this._condition, this._links, this._orders);

  bool _matches(T entity) {
    if (_condition != null && !_condition.matches(entity)) return false;
    for (final link in _links) {
      if (!link.matchesEntity(entity)) return false;
    }
    return true;
  }

  Iterable<T> _candidates() {
    // Fast-path narrowing when querying Message by chat id or any box by indexed guid.
    if (T == Message && _links.isNotEmpty) {
      for (final link in _links) {
        if (link is _TypedLinkClause<Message, Chat>) {
          final cond = link.targetBuilder._queryCondition;
          if (cond is _PredicateCondition<Chat, int> &&
              cond.isEquality &&
              identical(cond.prop, Chat_.id) &&
              cond.value != null) {
            final msgBox = _box as Box<Message>;
            final ids = msgBox._reverseIndex[cond.value!];
            if (ids == null) return const [];
            return ids.map((id) => msgBox._items[id]).whereType<Message>().cast<T>();
          }
        }
      }
    }
    if (_condition is _PredicateCondition<T, String>) {
      final pred = _condition;
      if (pred.isEquality &&
          _box._secondaryIndexProp != null &&
          identical(pred.prop, _box._secondaryIndexProp) &&
          pred.value != null &&
          pred.value!.isNotEmpty) {
        final id = _box._secondaryIndex[pred.value!];
        if (id == null) return const [];
        final item = _box._items[id];
        return item == null ? const [] : <T>[item];
      }
    }
    if (_condition is _PredicateCondition<T, int>) {
      final pred = _condition;
      if (pred.isEquality && identical(pred.prop, _box._idProp) && pred.value != null) {
        final item = _box._items[pred.value!];
        return item == null ? const [] : <T>[item];
      }
    }
    return _box._items.values;
  }

  List<T> _executeRaw() {
    final results = <T>[];
    for (final entity in _candidates()) {
      if (_matches(entity)) results.add(entity);
    }
    if (_orders.isNotEmpty && results.length > 1) {
      results.sort((a, b) {
        for (final spec in _orders) {
          final cmp = _compareValues(spec.prop.getter(a), spec.prop.getter(b), spec.flags);
          if (cmp != 0) return cmp;
        }
        return 0;
      });
    }
    return results;
  }

  static int _compareValues(dynamic a, dynamic b, int flags) {
    final desc = (flags & Order.descending) != 0;
    final nullsLast = (flags & Order.nullsLast) != 0;
    final nullsAsZero = (flags & Order.nullsAsZero) != 0;

    if (a == null && b == null) return 0;
    if (a == null || b == null) {
      if (nullsAsZero) {
        a ??= (b is String ? '' : (b is bool ? false : 0));
        b ??= (a is String ? '' : (a is bool ? false : 0));
      } else {
        if (nullsLast) return a == null ? 1 : -1;
        // ObjectBox default: null first in ASC, null last in DESC
        final cmp = a == null ? -1 : 1;
        return desc ? -cmp : cmp;
      }
    }

    int cmp;
    if (a is String && b is String) {
      final cs = (flags & Order.caseSensitive) != 0;
      cmp = cs ? a.compareTo(b) : a.toLowerCase().compareTo(b.toLowerCase());
    } else if (a is num && b is num) {
      cmp = a.compareTo(b);
    } else if (a is bool && b is bool) {
      cmp = (a ? 1 : 0).compareTo(b ? 1 : 0);
    } else if (a is Comparable && b is Comparable) {
      cmp = a.compareTo(b);
    } else {
      cmp = a.toString().compareTo(b.toString());
    }
    return desc ? -cmp : cmp;
  }

  List<T> find() {
    final all = _executeRaw();
    if (offset == 0 && limit == 0) return all;
    if (offset >= all.length) return <T>[];
    final end = limit > 0 ? (offset + limit).clamp(offset, all.length) : all.length;
    return all.sublist(offset, end);
  }

  Future<List<T>> findAsync() async => find();

  T? findFirst() {
    if (_orders.isEmpty && offset == 0) {
      for (final entity in _candidates()) {
        if (_matches(entity)) return entity;
      }
      return null;
    }
    final list = find();
    return list.isEmpty ? null : list.first;
  }

  Future<List<int>> findIdsAsync() async => find().map((e) => _box._idOf(e)!).toList();

  int count() {
    int n = 0;
    for (final entity in _candidates()) {
      if (_matches(entity)) n++;
    }
    return n;
  }

  int remove() {
    final ids = <int>[];
    for (final entity in _candidates()) {
      if (_matches(entity)) {
        final id = _box._idOf(entity);
        if (id != null) ids.add(id);
      }
    }
    if (ids.isEmpty) return 0;
    return _box.removeMany(ids);
  }

  PropertyQuery<D> property<D>(QueryProperty<T, D> prop) =>
      PropertyQuery<D>._(find(), (entity) => prop.getter(entity as T));

  QueryParam<D> param<D>(QueryProperty<T, D> prop, {String? alias}) {
    final setters = <void Function(D)>[];
    final listSetters = <void Function(List<D>)>[];
    _condition?._collectParams<D>(prop, alias, setters, listSetters);
    for (final link in _links) {
      link.collectParams<T, D>(prop, alias, setters, listSetters);
    }
    return QueryParam<D>._(setters, listSetters);
  }

  void close() {}
}

// ============================================================================
// Relations: ToOne & ToMany
// ============================================================================

class ToOne<T> {
  int _targetId = 0;
  T? _target;
  Store? _store;

  ToOne({T? target, int? targetId}) {
    if (target != null) {
      this.target = target;
    } else if (targetId != null) {
      _targetId = targetId;
    }
  }

  int get targetId {
    if (_target != null && _store != null) {
      final id = _store!._boxOrNull<T>()?._idOf(_target as T);
      if (id != null && id > 0) _targetId = id;
    }
    return _targetId;
  }

  set targetId(int? value) {
    final v = value ?? 0;
    if (_targetId != v) {
      _targetId = v;
      _target = null;
    }
  }

  T? get target {
    if (_targetId > 0 && _store != null) {
      final live = _store!._boxOrNull<T>()?.get(_targetId);
      if (live != null) {
        _target = live;
        return live;
      }
      _target = null;
      return null;
    }
    return _target;
  }

  set target(T? value) {
    _target = value;
    if (value == null) {
      _targetId = 0;
    } else if (_store != null) {
      _targetId = _store!._boxOrNull<T>()?._idOf(value) ?? 0;
    } else {
      _targetId = _extractEntityId(value) ?? 0;
    }
  }

  bool get hasValue => targetId > 0;

  void _attach(Store store) {
    _store = store;
    if (_target != null) {
      final id = store._boxOrNull<T>()?._idOf(_target as T);
      if (id != null && id > 0) _targetId = id;
    }
  }

  int _syncBeforeOwnerPut(Store store) {
    _attach(store);
    final box = store._boxOrNull<T>();
    if (_target != null && box != null) {
      final currentId = box._idOf(_target as T);
      if (currentId == null || currentId <= 0) {
        _targetId = box._resolveUniqueOrPut(_target as T);
      } else {
        _targetId = currentId;
      }
    }
    return _targetId;
  }
}

class ToMany<T> extends ListBase<T> {
  Store? _store;
  List<int> _targetIds = [];
  List<T>? _items;
  bool _dirty = false;

  // Backlink hooks when this ToMany represents @Backlink(...)
  bool _isBacklink = false;
  List<T> Function()? _backlinkResolver;
  void Function(List<T> added, List<T> removed)? _backlinkApplier;
  final List<T> _pendingAdd = [];
  final List<T> _pendingRemove = [];
  void Function()? _standaloneApplier;

  ToMany({List<T>? items}) {
    if (items != null && items.isNotEmpty) {
      _items = List<T>.from(items);
      _dirty = true;
    }
  }

  void _initStandalone(
    Store store,
    List<int> targetIds,
    void Function() applyOwner,
  ) {
    _store = store;
    _isBacklink = false;
    _standaloneApplier = applyOwner;
    if (_items != null && _dirty) {
      // Owner already had local additions before first put
      _syncStandaloneIdsFromItems(autoPut: false);
    } else {
      _targetIds = List<int>.from(targetIds);
      _items = null;
      _dirty = false;
    }
  }

  void _initBacklink(
    Store store,
    List<T> Function() resolver,
    void Function(List<T> added, List<T> removed) applier,
  ) {
    _store = store;
    _isBacklink = true;
    _backlinkResolver = resolver;
    _backlinkApplier = applier;
    if (_dirty && _items != null) {
      for (final item in _items!) {
        if (!_pendingAdd.contains(item)) _pendingAdd.add(item);
      }
      _items = null;
      _dirty = false;
    }
  }

  List<int> _effectiveTargetIds() {
    if (_dirty && _items != null) {
      final ids = <int>[];
      for (final item in _items!) {
        final id = _extractEntityId(item);
        if (id != null && id > 0) ids.add(id);
      }
      return ids;
    }
    return _targetIds;
  }

  List<int> _syncStandaloneIdsFromItems({required bool autoPut}) {
    if (_items == null) return _targetIds;
    final box = _store?._boxOrNull<T>();
    final ids = <int>[];
    for (final item in _items!) {
      int? id = box != null ? box._idOf(item) : _extractEntityId(item);
      if ((id == null || id <= 0) && box != null) {
        id = box._stampExistingUniqueId(item);
        if ((id == null || id <= 0) && autoPut) {
          id = box.put(item);
        }
      }
      if (id != null && id > 0 && !ids.contains(id)) {
        ids.add(id);
      }
    }
    _targetIds = ids;
    return _targetIds;
  }

  void _flushBacklinkPending() {
    if (!_isBacklink || _backlinkApplier == null) return;
    if (_pendingAdd.isEmpty && _pendingRemove.isEmpty) return;
    final added = List<T>.from(_pendingAdd);
    final removed = List<T>.from(_pendingRemove);
    _pendingAdd.clear();
    _pendingRemove.clear();
    _dirty = false;
    _items = null;
    _backlinkApplier!(added, removed);
  }

  List<T> _ensureResolved() {
    if (_isBacklink) {
      if (_dirty && _items != null) return _items!;
      if (_backlinkResolver != null) {
        return _backlinkResolver!();
      }
      return _items ??= [];
    }
    if (_items != null) return _items!;
    if (_store == null) return _items ??= [];
    final box = _store!._boxOrNull<T>();
    if (box == null) return _items ??= [];
    final resolved = <T>[];
    for (final id in _targetIds) {
      final item = box.get(id);
      if (item != null) resolved.add(item);
    }
    _items = resolved;
    return resolved;
  }

  void applyToDb() {
    if (_store == null) return;
    if (_isBacklink) {
      _flushBacklinkPending();
      return;
    }
    if (_items != null) {
      _syncStandaloneIdsFromItems(autoPut: true);
    }
    _dirty = false;
    _standaloneApplier?.call();
  }

  @override
  int get length => _ensureResolved().length;

  @override
  set length(int newLength) {
    final list = List<T>.from(_ensureResolved());
    if (newLength < list.length) {
      for (int i = newLength; i < list.length; i++) {
        _markRemoved(list[i]);
      }
    }
    list.length = newLength;
    _items = list;
    _dirty = true;
  }

  @override
  T operator [](int index) => _ensureResolved()[index];

  @override
  void operator []=(int index, T value) {
    final list = List<T>.from(_ensureResolved());
    final old = list[index];
    if (!identical(old, value)) {
      _markRemoved(old);
      _markAdded(value);
    }
    list[index] = value;
    _items = list;
    _dirty = true;
  }

  @override
  void add(T element) {
    final list = _isBacklink ? List<T>.from(_ensureResolved()) : _ensureResolved();
    list.add(element);
    _items = list;
    _dirty = true;
    _markAdded(element);
  }

  @override
  void addAll(Iterable<T> iterable) {
    final list = _isBacklink ? List<T>.from(_ensureResolved()) : _ensureResolved();
    for (final element in iterable) {
      list.add(element);
      _markAdded(element);
    }
    _items = list;
    _dirty = true;
  }

  @override
  bool remove(Object? element) {
    final list = _isBacklink ? List<T>.from(_ensureResolved()) : _ensureResolved();
    final removed = list.remove(element);
    if (removed && element is T) {
      _items = list;
      _dirty = true;
      _markRemoved(element);
    }
    return removed;
  }

  @override
  void clear() {
    final list = _ensureResolved();
    for (final item in list) {
      _markRemoved(item);
    }
    _items = <T>[];
    _dirty = true;
  }

  void _markAdded(T item) {
    if (_isBacklink) {
      _pendingRemove.remove(item);
      if (!_pendingAdd.contains(item)) _pendingAdd.add(item);
    }
  }

  void _markRemoved(T item) {
    if (_isBacklink) {
      _pendingAdd.remove(item);
      if (!_pendingRemove.contains(item)) _pendingRemove.add(item);
    }
  }
}

int? _extractEntityId(dynamic entity) {
  if (entity is Attachment) return entity.id;
  if (entity is Chat) return entity.id;
  if (entity is Message) return entity.id;
  if (entity is Handle) return entity.id;
  if (entity is ContactV2) return entity.id;
  if (entity is CustomGroup) return entity.id;
  if (entity is FCMData) return entity.id;
  if (entity is ThemeStruct) return entity.id;
  if (entity is ThemeEntry) return entity.id;
  if (entity is ThemeObject) return entity.id;
  return null;
}

// ============================================================================
// Box<T> & Transactional Store
// ============================================================================

class _BoxSnapshot<T> {
  final Box<T> box;
  final int nextId;
  final Map<int, Map<String, dynamic>?> previousEncoded = {};

  _BoxSnapshot(this.box, this.nextId);

  void recordBeforeMutation(int id) {
    previousEncoded.putIfAbsent(id, () => box._committedEncoded[id]);
  }

  void restore(Store store) {
    box._nextId = nextId;
    for (final entry in previousEncoded.entries) {
      final raw = entry.value;
      if (raw == null) {
        box._items.remove(entry.key);
        box._committedEncoded.remove(entry.key);
      } else {
        final restored = box._decode(raw);
        box._onAttach?.call(restored, store);
        box._items[entry.key] = restored;
        box._committedEncoded[entry.key] = raw;
      }
    }
    box._rebuildAllIndexes();
  }
}

class _Transaction {
  final Map<Type, _BoxSnapshot<dynamic>> snapshots = {};
  final List<void Function()> pendingPersistenceOps = [];
  final Set<Type> changedTypes = {};

  _BoxSnapshot<T> snapshotFor<T>(Box<T> box) {
    return snapshots.putIfAbsent(T, () => _BoxSnapshot<T>(box, box._nextId)) as _BoxSnapshot<T>;
  }
}

class Box<T> {
  final Store _store;
  final String _storeName;
  final QueryIntegerProperty<T> _idProp;
  final int? Function(T) _getId;
  final void Function(T, int) _setId;
  final QueryStringProperty<T>? _secondaryIndexProp;
  final String? Function(T)? _secondaryKey;
  final String? Function(T)? _uniqueKey;
  final Map<String, dynamic> Function(T) _encode;
  final T Function(Map<String, dynamic>) _decode;
  final void Function(T, Store)? _onAttach;
  final void Function(T, Store)? _afterPut;
  final int? Function(T)? _reverseIndexKey;

  final Map<int, T> _items = LinkedHashMap<int, T>();
  final Map<int, Map<String, dynamic>> _committedEncoded = {};
  final Map<String, int> _secondaryIndex = {};
  final Map<int, String> _secondaryKeyById = {};
  final Map<String, int> _uniqueIndex = {};
  final Map<int, String> _uniqueKeyById = {};
  final Map<int, Set<int>> _reverseIndex = {};
  final Map<int, int> _reverseKeyById = {};

  int _nextId = 1;

  Box._({
    required Store store,
    required String storeName,
    required QueryIntegerProperty<T> idProp,
    required int? Function(T) getId,
    required void Function(T, int) setId,
    required Map<String, dynamic> Function(T) encode,
    required T Function(Map<String, dynamic>) decode,
    QueryStringProperty<T>? secondaryIndexProp,
    String? Function(T)? secondaryKey,
    String? Function(T)? uniqueKey,
    void Function(T, Store)? onAttach,
    void Function(T, Store)? afterPut,
    int? Function(T)? reverseIndexKey,
  })  : _store = store,
        _storeName = storeName,
        _idProp = idProp,
        _getId = getId,
        _setId = setId,
        _secondaryIndexProp = secondaryIndexProp,
        _secondaryKey = secondaryKey,
        _uniqueKey = uniqueKey,
        _encode = encode,
        _decode = decode,
        _onAttach = onAttach,
        _afterPut = afterPut,
        _reverseIndexKey = reverseIndexKey;

  int? _idOf(T entity) => _getId(entity);

  List<T> _byReverseKey(int? key) {
    if (key == null || key <= 0) return const [];
    final ids = _reverseIndex[key];
    if (ids == null || ids.isEmpty) return const [];
    return ids.map(get).whereType<T>().toList();
  }

  void _hydrateFromRecords(List<Map<String, dynamic>> records) {
    int maxId = 0;
    for (final raw in records) {
      final entity = _decode(raw);
      final id = _getId(entity);
      if (id == null || id <= 0) continue;
      if (id > maxId) maxId = id;
      _onAttach?.call(entity, _store);
      _items[id] = entity;
      _committedEncoded[id] = raw;
      _indexInsert(id, entity);
    }
    _nextId = maxId + 1;
  }

  void _clearInMemoryOnly() {
    _items.clear();
    _committedEncoded.clear();
    _secondaryIndex.clear();
    _secondaryKeyById.clear();
    _uniqueIndex.clear();
    _uniqueKeyById.clear();
    _reverseIndex.clear();
    _reverseKeyById.clear();
    _nextId = 1;
  }

  void _indexInsert(int id, T entity) {
    final sec = _secondaryKey?.call(entity);
    if (sec != null && sec.isNotEmpty) {
      _secondaryIndex[sec] = id;
      _secondaryKeyById[id] = sec;
    }
    final uniq = _uniqueKey?.call(entity);
    if (uniq != null && uniq.isNotEmpty) {
      _uniqueIndex[uniq] = id;
      _uniqueKeyById[id] = uniq;
    }
    final rev = _reverseIndexKey?.call(entity);
    if (rev != null && rev > 0) {
      (_reverseIndex[rev] ??= <int>{}).add(id);
      _reverseKeyById[id] = rev;
    }
  }

  void _indexRemove(int id, T entity) {
    final sec = _secondaryKeyById.remove(id) ?? _secondaryKey?.call(entity);
    if (sec != null && _secondaryIndex[sec] == id) {
      _secondaryIndex.remove(sec);
    }
    final uniq = _uniqueKeyById.remove(id) ?? _uniqueKey?.call(entity);
    if (uniq != null && _uniqueIndex[uniq] == id) {
      _uniqueIndex.remove(uniq);
    }
    final rev = _reverseKeyById.remove(id) ?? _reverseIndexKey?.call(entity);
    if (rev != null && rev > 0) {
      _reverseIndex[rev]?.remove(id);
    }
  }

  void _rebuildAllIndexes() {
    _secondaryIndex.clear();
    _secondaryKeyById.clear();
    _uniqueIndex.clear();
    _uniqueKeyById.clear();
    _reverseIndex.clear();
    _reverseKeyById.clear();
    for (final entry in _items.entries) {
      _indexInsert(entry.key, entry.value);
    }
  }

  T? get(int id) => _items[id];

  List<T?> getMany(List<int> ids, {bool growableResult = false}) {
    final list = ids.map((id) => _items[id]).toList(growable: growableResult);
    return list;
  }

  List<T> getAll() => _items.values.toList();

  int count({int limit = 0}) {
    final len = _items.length;
    if (limit > 0 && len > limit) return limit;
    return len;
  }

  bool isEmpty() => _items.isEmpty;

  bool contains(int id) => _items.containsKey(id);

  int put(T object, {PutMode mode = PutMode.put}) {
    final id = _putSingle(object, mode: mode);
    _store._emitChangesIfOutsideTx([T]);
    return id;
  }

  List<int> putMany(List<T> objects, {PutMode mode = PutMode.put}) {
    if (objects.isEmpty) return const [];
    final ids = <int>[];
    for (final obj in objects) {
      ids.add(_putSingle(obj, mode: mode));
    }
    _store._emitChangesIfOutsideTx([T]);
    return ids;
  }

  /// If [object] has no ID but matches an existing row's unique key, stamps that ID onto [object].
  int? _stampExistingUniqueId(T object) {
    final currentId = _getId(object);
    if (currentId != null && currentId > 0) return currentId;
    final uniq = _uniqueKey?.call(object);
    if (uniq == null || uniq.isEmpty) return null;
    final existingId = _uniqueIndex[uniq];
    if (existingId != null) {
      _setId(object, existingId);
    }
    return existingId;
  }

  int _resolveUniqueOrPut(T object) => _stampExistingUniqueId(object) ?? put(object);

  int _putSingle(T object, {PutMode mode = PutMode.put}) {
    int? existingId = _getId(object);
    final isNew = existingId == null || existingId <= 0;

    if (mode == PutMode.update) {
      if (isNew || !_items.containsKey(existingId)) {
        throw ObjectBoxException('PutMode.update failed: entity id $existingId does not exist in $_storeName');
      }
    } else if (mode == PutMode.insert) {
      if (!isNew && _items.containsKey(existingId)) {
        throw UniqueViolationException('Duplicate primary key $existingId in $_storeName');
      }
    }

    final int targetId = isNew ? _nextId : existingId;
    final uniq = _uniqueKey?.call(object);
    if (uniq != null && uniq.isNotEmpty) {
      final conflictId = _uniqueIndex[uniq];
      if (conflictId != null && conflictId != targetId) {
        throw UniqueViolationException('Unique constraint failed for "$uniq" in $_storeName');
      }
    }

    final tx = _store._activeTx;
    if (tx != null) {
      tx.snapshotFor<T>(this).recordBeforeMutation(targetId);
    }

    if (isNew) {
      _nextId = targetId + 1;
      _setId(object, targetId);
    } else if (targetId >= _nextId) {
      _nextId = targetId + 1;
    }

    final previous = _items[targetId];
    if (previous != null) {
      _indexRemove(targetId, previous);
    }

    _onAttach?.call(object, _store);
    _items[targetId] = object;
    _indexInsert(targetId, object);

    final encoded = _encode(object);
    _store._schedulePersist(() {
      _committedEncoded[targetId] = encoded;
      _store._persistence?.enqueuePut(_storeName, targetId, encoded);
    }, T);
    _afterPut?.call(object, _store);
    return targetId;
  }

  bool remove(int id) {
    final removed = _removeSingle(id);
    if (removed) _store._emitChangesIfOutsideTx([T]);
    return removed;
  }

  Future<bool> removeAsync(int id) async => remove(id);

  int removeMany(List<int> ids) {
    int count = 0;
    for (final id in ids) {
      if (_removeSingle(id)) count++;
    }
    if (count > 0) _store._emitChangesIfOutsideTx([T]);
    return count;
  }

  int removeAll() {
    final count = _items.length;
    if (count == 0) return 0;
    final tx = _store._activeTx;
    if (tx != null) {
      final snap = tx.snapshotFor<T>(this);
      for (final entry in _items.entries) {
        snap.recordBeforeMutation(entry.key);
      }
    }
    _items.clear();
    _secondaryIndex.clear();
    _secondaryKeyById.clear();
    _uniqueIndex.clear();
    _uniqueKeyById.clear();
    _reverseIndex.clear();
    _reverseKeyById.clear();
    _store._schedulePersist(() {
      _committedEncoded.clear();
      _store._persistence?.enqueueClear(_storeName);
    }, T);
    _store._emitChangesIfOutsideTx([T]);
    return count;
  }

  bool _removeSingle(int id) {
    final existing = _items[id];
    if (existing == null) return false;
    final tx = _store._activeTx;
    if (tx != null) {
      tx.snapshotFor<T>(this).recordBeforeMutation(id);
    }
    _items.remove(id);
    _indexRemove(id, existing);
    _store._schedulePersist(() {
      _committedEncoded.remove(id);
      _store._persistence?.enqueueDelete(_storeName, id);
    }, T);
    return true;
  }

  QueryBuilder<T> query([Condition<T>? qc]) => QueryBuilder<T>(this, qc);
}

class Store {
  static Store? _active;
  static Store get active {
    final s = _active;
    if (s == null) {
      throw ObjectBoxException('Web Store has not been opened yet. Call openStore() first.');
    }
    return s;
  }

  final IdbPersistence? _persistence;
  final Map<Type, Box<dynamic>> _boxes = {};
  final StreamController<List<Type>> _entityChangesController = StreamController<List<Type>>.broadcast();
  _Transaction? _activeTx;
  bool _closed = false;

  Store._(this._persistence) {
    _initBoxes();
  }

  factory Store.attach(dynamic _, String? directoryPath, {bool queriesCaseSensitiveDefault = true}) =>
      throw UnsupportedError('Store.attach is not supported on web');

  static bool isOpen(String? directoryPath) => _active != null && !_active!._closed;

  Stream<List<Type>> get _entityChanges => _entityChangesController.stream;

  void _initBoxes() {
    late final Box<Attachment> attachmentBox;
    late final Box<Chat> chatBox;
    late final Box<ContactV2> contactBox;
    late final Box<CustomGroup> customGroupBox;
    late final Box<FCMData> fcmBox;
    late final Box<Handle> handleBox;
    late final Box<Message> messageBox;
    late final Box<ThemeStruct> themeBox;
    late final Box<ThemeEntry> themeEntryBox;
    late final Box<ThemeObject> themeObjectBox;

    void initToOneBacklink<ParentT, ChildT>(
      Store s,
      ParentT parent,
      int? parentId,
      ToMany<ChildT> backlink,
      Box<ChildT> childBox,
      ToOne<ParentT> Function(ChildT) toOneOf, {
      bool stampUniqueId = false,
    }) {
      backlink._initBacklink(
        s,
        () => childBox._byReverseKey(parentId),
        (added, removed) {
          for (final child in added) {
            if (stampUniqueId) childBox._stampExistingUniqueId(child);
            toOneOf(child).target = parent;
            childBox.put(child);
          }
          for (final child in removed) {
            if (toOneOf(child).targetId == parentId) {
              toOneOf(child).target = null;
              childBox.put(child);
            }
          }
        },
      );
    }

    void initToManyBacklink<TargetT, SourceT>(
      Store s,
      TargetT target,
      int? targetId,
      ToMany<SourceT> backlink,
      Box<SourceT> sourceBox,
      ToMany<TargetT> Function(SourceT) toManyOf,
      int? Function(TargetT) idOf,
    ) {
      backlink._initBacklink(
        s,
        () => sourceBox._items.values.where((src) => toManyOf(src)._effectiveTargetIds().contains(targetId)).toList(),
        (added, removed) {
          for (final src in added) {
            if (!toManyOf(src).any((x) => idOf(x) == targetId)) {
              toManyOf(src).add(target);
              sourceBox.put(src);
            }
          }
          for (final src in removed) {
            if (toManyOf(src).remove(target)) {
              sourceBox.put(src);
            }
          }
        },
      );
    }

    attachmentBox = Box<Attachment>._(
      store: this,
      storeName: IdbPersistence.storeAttachments,
      idProp: Attachment_.id,
      getId: (a) => a.id,
      setId: (a, id) => a.id = id,
      secondaryIndexProp: Attachment_.guid,
      secondaryKey: (a) => a.guid,
      uniqueKey: (a) => a.guid,
      encode: _Codec.encodeAttachment,
      decode: _Codec.decodeAttachment,
      onAttach: (a, s) => a.message._syncBeforeOwnerPut(s),
      reverseIndexKey: (a) => a.message.targetId,
    );

    handleBox = Box<Handle>._(
      store: this,
      storeName: IdbPersistence.storeHandles,
      idProp: Handle_.id,
      getId: (h) => h.id,
      setId: (h, id) => h.id = id,
      secondaryIndexProp: Handle_.uniqueAddressAndService,
      secondaryKey: (h) => h.uniqueAddressAndService,
      uniqueKey: (h) => h.uniqueAddressAndService,
      encode: _Codec.encodeHandle,
      decode: _Codec.decodeHandle,
      onAttach: (h, s) => initToManyBacklink(s, h, h.id, h.contactsV2, contactBox, (c) => c.handles, (x) => x.id),
      afterPut: (h, _) => h.contactsV2._flushBacklinkPending(),
    );

    messageBox = Box<Message>._(
      store: this,
      storeName: IdbPersistence.storeMessages,
      idProp: Message_.id,
      getId: (m) => m.id,
      setId: (m, id) => m.id = id,
      secondaryIndexProp: Message_.guid,
      secondaryKey: (m) => m.guid,
      uniqueKey: (m) => m.guid,
      encode: _Codec.encodeMessage,
      decode: _Codec.decodeMessage,
      onAttach: (m, s) {
        m.chat._syncBeforeOwnerPut(s);
        m.handleRelation._syncBeforeOwnerPut(s);
        initToOneBacklink(s, m, m.id, m.dbAttachments, attachmentBox, (a) => a.message, stampUniqueId: true);
      },
      afterPut: (m, _) => m.dbAttachments._flushBacklinkPending(),
      reverseIndexKey: (m) => m.chat.targetId,
    );

    chatBox = Box<Chat>._(
      store: this,
      storeName: IdbPersistence.storeChats,
      idProp: Chat_.id,
      getId: (c) => c.id,
      setId: (c, id) => c.id = id,
      secondaryIndexProp: Chat_.guid,
      secondaryKey: (c) => c.guid,
      uniqueKey: (c) => c.guid,
      encode: _Codec.encodeChat,
      decode: _Codec.decodeChat,
      onAttach: (c, s) {
        c.dbLatestMessage._syncBeforeOwnerPut(s);
        c.handles._initStandalone(s, c.handles._effectiveTargetIds(), () => chatBox.put(c));
        // Auto-put unsaved target items before _encode() so persisted _targetIds include them.
        c.handles._syncStandaloneIdsFromItems(autoPut: true);
        c.handles._dirty = false;
        initToOneBacklink(s, c, c.id, c.messages, messageBox, (m) => m.chat, stampUniqueId: true);
        initToManyBacklink(s, c, c.id, c.customGroups, customGroupBox, (g) => g.chats, (x) => x.id);
      },
      afterPut: (c, s) {
        c.messages._flushBacklinkPending();
        c.customGroups._flushBacklinkPending();
      },
    );

    contactBox = Box<ContactV2>._(
      store: this,
      storeName: IdbPersistence.storeContactsV2,
      idProp: ContactV2_.id,
      getId: (c) => c.id,
      setId: (c, id) => c.id = id,
      secondaryIndexProp: ContactV2_.nativeContactId,
      secondaryKey: (c) => c.nativeContactId,
      uniqueKey: (c) => c.nativeContactId,
      encode: _Codec.encodeContactV2,
      decode: _Codec.decodeContactV2,
      onAttach: (c, s) {
        c.handles._initStandalone(s, c.handles._effectiveTargetIds(), () => contactBox.put(c));
        c.handles._syncStandaloneIdsFromItems(autoPut: true);
        c.handles._dirty = false;
      },
    );

    customGroupBox = Box<CustomGroup>._(
      store: this,
      storeName: IdbPersistence.storeCustomGroups,
      idProp: CustomGroup_.id,
      getId: (g) => g.id,
      setId: (g, id) => g.id = id,
      secondaryIndexProp: CustomGroup_.name,
      secondaryKey: (g) => g.name,
      uniqueKey: (g) => g.name,
      encode: _Codec.encodeCustomGroup,
      decode: _Codec.decodeCustomGroup,
      onAttach: (g, s) {
        g.chats._initStandalone(s, g.chats._effectiveTargetIds(), () => customGroupBox.put(g));
        g.chats._syncStandaloneIdsFromItems(autoPut: true);
        g.chats._dirty = false;
      },
    );

    fcmBox = Box<FCMData>._(
      store: this,
      storeName: IdbPersistence.storeFcmData,
      idProp: FCMData_.id,
      getId: (f) => f.id,
      setId: (f, id) => f.id = id,
      encode: _Codec.encodeFCMData,
      decode: _Codec.decodeFCMData,
    );

    themeBox = Box<ThemeStruct>._(
      store: this,
      storeName: IdbPersistence.storeThemes,
      idProp: ThemeStruct_.id,
      getId: (t) => t.id,
      setId: (t, id) => t.id = id,
      secondaryIndexProp: ThemeStruct_.name,
      secondaryKey: (t) => t.name,
      uniqueKey: (t) => t.name,
      encode: _Codec.encodeThemeStruct,
      decode: _Codec.decodeThemeStruct,
    );

    themeEntryBox = Box<ThemeEntry>._(
      store: this,
      storeName: IdbPersistence.storeThemeEntries,
      idProp: ThemeEntry_.id,
      getId: (e) => e.id,
      setId: (e, id) => e.id = id,
      encode: _Codec.encodeThemeEntry,
      decode: _Codec.decodeThemeEntry,
      onAttach: (e, s) => e.themeObject._syncBeforeOwnerPut(s),
      reverseIndexKey: (e) => e.themeObject.targetId,
    );

    themeObjectBox = Box<ThemeObject>._(
      store: this,
      storeName: IdbPersistence.storeThemeObjects,
      idProp: ThemeObject_.id,
      getId: (o) => o.id,
      setId: (o, id) => o.id = id,
      secondaryIndexProp: ThemeObject_.name,
      secondaryKey: (o) => o.name,
      uniqueKey: (o) => o.name,
      encode: _Codec.encodeThemeObject,
      decode: _Codec.decodeThemeObject,
      onAttach: (o, s) => initToOneBacklink(s, o, o.id, o.themeEntries, themeEntryBox, (e) => e.themeObject),
      afterPut: (o, _) => o.themeEntries._flushBacklinkPending(),
    );

    _boxes[Attachment] = attachmentBox;
    _boxes[Chat] = chatBox;
    _boxes[ContactV2] = contactBox;
    _boxes[CustomGroup] = customGroupBox;
    _boxes[FCMData] = fcmBox;
    _boxes[Handle] = handleBox;
    _boxes[Message] = messageBox;
    _boxes[ThemeStruct] = themeBox;
    _boxes[ThemeEntry] = themeEntryBox;
    _boxes[ThemeObject] = themeObjectBox;
  }

  Future<void> _hydrate() async {
    final persistence = _persistence;
    if (persistence == null) return;
    final sw = Stopwatch()..start();
    final stores = await persistence.loadAllStores();

    // shortcut: full hydration up to 50k messages (~40-80MB RAM); upgrade to windowed message hydration if startup exceeds 500ms.
    box<Attachment>()._hydrateFromRecords(stores[IdbPersistence.storeAttachments] ?? const []);
    box<Handle>()._hydrateFromRecords(stores[IdbPersistence.storeHandles] ?? const []);
    box<Message>()._hydrateFromRecords(stores[IdbPersistence.storeMessages] ?? const []);
    box<Chat>()._hydrateFromRecords(stores[IdbPersistence.storeChats] ?? const []);
    box<ContactV2>()._hydrateFromRecords(stores[IdbPersistence.storeContactsV2] ?? const []);
    box<CustomGroup>()._hydrateFromRecords(stores[IdbPersistence.storeCustomGroups] ?? const []);
    box<FCMData>()._hydrateFromRecords(stores[IdbPersistence.storeFcmData] ?? const []);
    box<ThemeStruct>()._hydrateFromRecords(stores[IdbPersistence.storeThemes] ?? const []);
    box<ThemeEntry>()._hydrateFromRecords(stores[IdbPersistence.storeThemeEntries] ?? const []);
    box<ThemeObject>()._hydrateFromRecords(stores[IdbPersistence.storeThemeObjects] ?? const []);
    sw.stop();

    final msgCount = box<Message>().count();
    if (msgCount > 50000 || sw.elapsedMilliseconds > 500) {
      Logger.info('IDB hydrated $msgCount messages in ${sw.elapsedMilliseconds}ms', tag: 'WebDB');
    }
  }

  void clearInMemory() {
    for (final b in _boxes.values) {
      b._clearInMemoryOnly();
    }
    if (!_entityChangesController.isClosed) {
      _entityChangesController.add(_boxes.keys.toList(growable: false));
    }
  }

  Box<T>? _boxOrNull<T>() => _boxes[T] as Box<T>?;

  Box<T> box<T>() {
    final b = _boxOrNull<T>();
    if (b == null) throw ObjectBoxException('Unknown entity type $T');
    return b;
  }

  void _schedulePersist(void Function() op, Type changedType) {
    final tx = _activeTx;
    if (tx != null) {
      tx.pendingPersistenceOps.add(op);
      tx.changedTypes.add(changedType);
    } else {
      op();
    }
  }

  void _emitChangesIfOutsideTx(List<Type> types) {
    if (_activeTx != null || _closed || _entityChangesController.isClosed) return;
    _entityChangesController.add(types);
  }

  R runInTransaction<R>(TxMode mode, R Function() fn) {
    if (mode == TxMode.read || _activeTx != null) {
      return fn();
    }
    final tx = _Transaction();
    _activeTx = tx;
    try {
      final result = fn();
      _activeTx = null;
      for (final op in tx.pendingPersistenceOps) {
        op();
      }
      if (tx.changedTypes.isNotEmpty && !_closed && !_entityChangesController.isClosed) {
        _entityChangesController.add(tx.changedTypes.toList(growable: false));
      }
      return result;
    } catch (e) {
      _activeTx = null;
      for (final snap in tx.snapshots.values) {
        snap.restore(this);
      }
      rethrow;
    }
  }

  Future<void> flush() async {
    await _persistence?.flush();
  }

  Future<void> clearPersistence() async {
    clearInMemory();
    await _persistence?.clearAll();
  }

  Future<void> close({bool flushPending = true}) async {
    if (_closed) return;
    _closed = true;
    if (identical(_active, this)) {
      _active = null;
      IdbPersistence.onClearAllInMemory = null;
    }
    await _persistence?.close(flushPending: flushPending);
    if (!_entityChangesController.isClosed) {
      await _entityChangesController.close();
    }
  }
}

class HtmlDatabase {
  static Store get store => Store.active;
  static Box<Attachment> get attachments => store.box<Attachment>();
  static Box<Chat> get chats => store.box<Chat>();
  static Box<ContactV2> get contactsV2 => store.box<ContactV2>();
  static Box<CustomGroup> get customGroups => store.box<CustomGroup>();
  static Box<FCMData> get fcmData => store.box<FCMData>();
  static Box<Handle> get handles => store.box<Handle>();
  static Box<Message> get messages => store.box<Message>();
  static Box<ThemeStruct> get themes => store.box<ThemeStruct>();
  static Box<ThemeEntry> get themeEntries => store.box<ThemeEntry>();
  static Box<ThemeObject> get themeObjects => store.box<ThemeObject>();

  static R runInTransaction<R>(TxMode mode, R Function() fn) => store.runInTransaction(mode, fn);
}

Future<Store> openStore({
  String? directory,
  IdbFactory? idbFactory,
  String dbName = IdbPersistence.dbName,
  bool registerAsActive = true,
}) async {
  IdbPersistence? persistence;
  try {
    persistence = await IdbPersistence.open(
      factory: idbFactory,
      dbName: dbName,
      registerAsActive: registerAsActive,
    );
    final store = Store._(persistence);
    if (registerAsActive) {
      Store._active = store;
      IdbPersistence.onClearAllInMemory = store.clearInMemory;
    }
    await store._hydrate();
    return store;
  } catch (e, s) {
    if (persistence != null) {
      try {
        await persistence.close(flushPending: false);
      } catch (_) {}
    }
    Logger.error("Failed to open web ObjectBox IDB store, falling back to in-memory store", error: e, trace: s);
    final store = createInMemoryStore();
    if (registerAsActive) {
      Store._active = store;
      IdbPersistence.onClearAllInMemory = store.clearInMemory;
    }
    return store;
  }
}

Store createInMemoryStore() => Store._(null);

// ============================================================================
// Entity_ Query Descriptors
// ============================================================================

class Attachment_ {
  static final id = QueryIntegerProperty<Attachment>('id', (e) => e.id);
  static final originalROWID = QueryIntegerProperty<Attachment>('originalROWID', (e) => e.originalROWID);
  static final guid = QueryStringProperty<Attachment>('guid', (e) => e.guid);
  static final uti = QueryStringProperty<Attachment>('uti', (e) => e.uti);
  static final mimeType = QueryStringProperty<Attachment>('mimeType', (e) => e.mimeType);
  static final isOutgoing = QueryBooleanProperty<Attachment>('isOutgoing', (e) => e.isOutgoing);
  static final transferName = QueryStringProperty<Attachment>('transferName', (e) => e.transferName);
  static final totalBytes = QueryIntegerProperty<Attachment>('totalBytes', (e) => e.totalBytes);
  static final height = QueryIntegerProperty<Attachment>('height', (e) => e.height);
  static final width = QueryIntegerProperty<Attachment>('width', (e) => e.width);
  static final webUrl = QueryStringProperty<Attachment>('webUrl', (e) => e.webUrl);
  static final message = QueryRelationToOne<Attachment, Message>('message', (e) => e.message);
  static final dbMetadata = QueryStringProperty<Attachment>('dbMetadata', (e) => e.dbMetadata);
  static final hasLivePhoto = QueryBooleanProperty<Attachment>('hasLivePhoto', (e) => e.hasLivePhoto);
  static final isDownloaded = QueryBooleanProperty<Attachment>('isDownloaded', (e) => e.isDownloaded);
}

class Chat_ {
  static final id = QueryIntegerProperty<Chat>('id', (e) => e.id);
  static final guid = QueryStringProperty<Chat>('guid', (e) => e.guid);
  static final chatIdentifier = QueryStringProperty<Chat>('chatIdentifier', (e) => e.chatIdentifier);
  static final isArchived = QueryBooleanProperty<Chat>('isArchived', (e) => e.isArchived);
  static final muteType = QueryStringProperty<Chat>('muteType', (e) => e.muteType);
  static final muteArgs = QueryStringProperty<Chat>('muteArgs', (e) => e.muteArgs);
  static final isPinned = QueryBooleanProperty<Chat>('isPinned', (e) => e.isPinned);
  static final hasUnreadMessage = QueryBooleanProperty<Chat>('hasUnreadMessage', (e) => e.hasUnreadMessage);
  static final dbOnlyLatestMessageDate =
      QueryDateProperty<Chat>('dbOnlyLatestMessageDate', (e) => e.dbOnlyLatestMessageDate?.millisecondsSinceEpoch);
  static final displayName = QueryStringProperty<Chat>('displayName', (e) => e.displayName);
  static final customAvatarPath = QueryStringProperty<Chat>('customAvatarPath', (e) => e.customAvatarPath);
  static final pinIndex = QueryIntegerProperty<Chat>('pinIndex', (e) => e.pinIndex);
  static final autoSendReadReceipts = QueryBooleanProperty<Chat>('autoSendReadReceipts', (e) => e.autoSendReadReceipts);
  static final autoSendTypingIndicators =
      QueryBooleanProperty<Chat>('autoSendTypingIndicators', (e) => e.autoSendTypingIndicators);
  static final textFieldText = QueryStringProperty<Chat>('textFieldText', (e) => e.textFieldText);
  static final textFieldAttachments =
      QueryStringVectorProperty<Chat>('textFieldAttachments', (e) => e.textFieldAttachments);
  static final dateDeleted = QueryDateProperty<Chat>('dateDeleted', (e) => e.dateDeleted?.millisecondsSinceEpoch);
  static final style = QueryIntegerProperty<Chat>('style', (e) => e.style);
  static final lockChatName = QueryBooleanProperty<Chat>('lockChatName', (e) => e.lockChatName);
  static final lockChatIcon = QueryBooleanProperty<Chat>('lockChatIcon', (e) => e.lockChatIcon);
  static final lastReadMessageGuid = QueryStringProperty<Chat>('lastReadMessageGuid', (e) => e.lastReadMessageGuid);
  static final customBackgroundPath = QueryStringProperty<Chat>('customBackgroundPath', (e) => e.customBackgroundPath);
  static final dbLatestMessage = QueryRelationToOne<Chat, Message>('dbLatestMessage', (e) => e.dbLatestMessage);
  static final customThemeLight = QueryStringProperty<Chat>('customThemeLight', (e) => e.customThemeLight);
  static final customThemeDark = QueryStringProperty<Chat>('customThemeDark', (e) => e.customThemeDark);
  static final wallpaperType = QueryStringProperty<Chat>('wallpaperType', (e) => e.wallpaperType);
  static final dynamicWallpaperId = QueryStringProperty<Chat>('dynamicWallpaperId', (e) => e.dynamicWallpaperId);
  static final dynamicWallpaperConfig =
      QueryStringProperty<Chat>('dynamicWallpaperConfig', (e) => e.dynamicWallpaperConfig);
  static final knownGroupPhotoGuid = QueryStringProperty<Chat>('knownGroupPhotoGuid', (e) => e.knownGroupPhotoGuid);
  static final textFieldRuns = QueryStringProperty<Chat>('textFieldRuns', (e) => e.textFieldRuns);
  static final serviceName = QueryStringProperty<Chat>('serviceName', (e) => e.serviceName);
  static final handles = QueryRelationToMany<Chat, Handle>('handles', (e) => e.handles);
  static final messages = QueryBacklinkToMany<Message, Chat>(Message_.chat);
}

class FCMData_ {
  static final id = QueryIntegerProperty<FCMData>('id', (e) => e.id);
  static final projectID = QueryStringProperty<FCMData>('projectID', (e) => e.projectID);
  static final storageBucket = QueryStringProperty<FCMData>('storageBucket', (e) => e.storageBucket);
  static final apiKey = QueryStringProperty<FCMData>('apiKey', (e) => e.apiKey);
  static final firebaseURL = QueryStringProperty<FCMData>('firebaseURL', (e) => e.firebaseURL);
  static final clientID = QueryStringProperty<FCMData>('clientID', (e) => e.clientID);
  static final applicationID = QueryStringProperty<FCMData>('applicationID', (e) => e.applicationID);
}

class Handle_ {
  static final id = QueryIntegerProperty<Handle>('id', (e) => e.id);
  static final originalROWID = QueryIntegerProperty<Handle>('originalROWID', (e) => e.originalROWID);
  static final address = QueryStringProperty<Handle>('address', (e) => e.address);
  static final country = QueryStringProperty<Handle>('country', (e) => e.country);
  static final color = QueryStringProperty<Handle>('color', (e) => e.color);
  static final defaultPhone = QueryStringProperty<Handle>('defaultPhone', (e) => e.defaultPhone);
  static final defaultEmail = QueryStringProperty<Handle>('defaultEmail', (e) => e.defaultEmail);
  static final formattedAddress = QueryStringProperty<Handle>('formattedAddress', (e) => e.formattedAddress);
  static final uniqueAddressAndService =
      QueryStringProperty<Handle>('uniqueAddressAndService', (e) => e.uniqueAddressAndService);
  static final service = QueryStringProperty<Handle>('service', (e) => e.service);
}

class ThemeEntry_ {
  static final id = QueryIntegerProperty<ThemeEntry>('id', (e) => e.id);
  static final themeId = QueryIntegerProperty<ThemeEntry>('themeId', (e) => e.themeId);
  static final name = QueryStringProperty<ThemeEntry>('name', (e) => e.name);
  static final isFont = QueryBooleanProperty<ThemeEntry>('isFont', (e) => e.isFont);
  static final fontSize = QueryIntegerProperty<ThemeEntry>('fontSize', (e) => e.fontSize);
  static final dbColor = QueryStringProperty<ThemeEntry>('dbColor', (e) => e.dbColor);
  static final fontWeight = QueryIntegerProperty<ThemeEntry>('fontWeight', (e) => e.fontWeight);
  static final themeObject = QueryRelationToOne<ThemeEntry, ThemeObject>('themeObject', (e) => e.themeObject);
}

class Message_ {
  static final id = QueryIntegerProperty<Message>('id', (e) => e.id);
  static final originalROWID = QueryIntegerProperty<Message>('originalROWID', (e) => e.originalROWID);
  static final guid = QueryStringProperty<Message>('guid', (e) => e.guid);
  static final handleId = QueryIntegerProperty<Message>('handleId', (e) => e.handleId);
  static final otherHandle = QueryIntegerProperty<Message>('otherHandle', (e) => e.otherHandle);
  static final text = QueryStringProperty<Message>('text', (e) => e.text);
  static final subject = QueryStringProperty<Message>('subject', (e) => e.subject);
  static final country = QueryStringProperty<Message>('country', (e) => e.country);
  static final dateCreated = QueryDateProperty<Message>('dateCreated', (e) => e.dateCreated?.millisecondsSinceEpoch);
  static final dateRead = QueryDateProperty<Message>('dateRead', (e) => e.dateRead?.millisecondsSinceEpoch);
  static final dateDelivered =
      QueryDateProperty<Message>('dateDelivered', (e) => e.dateDelivered?.millisecondsSinceEpoch);
  static final isFromMe = QueryBooleanProperty<Message>('isFromMe', (e) => e.isFromMe);
  static final hasDdResults = QueryBooleanProperty<Message>('hasDdResults', (e) => e.hasDdResults);
  static final datePlayed = QueryDateProperty<Message>('datePlayed', (e) => e.datePlayed?.millisecondsSinceEpoch);
  static final itemType = QueryIntegerProperty<Message>('itemType', (e) => e.itemType);
  static final groupTitle = QueryStringProperty<Message>('groupTitle', (e) => e.groupTitle);
  static final groupActionType = QueryIntegerProperty<Message>('groupActionType', (e) => e.groupActionType);
  static final balloonBundleId = QueryStringProperty<Message>('balloonBundleId', (e) => e.balloonBundleId);
  static final associatedMessageGuid =
      QueryStringProperty<Message>('associatedMessageGuid', (e) => e.associatedMessageGuid);
  static final associatedMessageType =
      QueryStringProperty<Message>('associatedMessageType', (e) => e.associatedMessageType);
  static final expressiveSendStyleId =
      QueryStringProperty<Message>('expressiveSendStyleId', (e) => e.expressiveSendStyleId);
  static final hasAttachments = QueryBooleanProperty<Message>('hasAttachments', (e) => e.hasAttachments);
  static final hasReactions = QueryBooleanProperty<Message>('hasReactions', (e) => e.hasReactions);
  static final dateDeleted = QueryDateProperty<Message>('dateDeleted', (e) => e.dateDeleted?.millisecondsSinceEpoch);
  static final threadOriginatorGuid =
      QueryStringProperty<Message>('threadOriginatorGuid', (e) => e.threadOriginatorGuid);
  static final threadOriginatorPart =
      QueryStringProperty<Message>('threadOriginatorPart', (e) => e.threadOriginatorPart);
  static final bigEmoji = QueryBooleanProperty<Message>('bigEmoji', (e) => e.bigEmoji);
  static final error = QueryIntegerProperty<Message>('error', (e) => e.error);
  static final chat = QueryRelationToOne<Message, Chat>('chat', (e) => e.chat);
  static final dbAttributedBody = QueryStringProperty<Message>('dbAttributedBody', (e) => e.dbAttributedBody);
  static final associatedMessagePart =
      QueryIntegerProperty<Message>('associatedMessagePart', (e) => e.associatedMessagePart);
  static final hasApplePayloadData =
      QueryBooleanProperty<Message>('hasApplePayloadData', (e) => e.hasApplePayloadData);
  static final dateEdited = QueryDateProperty<Message>('dateEdited', (e) => e.dateEdited?.millisecondsSinceEpoch);
  static final dbMessageSummaryInfo =
      QueryStringProperty<Message>('dbMessageSummaryInfo', (e) => e.dbMessageSummaryInfo);
  static final dbPayloadData = QueryStringProperty<Message>('dbPayloadData', (e) => e.dbPayloadData);
  static final dbMetadata = QueryStringProperty<Message>('dbMetadata', (e) => e.dbMetadata);
  static final wasDeliveredQuietly =
      QueryBooleanProperty<Message>('wasDeliveredQuietly', (e) => e.wasDeliveredQuietly);
  static final didNotifyRecipient = QueryBooleanProperty<Message>('didNotifyRecipient', (e) => e.didNotifyRecipient);
  static final isBookmarked = QueryBooleanProperty<Message>('isBookmarked', (e) => e.isBookmarked);
  static final isDelivered = QueryBooleanProperty<Message>('isDelivered', (e) => e.isDelivered);
  static final handleRelation = QueryRelationToOne<Message, Handle>('handleRelation', (e) => e.handleRelation);
  static final errorMessage = QueryStringProperty<Message>('errorMessage', (e) => e.errorMessage);
  static final hasEffectPlayed = QueryBooleanProperty<Message>('hasEffectPlayed', (e) => e.hasEffectPlayed);
  static final associatedMessageEmoji =
      QueryStringProperty<Message>('associatedMessageEmoji', (e) => e.associatedMessageEmoji);
  static final service = QueryStringProperty<Message>('service', (e) => e.service);
  static final dbAttachments = QueryBacklinkToMany<Attachment, Message>(Attachment_.message);
}

class ThemeObject_ {
  static final id = QueryIntegerProperty<ThemeObject>('id', (e) => e.id);
  static final name = QueryStringProperty<ThemeObject>('name', (e) => e.name);
  static final selectedLightTheme = QueryBooleanProperty<ThemeObject>('selectedLightTheme', (e) => e.selectedLightTheme);
  static final selectedDarkTheme = QueryBooleanProperty<ThemeObject>('selectedDarkTheme', (e) => e.selectedDarkTheme);
  static final gradientBg = QueryBooleanProperty<ThemeObject>('gradientBg', (e) => e.gradientBg);
  static final previousLightTheme = QueryBooleanProperty<ThemeObject>('previousLightTheme', (e) => e.previousLightTheme);
  static final previousDarkTheme = QueryBooleanProperty<ThemeObject>('previousDarkTheme', (e) => e.previousDarkTheme);
  static final themeEntries = QueryBacklinkToMany<ThemeEntry, ThemeObject>(ThemeEntry_.themeObject);
}

class ThemeStruct_ {
  static final id = QueryIntegerProperty<ThemeStruct>('id', (e) => e.id);
  static final name = QueryStringProperty<ThemeStruct>('name', (e) => e.name);
  static final gradientBg = QueryBooleanProperty<ThemeStruct>('gradientBg', (e) => e.gradientBg);
  static final dbThemeData = QueryStringProperty<ThemeStruct>('dbThemeData', (e) => e.dbThemeData);
  static final googleFont = QueryStringProperty<ThemeStruct>('googleFont', (e) => e.googleFont);
}

class ContactV2_ {
  static final id = QueryIntegerProperty<ContactV2>('id', (e) => e.id);
  static final displayName = QueryStringProperty<ContactV2>('displayName', (e) => e.displayName);
  static final nativeContactId = QueryStringProperty<ContactV2>('nativeContactId', (e) => e.nativeContactId);
  static final avatarPath = QueryStringProperty<ContactV2>('avatarPath', (e) => e.avatarPath);
  static final addresses = QueryStringVectorProperty<ContactV2>('addresses', (e) => e.addresses);
  static final nickname = QueryStringProperty<ContactV2>('nickname', (e) => e.nickname);
  static final firstName = QueryStringProperty<ContactV2>('firstName', (e) => e.firstName);
  static final lastName = QueryStringProperty<ContactV2>('lastName', (e) => e.lastName);
  static final middleName = QueryStringProperty<ContactV2>('middleName', (e) => e.middleName);
  static final namePrefix = QueryStringProperty<ContactV2>('namePrefix', (e) => e.namePrefix);
  static final nameSuffix = QueryStringProperty<ContactV2>('nameSuffix', (e) => e.nameSuffix);
  static final company = QueryStringProperty<ContactV2>('company', (e) => e.company);
  static final dbPhoneNumbers = QueryStringProperty<ContactV2>('dbPhoneNumbers', (e) => e.dbPhoneNumbers);
  static final dbEmailAddresses = QueryStringProperty<ContactV2>('dbEmailAddresses', (e) => e.dbEmailAddresses);
  static final isNative = QueryBooleanProperty<ContactV2>('isNative', (e) => e.isNative);
  static final handles = QueryRelationToMany<ContactV2, Handle>('handles', (e) => e.handles);
}

class CustomGroup_ {
  static final id = QueryIntegerProperty<CustomGroup>('id', (e) => e.id);
  static final name = QueryStringProperty<CustomGroup>('name', (e) => e.name);
  static final sortOrder = QueryIntegerProperty<CustomGroup>('sortOrder', (e) => e.sortOrder);
  static final showUnreadBadge = QueryBooleanProperty<CustomGroup>('showUnreadBadge', (e) => e.showUnreadBadge);
  static final chats = QueryRelationToMany<CustomGroup, Chat>('chats', (e) => e.chats);
}

// ============================================================================
// Lossless IDB Record Codecs (all 10 entities)
// ============================================================================

class _Codec {
  static DateTime? _dt(dynamic v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
  static int? _ms(DateTime? d) => d?.millisecondsSinceEpoch;
  static List<int> _intList(dynamic v) => v is List ? v.whereType<int>().toList() : const [];
  static List<String> _strList(dynamic v) => v is List ? v.map((e) => e.toString()).toList() : <String>[];

  static Map<String, dynamic> encodeAttachment(Attachment a) => {
        'id': a.id,
        'originalROWID': a.originalROWID,
        'guid': a.guid,
        'uti': a.uti,
        'mimeType': a.mimeType,
        'isOutgoing': a.isOutgoing,
        'transferName': a.transferName,
        'totalBytes': a.totalBytes,
        'height': a.height,
        'width': a.width,
        'dbMetadata': a.dbMetadata,
        'stickerPlacement': a.stickerPlacement == null ? null : jsonEncode(a.stickerPlacement),
        'originalGuid': a.originalGuid,
        'exif': a.exif == null ? null : jsonEncode(a.exif),
        'webUrl': a.webUrl,
        'hasLivePhoto': a.hasLivePhoto,
        'isDownloaded': a.isDownloaded,
        'messageId': a.message.targetId,
      };

  static Attachment decodeAttachment(Map<String, dynamic> m) {
    final a = Attachment(
      id: m['id'] as int?,
      originalROWID: m['originalROWID'] as int?,
      guid: m['guid'] as String?,
      uti: m['uti'] as String?,
      mimeType: m['mimeType'] as String?,
      isOutgoing: m['isOutgoing'] as bool?,
      transferName: m['transferName'] as String?,
      totalBytes: m['totalBytes'] as int?,
      height: m['height'] as int?,
      width: m['width'] as int?,
      originalGuid: m['originalGuid'] as String?,
      webUrl: m['webUrl'] as String?,
      hasLivePhoto: m['hasLivePhoto'] as bool? ?? false,
      isDownloaded: m['isDownloaded'] as bool? ?? false,
    );
    a.dbMetadata = m['dbMetadata'] as String?;
    final spRaw = m['stickerPlacement'];
    if (spRaw is String && spRaw.isNotEmpty) {
      try {
        a.stickerPlacement = jsonDecode(spRaw) as Map<String, dynamic>;
      } catch (_) {}
    } else if (spRaw is Map) {
      a.stickerPlacement = Map<String, dynamic>.from(spRaw);
    }
    final exifRaw = m['exif'];
    if (exifRaw is String && exifRaw.isNotEmpty) {
      try {
        a.exif = jsonDecode(exifRaw) as Map<String, dynamic>;
      } catch (_) {}
    }
    a.message.targetId = m['messageId'] as int? ?? 0;
    return a;
  }

  static Map<String, dynamic> encodeChat(Chat c) => {
        'id': c.id,
        'guid': c.guid,
        'chatIdentifier': c.chatIdentifier,
        'isArchived': c.isArchived,
        'muteType': c.muteType,
        'muteArgs': c.muteArgs,
        'isPinned': c.isPinned,
        'hasUnreadMessage': c.hasUnreadMessage,
        'dbOnlyLatestMessageDate': _ms(c.dbOnlyLatestMessageDate),
        'displayName': c.displayName,
        'customAvatarPath': c.customAvatarPath,
        'pinIndex': c.pinIndex,
        'autoSendReadReceipts': c.autoSendReadReceipts,
        'autoSendTypingIndicators': c.autoSendTypingIndicators,
        'textFieldText': c.textFieldText,
        'textFieldRuns': c.textFieldRuns,
        'textFieldAttachments': List<String>.from(c.textFieldAttachments),
        'dateDeleted': _ms(c.dateDeleted),
        'style': c.style,
        'lockChatName': c.lockChatName,
        'lockChatIcon': c.lockChatIcon,
        'lastReadMessageGuid': c.lastReadMessageGuid,
        'customBackgroundPath': c.customBackgroundPath,
        'customThemeLight': c.customThemeLight,
        'customThemeDark': c.customThemeDark,
        'wallpaperType': c.wallpaperType,
        'dynamicWallpaperId': c.dynamicWallpaperId,
        'dynamicWallpaperConfig': c.dynamicWallpaperConfig,
        'knownGroupPhotoGuid': c.knownGroupPhotoGuid,
        'serverGroupPhotoGuid': c.serverGroupPhotoGuid,
        'serverBackgroundGuid': c.serverBackgroundGuid,
        'hasServerProperties': c.hasServerProperties,
        'serviceName': c.serviceName,
        'dbLatestMessageId': c.dbLatestMessage.targetId,
        'handleIds': c.handles._effectiveTargetIds(),
      };

  static Chat decodeChat(Map<String, dynamic> m) {
    final c = Chat(
      id: m['id'] as int?,
      guid: m['guid'] as String? ?? '',
      chatIdentifier: m['chatIdentifier'] as String?,
      isArchived: m['isArchived'] as bool?,
      muteType: m['muteType'] as String?,
      muteArgs: m['muteArgs'] as String?,
      isPinned: m['isPinned'] as bool?,
      hasUnreadMessage: m['hasUnreadMessage'] as bool?,
      displayName: m['displayName'] as String?,
      customAvatar: m['customAvatarPath'] as String?,
      customBackground: m['customBackgroundPath'] as String?,
      pinnedIndex: m['pinIndex'] as int?,
      autoSendReadReceipts: m['autoSendReadReceipts'] as bool?,
      autoSendTypingIndicators: m['autoSendTypingIndicators'] as bool?,
      textFieldText: m['textFieldText'] as String?,
      textFieldRuns: m['textFieldRuns'] as String?,
      textFieldAttachments: _strList(m['textFieldAttachments']),
      dateDeleted: _dt(m['dateDeleted']),
      style: m['style'] as int?,
      lockChatName: m['lockChatName'] as bool? ?? false,
      lockChatIcon: m['lockChatIcon'] as bool? ?? false,
      lastReadMessageGuid: m['lastReadMessageGuid'] as String?,
      customThemeLight: m['customThemeLight'] as String?,
      customThemeDark: m['customThemeDark'] as String?,
      wallpaperType: m['wallpaperType'] as String?,
      dynamicWallpaperId: m['dynamicWallpaperId'] as String?,
      dynamicWallpaperConfig: m['dynamicWallpaperConfig'] as String?,
      knownGroupPhotoGuid: m['knownGroupPhotoGuid'] as String?,
      serverGroupPhotoGuid: m['serverGroupPhotoGuid'] as String?,
      serverBackgroundGuid: m['serverBackgroundGuid'] as String?,
      hasServerProperties: m['hasServerProperties'] as bool? ?? false,
      serviceName: m['serviceName'] as String?,
    );
    c.dbOnlyLatestMessageDate = _dt(m['dbOnlyLatestMessageDate']);
    c.dbLatestMessage.targetId = m['dbLatestMessageId'] as int? ?? 0;
    c.handles._targetIds = _intList(m['handleIds']);
    return c;
  }

  static Map<String, dynamic> encodeMessage(Message msg) => {
        'id': msg.id,
        'originalROWID': msg.originalROWID,
        'guid': msg.guid,
        'handleId': msg.handleId,
        'otherHandle': msg.otherHandle,
        'text': msg.text,
        'subject': msg.subject,
        'country': msg.country,
        'error': msg.error,
        'errorMessage': msg.errorMessage,
        'dateCreated': _ms(msg.dateCreated),
        'dateRead': _ms(msg.dateRead),
        'dateDelivered': _ms(msg.dateDelivered),
        'isDelivered': msg.isDelivered,
        'dateEdited': _ms(msg.dateEdited),
        'isFromMe': msg.isFromMe,
        'hasDdResults': msg.hasDdResults,
        'datePlayed': _ms(msg.datePlayed),
        'hasEffectPlayed': msg.hasEffectPlayed,
        'itemType': msg.itemType,
        'groupTitle': msg.groupTitle,
        'groupActionType': msg.groupActionType,
        'balloonBundleId': msg.balloonBundleId,
        'associatedMessageGuid': msg.associatedMessageGuid,
        'associatedMessagePart': msg.associatedMessagePart,
        'associatedMessageType': msg.associatedMessageType,
        'associatedMessageEmoji': msg.associatedMessageEmoji,
        'expressiveSendStyleId': msg.expressiveSendStyleId,
        'service': msg.service,
        'hasAttachments': msg.hasAttachments,
        'hasReactions': msg.hasReactions,
        'dateDeleted': _ms(msg.dateDeleted),
        'dbMetadata': msg.dbMetadata,
        'threadOriginatorGuid': msg.threadOriginatorGuid,
        'threadOriginatorPart': msg.threadOriginatorPart,
        'bigEmoji': msg.bigEmoji,
        'dbAttributedBody': msg.dbAttributedBody,
        'dbMessageSummaryInfo': msg.dbMessageSummaryInfo,
        'dbPayloadData': msg.dbPayloadData,
        'hasApplePayloadData': msg.hasApplePayloadData,
        'wasDeliveredQuietly': msg.wasDeliveredQuietly,
        'didNotifyRecipient': msg.didNotifyRecipient,
        'isBookmarked': msg.isBookmarked,
        'chatId': msg.chat.targetId,
        'handleRelationId': msg.handleRelation.targetId,
      };

  static Message decodeMessage(Map<String, dynamic> m) {
    final msg = Message(
      id: m['id'] as int?,
      originalROWID: m['originalROWID'] as int?,
      guid: m['guid'] as String?,
      handleId: m['handleId'] as int?,
      otherHandle: m['otherHandle'] as int?,
      text: m['text'] as String?,
      subject: m['subject'] as String?,
      country: m['country'] as String?,
      error: m['error'] as int?,
      errorMessage: m['errorMessage'] as String?,
      dateCreated: _dt(m['dateCreated']),
      dateRead: _dt(m['dateRead']),
      dateDelivered: _dt(m['dateDelivered']),
      isDelievered: m['isDelivered'] as bool?,
      dateEdited: _dt(m['dateEdited']),
      isFromMe: m['isFromMe'] as bool?,
      hasDdResults: m['hasDdResults'] as bool?,
      datePlayed: _dt(m['datePlayed']),
      hasEffectPlayed: m['hasEffectPlayed'] as bool? ?? false,
      itemType: m['itemType'] as int?,
      groupTitle: m['groupTitle'] as String?,
      groupActionType: m['groupActionType'] as int?,
      balloonBundleId: m['balloonBundleId'] as String?,
      associatedMessageGuid: m['associatedMessageGuid'] as String?,
      associatedMessagePart: m['associatedMessagePart'] as int?,
      associatedMessageType: m['associatedMessageType'] as String?,
      associatedMessageEmoji: m['associatedMessageEmoji'] as String?,
      expressiveSendStyleId: m['expressiveSendStyleId'] as String?,
      service: m['service'] as String?,
      hasAttachments: m['hasAttachments'] as bool? ?? false,
      hasReactions: m['hasReactions'] as bool? ?? false,
      dateDeleted: _dt(m['dateDeleted']),
      threadOriginatorGuid: m['threadOriginatorGuid'] as String?,
      threadOriginatorPart: m['threadOriginatorPart'] as String?,
      hasApplePayloadData: m['hasApplePayloadData'] as bool? ?? false,
      wasDeliveredQuietly: m['wasDeliveredQuietly'] as bool? ?? false,
      didNotifyRecipient: m['didNotifyRecipient'] as bool? ?? false,
      isBookmarked: m['isBookmarked'] as bool? ?? false,
    );
    msg.bigEmoji = m['bigEmoji'] as bool?;
    msg.dbMetadata = m['dbMetadata'] as String?;
    msg.dbAttributedBody = m['dbAttributedBody'] as String?;
    msg.dbMessageSummaryInfo = m['dbMessageSummaryInfo'] as String?;
    msg.dbPayloadData = m['dbPayloadData'] as String?;
    msg.chat.targetId = m['chatId'] as int? ?? 0;
    msg.handleRelation.targetId = m['handleRelationId'] as int? ?? 0;
    return msg;
  }

  static Map<String, dynamic> encodeHandle(Handle h) => {
        'id': h.id,
        'originalROWID': h.originalROWID,
        'address': h.address,
        'country': h.country,
        'color': h.color,
        'defaultPhone': h.defaultPhone,
        'defaultEmail': h.defaultEmail,
        'formattedAddress': h.formattedAddress,
        'uniqueAddressAndService': h.uniqueAddressAndService,
        'service': h.service,
      };

  static Handle decodeHandle(Map<String, dynamic> m) => Handle(
        id: m['id'] as int?,
        originalROWID: m['originalROWID'] as int?,
        address: m['address'] as String? ?? '',
        country: m['country'] as String?,
        color: m['color'] as String?,
        defaultPhone: m['defaultPhone'] as String?,
        defaultEmail: m['defaultEmail'] as String?,
        formattedAddress: m['formattedAddress'] as String?,
        uniqueAddressAndService:
            m['uniqueAddressAndService'] as String? ?? '${m['address'] ?? ''}/${m['service'] ?? 'iMessage'}',
        service: m['service'] as String? ?? 'iMessage',
      );

  static Map<String, dynamic> encodeContactV2(ContactV2 c) => {
        'id': c.id,
        'displayName': c.displayName,
        'nativeContactId': c.nativeContactId,
        'avatarPath': c.avatarPath,
        'addresses': List<String>.from(c.addresses),
        'nickname': c.nickname,
        'firstName': c.firstName,
        'lastName': c.lastName,
        'middleName': c.middleName,
        'namePrefix': c.namePrefix,
        'nameSuffix': c.nameSuffix,
        'company': c.company,
        'dbPhoneNumbers': c.dbPhoneNumbers,
        'dbEmailAddresses': c.dbEmailAddresses,
        'isNative': c.isNative,
        'handleIds': c.handles._effectiveTargetIds(),
      };

  static ContactV2 decodeContactV2(Map<String, dynamic> m) {
    final c = ContactV2(
      id: m['id'] as int? ?? 0,
      displayName: m['displayName'] as String? ?? '',
      nativeContactId: m['nativeContactId'] as String? ?? '',
      isNative: m['isNative'] as bool? ?? false,
      avatarPath: m['avatarPath'] as String?,
      addresses: _strList(m['addresses']),
      nickname: m['nickname'] as String?,
      firstName: m['firstName'] as String?,
      lastName: m['lastName'] as String?,
      middleName: m['middleName'] as String?,
      namePrefix: m['namePrefix'] as String?,
      nameSuffix: m['nameSuffix'] as String?,
      company: m['company'] as String?,
    );
    c.dbPhoneNumbers = m['dbPhoneNumbers'] as String?;
    c.dbEmailAddresses = m['dbEmailAddresses'] as String?;
    c.handles._targetIds = _intList(m['handleIds']);
    return c;
  }

  static Map<String, dynamic> encodeCustomGroup(CustomGroup g) => {
        'id': g.id,
        'name': g.name,
        'sortOrder': g.sortOrder,
        'showUnreadBadge': g.showUnreadBadge,
        'chatIds': g.chats._effectiveTargetIds(),
      };

  static CustomGroup decodeCustomGroup(Map<String, dynamic> m) {
    final g = CustomGroup(
      id: m['id'] as int?,
      name: m['name'] as String? ?? '',
      sortOrder: m['sortOrder'] as int? ?? 0,
      showUnreadBadge: m['showUnreadBadge'] as bool? ?? true,
    );
    g.chats._targetIds = _intList(m['chatIds']);
    return g;
  }

  static Map<String, dynamic> encodeFCMData(FCMData f) => {
        'id': f.id,
        'projectID': f.projectID,
        'storageBucket': f.storageBucket,
        'apiKey': f.apiKey,
        'firebaseURL': f.firebaseURL,
        'clientID': f.clientID,
        'applicationID': f.applicationID,
      };

  static FCMData decodeFCMData(Map<String, dynamic> m) => FCMData(
        id: m['id'] as int?,
        projectID: m['projectID'] as String?,
        storageBucket: m['storageBucket'] as String?,
        apiKey: m['apiKey'] as String?,
        firebaseURL: m['firebaseURL'] as String?,
        clientID: m['clientID'] as String?,
        applicationID: m['applicationID'] as String?,
      );

  static Map<String, dynamic> encodeThemeStruct(ThemeStruct t) => {
        'id': t.id,
        'name': t.name,
        'gradientBg': t.gradientBg,
        'dbThemeData': t.dbThemeData,
        'googleFont': t.googleFont,
      };

  static ThemeStruct decodeThemeStruct(Map<String, dynamic> m) {
    final t = ThemeStruct(
      id: m['id'] as int?,
      name: m['name'] as String? ?? '',
      gradientBg: m['gradientBg'] as bool? ?? false,
      googleFont: m['googleFont'] as String? ?? 'Default',
    );
    final rawThemeData = m['dbThemeData'];
    if (rawThemeData is String && rawThemeData.isNotEmpty) {
      t.dbThemeData = rawThemeData;
    }
    return t;
  }

  static Map<String, dynamic> encodeThemeEntry(ThemeEntry e) => {
        'id': e.id,
        'themeId': e.themeId,
        'name': e.name,
        'isFont': e.isFont,
        'fontSize': e.fontSize,
        'dbColor': e.dbColor,
        'fontWeight': e.fontWeight,
        'themeObjectId': e.themeObject.targetId,
      };

  static ThemeEntry decodeThemeEntry(Map<String, dynamic> m) {
    final e = ThemeEntry(
      id: m['id'] as int?,
      themeId: m['themeId'] as int?,
      name: m['name'] as String?,
      isFont: m['isFont'] as bool?,
      fontSize: m['fontSize'] as int?,
      fontWeight: m['fontWeight'] as int?,
    );
    e.dbColor = m['dbColor'] as String?;
    e.themeObject.targetId = m['themeObjectId'] as int? ?? 0;
    return e;
  }

  static Map<String, dynamic> encodeThemeObject(ThemeObject o) => {
        'id': o.id,
        'name': o.name,
        'selectedLightTheme': o.selectedLightTheme,
        'selectedDarkTheme': o.selectedDarkTheme,
        'gradientBg': o.gradientBg,
        'previousLightTheme': o.previousLightTheme,
        'previousDarkTheme': o.previousDarkTheme,
      };

  static ThemeObject decodeThemeObject(Map<String, dynamic> m) => ThemeObject(
        id: m['id'] as int?,
        name: m['name'] as String?,
        selectedLightTheme: m['selectedLightTheme'] as bool? ?? false,
        selectedDarkTheme: m['selectedDarkTheme'] as bool? ?? false,
        gradientBg: m['gradientBg'] as bool? ?? false,
        previousLightTheme: m['previousLightTheme'] as bool? ?? false,
        previousDarkTheme: m['previousDarkTheme'] as bool? ?? false,
      );
}

// Legacy compatibility shims kept for any direct references
dynamic getObjectBoxModel() => null;
