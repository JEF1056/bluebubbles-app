export 'global_isolate_io.dart' if (dart.library.js_interop) 'global_isolate_web.dart';

/// Standard signature for all isolate-dispatchable action functions.
/// Every entry in the action map must conform to this type so that the
/// dispatch path is a single `await action(data)` without any runtime
/// string introspection.
typedef IsolateAction = Future<dynamic> Function(dynamic);

enum IsolateRequestType {
  // Test actions
  testReturnInput,
  testPrintInput,
  testThrowError,

  // App actions
  checkForUpdate,
  getFcmData,

  // Server actions
  checkForServerUpdate,
  getServerDetails,

  // Image actions
  convertImageToPng,
  convertIcoToPng,
  readExifData,
  getGifDimensions,
  readExifOrientation,
  generatePreview,

  // Prefs actions
  saveReplyToMessageState,
  loadReplyToMessageState,
  clearAllReplyToMessageStates,
  syncAllSettings,
  syncSettings,

  // Messages actions
  getMessages,

  // Chat actions
  clearNotificationForChat,
  markAllChatsRead,
  markChatReadUnread,
  startTyping,
  stopTyping,
  saveChat,
  deleteChat,
  softDeleteChat,
  unDeleteChat,
  addMessageToChat,
  loadSupplementalData,
  syncLatestMessages,
  bulkSyncChats,
  getMessagesAsync,
  getParticipantsAsync,
  clearTranscriptAsync,
  getChatsAsync,

  // Handle actions
  saveHandleAsync,
  bulkSaveHandlesAsync,
  findOneHandleAsync,
  findHandlesAsync,

  // ContactV2 actions (new contact service)
  syncContactsToHandles,
  syncContactsToHandlesWithStats,
  getStoredContactIds,
  findOneContact,
  getContactsForHandles,
  getContactByAddress,
  getAllContacts,
  fetchNetworkContacts,
  getContactAvatar,
  uploadContactsV2,
  getAccountContactCounts,

  // Attachment actions
  saveAttachmentAsync,
  bulkSaveAttachmentsAsync,
  replaceAttachmentAsync,
  findOneAttachmentAsync,
  findAttachmentsAsync,
  deleteAttachmentAsync,

  // Network actions
  setOriginOverride,

  // Sync actions
  performIncrementalSync,
  bulkSyncData,

  // Log actions
  getLogs,

  // Send message actions (routed through isolate so sends survive backgrounding)
  sendTextMessage,
  sendTapback,
  sendMultipartMessage,
  sendAttachmentMessage,
  sendMultiAttachmentMessage,
  sendAppMessage,

  // Message actions
  replaceMessage,
  deleteMessage,
  softDeleteMessage,
  fetchAssociatedMessagesAsync,
  saveMessageAsync,
  findOneAsync,
  findAsync,
  relinkMessagesToHandle,

  // CustomGroup actions
  getAllCustomGroups,
  createCustomGroup,
  renameCustomGroup,
  updateCustomGroupChats,
  setCustomGroupShowUnreadBadge,
  deleteCustomGroup,
  reorderCustomGroups,

  // Storage analyzer actions
  analyzeStorage,
  deleteStorageAttachments,
}

/// A standard request format for isolate communication
class IsolateRequest<T> {
  /// Unique identifier for the request
  final String uuid;

  /// Type of the request
  final IsolateRequestType type;

  /// Data payload
  final T? data;

  IsolateRequest({required this.uuid, required this.type, this.data});

  /// Convert request to a map
  Map<String, dynamic> toMap() {
    return {'uuid': uuid, 'type': type, if (data != null) 'data': data};
  }

  /// Create a request from a map
  factory IsolateRequest.fromMap(Map<String, dynamic> map) {
    return IsolateRequest(uuid: map['uuid'] as String, type: map['type'], data: map['data'] as T?);
  }
}

/// A standard response format for isolate communication
class IsolateResponse<T> {
  /// Unique identifier for the request
  final String uuid;

  /// Indicates if the operation was successful
  final bool ok;

  /// Error details if ok is false
  final String? error;

  /// Optional message about the operation
  final String? message;

  /// Optional data payload
  final T? data;

  IsolateResponse({required this.uuid, required this.ok, this.error, this.message, this.data});

  /// Create a success response
  factory IsolateResponse.success({required String uuid, String? message, T? data}) {
    return IsolateResponse(uuid: uuid, ok: true, message: message, data: data);
  }

  /// Create an error response
  factory IsolateResponse.error({required String uuid, required String error, String? message}) {
    return IsolateResponse(uuid: uuid, ok: false, error: error, message: message);
  }

  /// Convert response to a map
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'ok': ok,
      if (error != null) 'error': error,
      if (message != null) 'message': message,
      if (data != null) 'data': data,
    };
  }

  /// Create a response from a map
  factory IsolateResponse.fromMap(Map<String, dynamic> map) {
    return IsolateResponse(
      uuid: map['uuid'] as String,
      ok: map['ok'] as bool,
      error: map['error'] as String?,
      message: map['message'] as String?,
      data: map['data'] as T?,
    );
  }
}
