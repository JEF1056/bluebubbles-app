import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

class GoogleSignInArgs {
  final String clientId;
  final String redirectUri;
  final String scope;
  const GoogleSignInArgs({
    required this.clientId,
    required this.redirectUri,
    required this.scope,
  });
}

class DesktopAuthResult {
  final String? accessToken;
  const DesktopAuthResult({this.accessToken});
}

class DesktopWebviewAuth {
  static Future<DesktopAuthResult?> signIn(
    GoogleSignInArgs args, {
    int? width,
    int? height,
  }) async =>
      null;
}

class SecureApplicationController {
  void lock() {}
  void unlock() {}
  void open() {}
  void secure() {}
  void authSuccess({bool unlock = false}) {}
}

class SecureApplication extends StatelessWidget {
  final Widget child;
  const SecureApplication({super.key, required this.child});
  @override
  Widget build(BuildContext context) => child;
}

class SecureApplicationProvider {
  static final SecureApplicationController _controller = SecureApplicationController();
  static SecureApplicationController? of(BuildContext context, {bool listen = true}) => _controller;
}

class SecureGate extends StatelessWidget {
  final Widget child;
  final double blurr;
  final double opacity;
  final Widget Function(BuildContext context, SecureApplicationController? controller)? lockedBuilder;
  const SecureGate({
    super.key,
    required this.child,
    this.blurr = 20,
    this.opacity = 0.6,
    this.lockedBuilder,
  });
  @override
  Widget build(BuildContext context) => child;
}

enum ResultType { done, fileNotFound, noAppToOpen, permissionDenied, error }

class OpenResult {
  final ResultType type;
  final String message;
  const OpenResult({this.type = ResultType.noAppToOpen, this.message = 'Not supported on web'});
}

class OpenFilex {
  static Future<OpenResult> open(String? filePath, {String? type}) async => const OpenResult();
}

// flutter_contacts v2 stubs
enum ContactProperty { photoThumbnail, photoFullRes }

class ContactProperties {
  static const Set<ContactProperty> allProperties = {};
  static const Set<ContactProperty> all = {};
}

enum PhoneLabel { custom, mobile, home, work, other }

enum EmailLabel { custom, home, work, other }

class Label<T> {
  final T label;
  final String? customLabel;
  const Label(this.label, [this.customLabel]);
}

class Phone {
  final String number;
  final Label<PhoneLabel> label;
  const Phone({required this.number, this.label = const Label(PhoneLabel.other)});
}

class Email {
  final String address;
  final Label<EmailLabel> label;
  const Email({required this.address, this.label = const Label(EmailLabel.other)});
}

class Name {
  final String? first;
  final String? last;
  final String? middle;
  final String? prefix;
  final String? suffix;
  final String? nickname;
  const Name({this.first, this.last, this.middle, this.prefix, this.suffix, this.nickname});
}

class Organization {
  final String? name;
  const Organization({this.name});
}

class Photo {
  final Uint8List? thumbnail;
  final Uint8List? fullSize;
  const Photo({this.thumbnail, this.fullSize});
}

class Account {
  final String id;
  final String name;
  final String type;
  const Account({required this.id, required this.name, required this.type});
}

class Contact {
  final String? id;
  final String? displayName;
  final Name? name;
  final List<Phone> phones;
  final List<Email> emails;
  final List<Organization> organizations;
  final Photo? photo;
  const Contact({
    this.id,
    this.displayName,
    this.name,
    this.phones = const [],
    this.emails = const [],
    this.organizations = const [],
    this.photo,
  });

  Contact copyWith({Photo? photo}) => Contact(
        id: id,
        displayName: displayName,
        name: name,
        phones: phones,
        emails: emails,
        organizations: organizations,
        photo: photo ?? this.photo,
      );
}

enum PermissionType { read, readWrite }

enum PermissionStatus { granted, denied }

class _ContactsPermissions {
  Future<PermissionStatus> request(PermissionType type) async => PermissionStatus.denied;
}

class _ContactsAccounts {
  Future<List<Account>> getAll() async => [];
}

class FlutterContacts {
  static final permissions = _ContactsPermissions();
  static final accounts = _ContactsAccounts();
  static Stream<void> get onDatabaseChange => const Stream.empty();

  static Future<List<Contact>> getAll({
    Set<ContactProperty>? properties,
    Account? account,
  }) async =>
      [];

  static Future<Contact?> get(
    String id, {
    Set<ContactProperty>? properties,
  }) async =>
      null;

  static Future<Contact> update(Contact contact) async => contact;
}
