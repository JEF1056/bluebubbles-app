export const DEFAULT_PASSWORD = 'test-password-123';

// Valid 1x1 red RGBA PNG
export const SAMPLE_PNG_BYTES = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

// Minimal valid ISO BMFF MP4 container (ftypisom + free + mdat)
export const SAMPLE_MP4_BYTES = Buffer.concat([
  Buffer.from([
    0x00, 0x00, 0x00, 0x18, // box size 24
    0x66, 0x74, 0x79, 0x70, // 'ftyp'
    0x69, 0x73, 0x6f, 0x6d, // 'isom'
    0x00, 0x00, 0x02, 0x00, // minor_version
    0x69, 0x73, 0x6f, 0x6d, // 'isom'
    0x6d, 0x70, 0x34, 0x31, // 'mp41'
  ]),
  Buffer.from([0x00, 0x00, 0x00, 0x08, 0x66, 0x72, 0x65, 0x65]), // 'free'
  Buffer.from([0x00, 0x00, 0x00, 0x10, 0x6d, 0x64, 0x61, 0x74, 0, 0, 0, 0, 0, 0, 0, 0]), // 'mdat'
]);

// Minimal valid ISO BMFF M4A audio container (ftypM4A  + free + mdat)
export const SAMPLE_M4A_BYTES = Buffer.concat([
  Buffer.from([
    0x00, 0x00, 0x00, 0x18, // box size 24
    0x66, 0x74, 0x79, 0x70, // 'ftyp'
    0x4d, 0x34, 0x41, 0x20, // 'M4A '
    0x00, 0x00, 0x00, 0x00, // minor_version
    0x4d, 0x34, 0x41, 0x20, // 'M4A '
    0x6d, 0x70, 0x34, 0x32, // 'mp42'
  ]),
  Buffer.from([0x00, 0x00, 0x00, 0x08, 0x66, 0x72, 0x65, 0x65]), // 'free'
  Buffer.from([0x00, 0x00, 0x00, 0x10, 0x6d, 0x64, 0x61, 0x74, 0, 0, 0, 0, 0, 0, 0, 0]), // 'mdat'
]);

export interface HandleFixture {
  originalROWID: number;
  id: number;
  address: string;
  formattedAddress: string;
  service: string;
  country: string;
  uncanonicalizedId?: string;
}

export interface AttachmentFixture {
  originalROWID: number;
  id: number;
  guid: string;
  uti: string;
  mimeType: string;
  isOutgoing: boolean;
  transferName: string;
  totalBytes: number;
  height: number;
  width: number;
  hasLivePhoto: boolean;
  isDownloaded: boolean;
  metadata: Record<string, unknown> | null;
  exif: Record<string, unknown> | null;
  /** Binary payload served by /attachment/:guid/download (stripped from JSON responses). */
  bytes?: Buffer;
}

export interface MessageFixture {
  originalROWID: number;
  id: number;
  guid: string;
  chatGuid?: string;
  handleId: number;
  otherHandle: number | null;
  text: string;
  subject: string | null;
  country: string;
  error: number;
  dateCreated: number;
  dateRead: number | null;
  dateDelivered: number | null;
  dateEdited: number | null;
  dateDeleted: number | null;
  isDelivered: boolean;
  isFromMe: boolean;
  hasDdResults: boolean;
  itemType: number;
  groupTitle: string | null;
  groupActionType: number;
  balloonBundleId: string | null;
  associatedMessageGuid: string | null;
  associatedMessagePart: number | null;
  associatedMessageType: string | null;
  associatedMessageEmoji: string | null;
  expressiveSendStyleId: string | null;
  service: string;
  handle: HandleFixture | null;
  hasAttachments: boolean;
  attachments: AttachmentFixture[];
  hasReactions: boolean;
  associatedMessages: MessageFixture[];
  metadata: Record<string, unknown> | null;
  threadOriginatorGuid: string | null;
  threadOriginatorPart: string | null;
  attributedBody: Array<Record<string, unknown>>;
  messageSummaryInfo: Array<Record<string, unknown>>;
  payloadData: Record<string, unknown> | null;
  hasApplePayloadData: boolean;
  wasDeliveredQuietly: boolean;
  didNotifyRecipient: boolean;
  isBookmarked: boolean;
  tempGuid?: string;
}

export interface ChatFixture {
  originalROWID: number;
  id: number;
  guid: string;
  chatIdentifier: string;
  isArchived: boolean;
  isPinned: boolean;
  pinIndex: number | null;
  muteType: string | null;
  muteArgs: string | null;
  hasUnreadMessage: boolean;
  displayName: string | null;
  style: number;
  serviceName: string;
  /** Must always be non-empty: FullSyncManager soft-deletes chats with empty participants. */
  participants: HandleFixture[];
  lastMessage: MessageFixture | null;
  autoSendReadReceipts: boolean | null;
  autoSendTypingIndicators: boolean | null;
  dateDeleted: number | null;
  lastReadMessageGuid: string | null;
  properties: Array<Record<string, unknown>>;
}

export interface ContactFixture {
  id: string;
  displayName: string;
  firstName: string;
  lastName: string;
  phoneNumbers: Array<{ address: string; label: string }>;
  emails: Array<{ address: string; label: string }>;
  avatar?: string;
}

export interface FindMyDeviceFixture {
  id: string;
  name: string;
  deviceDisplayName: string;
  modelDisplayName: string;
  deviceModel: string;
  rawDeviceModel: string;
  deviceClass: string;
  isConsideredAccessory: boolean;
  isMac: boolean;
  thisDevice: boolean;
  deviceWithYou: boolean;
  batteryLevel: number;
  batteryStatus: string;
  locationEnabled: boolean;
  locationCapable: boolean;
  lostModeCapable: boolean;
  lostModeEnabled: boolean;
  lostDevice: unknown;
  activationLocked: boolean;
  audioChannels: unknown[];
  safeLocations: unknown[];
  lowPowerMode: boolean;
  passcodeLength: number;
  itemGroup: unknown;
  snd: unknown;
  deviceColor: string | null;
  rm2State: number;
  locFoundEnabled: boolean;
  nwd: boolean;
  deviceStatus: string;
  remoteWipe: unknown;
  fmlyShare: boolean;
  canWipeAfterLock: boolean;
  baUUID: string | null;
  trackingInfo: unknown;
  features: Record<string, unknown> | null;
  deviceDiscoveryId: string | null;
  prsId: string | null;
  scd: boolean;
  remoteLock: unknown;
  wipeInProgress: boolean;
  darkWake: boolean;
  maxMsgChar: number;
  crowdSourcedLocation: unknown;
  role: { emoji?: string; [k: string]: unknown } | null;
  lostModeMetadata: Record<string, unknown> | null;
  iconUrl: string | null;
  iconCategory: string | null;
  address: {
    label: string | null;
    streetAddress: string;
    streetName: string;
    locality: string;
    administrativeArea: string;
    stateCode: string;
    country: string;
    countryCode: string;
    subAdministrativeArea: string;
    formattedAddressLines: string[];
    mapItemFullAddress: string;
    fullThroroughfare: string;
    areaOfInterest: string[];
  };
  location: {
    latitude: number;
    longitude: number;
    timeStamp: number;
    horizontalAccuracy: number;
    verticalAccuracy: number;
    altitude: number;
    speed: number;
    floorLevel: number;
    positionType: string;
    isOld: boolean;
    isInaccurate: boolean;
    locationFinished: boolean;
    isLocatingInProgress: boolean;
  };
}

export interface FindMyFriendFixture {
  coordinates: [number, number];
  title: string;
  subtitle: string;
  short_address: string;
  long_address: string;
  handle: string | { address: string };
  last_updated: number;
  status: 'legacy' | 'shallow' | 'live';
  is_live: boolean;
  locating_in_progress: boolean;
  horizontal_accuracy: number;
  vertical_accuracy: number;
  speed: number;
  altitude: number;
  is_old: boolean;
  is_inaccurate: boolean;
  location_finished: boolean;
}

export interface FaceTimeSessionFixture {
  uuid: string;
  status_id: number;
  status: string;
  handle?: HandleFixture;
  address?: string;
  display_name?: string;
  is_video: boolean;
  is_audio: boolean;
  is_telephony: boolean;
  date_started?: number;
  link?: string;
}

export interface ScheduledMessageFixture {
  id: number;
  type: string;
  payload: Record<string, unknown>;
  scheduledFor: number;
  schedule: Record<string, unknown>;
  status: string;
  created: number;
}

export interface ServerInfoFixture {
  os_version: string;
  server_version: string;
  server_build_version: number;
  private_api: boolean;
  helper_connected: boolean;
  detected_icloud: string;
  detected_imessage: string;
  proxy_service: string;
  api_versions: number[];
  supportsFaceTimeCalls: boolean;
  mac_address: string;
}

export interface MockSeed {
  serverInfo: ServerInfoFixture;
  handles: HandleFixture[];
  chats: ChatFixture[];
  messagesByChat: Record<string, MessageFixture[]>;
  contacts: ContactFixture[];
  findMyDevices: FindMyDeviceFixture[];
  findMyFriends: FindMyFriendFixture[];
  faceTimeSessions: FaceTimeSessionFixture[];
  scheduledMessages: ScheduledMessageFixture[];
  themeBackup: Record<string, unknown> | null;
  settingsBackup: Record<string, unknown> | null;
}

// Deterministic base epoch: 2026-11-20T18:00:00.000Z
const BASE_TS = 1795197600000;
let seqCounter = 100;

function nextId(): number {
  seqCounter += 1;
  return seqCounter;
}

export function makeHandle(overrides: Partial<HandleFixture> = {}): HandleFixture {
  const id = overrides.originalROWID ?? overrides.id ?? nextId();
  const address = overrides.address ?? `+1555010${String(id).padStart(4, '0')}`;
  return {
    originalROWID: id,
    id,
    address,
    formattedAddress: overrides.formattedAddress ?? address,
    service: overrides.service ?? 'iMessage',
    country: overrides.country ?? 'US',
    ...overrides,
  };
}

export function makeAttachment(overrides: Partial<AttachmentFixture> = {}): AttachmentFixture {
  const id = overrides.originalROWID ?? overrides.id ?? nextId();
  const bytes = overrides.bytes ?? SAMPLE_PNG_BYTES;
  return {
    originalROWID: id,
    id,
    guid: overrides.guid ?? `att-mock-${id}`,
    uti: overrides.uti ?? 'public.png',
    mimeType: overrides.mimeType ?? 'image/png',
    isOutgoing: overrides.isOutgoing ?? false,
    transferName: overrides.transferName ?? `image-${id}.png`,
    totalBytes: overrides.totalBytes ?? bytes.byteLength,
    height: overrides.height ?? 240,
    width: overrides.width ?? 320,
    hasLivePhoto: overrides.hasLivePhoto ?? false,
    isDownloaded: overrides.isDownloaded ?? true,
    metadata: overrides.metadata ?? null,
    exif: overrides.exif ?? null,
    bytes,
    ...overrides,
  };
}

export function makeMessage(overrides: Partial<MessageFixture> = {}): MessageFixture {
  const id = overrides.originalROWID ?? overrides.id ?? nextId();
  const dateCreated = overrides.dateCreated ?? BASE_TS + id * 1000;
  const attachments = overrides.attachments ?? [];
  const isFromMe = overrides.isFromMe ?? false;
  return {
    originalROWID: id,
    id,
    guid: overrides.guid ?? `msg-mock-${id}`,
    chatGuid: overrides.chatGuid,
    handleId: overrides.handleId ?? (isFromMe ? 0 : (overrides.handle?.originalROWID ?? 1)),
    otherHandle: overrides.otherHandle ?? null,
    text: overrides.text ?? `Message ${id}`,
    subject: overrides.subject ?? null,
    country: overrides.country ?? 'US',
    error: overrides.error ?? 0,
    dateCreated,
    dateRead: overrides.dateRead ?? (isFromMe ? dateCreated + 500 : null),
    dateDelivered: overrides.dateDelivered ?? dateCreated + 200,
    dateEdited: overrides.dateEdited ?? null,
    dateDeleted: overrides.dateDeleted ?? null,
    isDelivered: overrides.isDelivered ?? true,
    isFromMe,
    hasDdResults: overrides.hasDdResults ?? false,
    itemType: overrides.itemType ?? 0,
    groupTitle: overrides.groupTitle ?? null,
    groupActionType: overrides.groupActionType ?? 0,
    balloonBundleId: overrides.balloonBundleId ?? null,
    associatedMessageGuid: overrides.associatedMessageGuid ?? null,
    associatedMessagePart: overrides.associatedMessagePart ?? null,
    associatedMessageType: overrides.associatedMessageType ?? null,
    associatedMessageEmoji: overrides.associatedMessageEmoji ?? null,
    expressiveSendStyleId: overrides.expressiveSendStyleId ?? null,
    service: overrides.service ?? 'iMessage',
    handle: overrides.handle ?? null,
    hasAttachments: overrides.hasAttachments ?? attachments.length > 0,
    attachments,
    hasReactions: overrides.hasReactions ?? false,
    associatedMessages: overrides.associatedMessages ?? [],
    metadata: overrides.metadata ?? null,
    threadOriginatorGuid: overrides.threadOriginatorGuid ?? null,
    threadOriginatorPart: overrides.threadOriginatorPart ?? null,
    attributedBody: overrides.attributedBody ?? [],
    messageSummaryInfo: overrides.messageSummaryInfo ?? [],
    payloadData: overrides.payloadData ?? null,
    hasApplePayloadData: overrides.hasApplePayloadData ?? false,
    wasDeliveredQuietly: overrides.wasDeliveredQuietly ?? false,
    didNotifyRecipient: overrides.didNotifyRecipient ?? false,
    isBookmarked: overrides.isBookmarked ?? false,
    ...(overrides.tempGuid ? { tempGuid: overrides.tempGuid } : {}),
  };
}

export function makeChat(overrides: Partial<ChatFixture> = {}): ChatFixture {
  const id = overrides.originalROWID ?? overrides.id ?? nextId();
  const participants =
    overrides.participants && overrides.participants.length > 0
      ? overrides.participants
      : [makeHandle()];
  const serviceName = overrides.serviceName ?? participants[0].service ?? 'iMessage';
  const style = overrides.style ?? (participants.length > 1 ? 43 : 45);
  const chatIdentifier =
    overrides.chatIdentifier ?? (style === 43 ? `chat${1000000 + id}` : participants[0].address);
  const guid =
    overrides.guid ?? `${serviceName};${style === 43 ? '+' : '-'};${chatIdentifier}`;

  return {
    originalROWID: id,
    id,
    guid,
    chatIdentifier,
    isArchived: overrides.isArchived ?? false,
    isPinned: overrides.isPinned ?? false,
    pinIndex: overrides.pinIndex ?? null,
    muteType: overrides.muteType ?? null,
    muteArgs: overrides.muteArgs ?? null,
    hasUnreadMessage: overrides.hasUnreadMessage ?? false,
    displayName: overrides.displayName ?? null,
    style,
    serviceName,
    participants,
    lastMessage: overrides.lastMessage ?? null,
    autoSendReadReceipts: overrides.autoSendReadReceipts ?? true,
    autoSendTypingIndicators: overrides.autoSendTypingIndicators ?? true,
    dateDeleted: overrides.dateDeleted ?? null,
    lastReadMessageGuid: overrides.lastReadMessageGuid ?? null,
    properties: overrides.properties ?? [],
  };
}

export function makeContact(overrides: Partial<ContactFixture> = {}): ContactFixture {
  const id = overrides.id ?? `contact-${nextId()}`;
  const firstName = overrides.firstName ?? 'Test';
  const lastName = overrides.lastName ?? 'Contact';
  return {
    id,
    displayName: overrides.displayName ?? `${firstName} ${lastName}`.trim(),
    firstName,
    lastName,
    phoneNumbers: overrides.phoneNumbers ?? [],
    emails: overrides.emails ?? [],
    ...(overrides.avatar ? { avatar: overrides.avatar } : {}),
  };
}

export function makeFindMyDevice(overrides: Partial<FindMyDeviceFixture> = {}): FindMyDeviceFixture {
  const id = overrides.id ?? `device-${nextId()}`;
  const name = overrides.name ?? 'MacBook Pro';
  return {
    id,
    name,
    deviceDisplayName: overrides.deviceDisplayName ?? name,
    modelDisplayName: overrides.modelDisplayName ?? 'MacBook Pro 16"',
    deviceModel: overrides.deviceModel ?? 'Mac15,10',
    rawDeviceModel: overrides.rawDeviceModel ?? 'Mac15,10',
    deviceClass: overrides.deviceClass ?? 'Mac',
    isConsideredAccessory: overrides.isConsideredAccessory ?? false,
    isMac: overrides.isMac ?? true,
    thisDevice: overrides.thisDevice ?? false,
    deviceWithYou: overrides.deviceWithYou ?? true,
    batteryLevel: overrides.batteryLevel ?? 0.85,
    batteryStatus: overrides.batteryStatus ?? 'NotCharging',
    locationEnabled: overrides.locationEnabled ?? true,
    locationCapable: overrides.locationCapable ?? true,
    lostModeCapable: overrides.lostModeCapable ?? true,
    lostModeEnabled: overrides.lostModeEnabled ?? false,
    lostDevice: overrides.lostDevice ?? null,
    activationLocked: overrides.activationLocked ?? true,
    audioChannels: overrides.audioChannels ?? [],
    safeLocations: overrides.safeLocations ?? [],
    lowPowerMode: overrides.lowPowerMode ?? false,
    passcodeLength: overrides.passcodeLength ?? 6,
    itemGroup: overrides.itemGroup ?? null,
    snd: overrides.snd ?? null,
    deviceColor: overrides.deviceColor ?? 'SpaceBlack',
    rm2State: overrides.rm2State ?? 0,
    locFoundEnabled: overrides.locFoundEnabled ?? false,
    nwd: overrides.nwd ?? false,
    deviceStatus: overrides.deviceStatus ?? '200',
    remoteWipe: overrides.remoteWipe ?? null,
    fmlyShare: overrides.fmlyShare ?? false,
    canWipeAfterLock: overrides.canWipeAfterLock ?? true,
    baUUID: overrides.baUUID ?? null,
    trackingInfo: overrides.trackingInfo ?? null,
    features: overrides.features ?? null,
    deviceDiscoveryId: overrides.deviceDiscoveryId ?? null,
    prsId: overrides.prsId ?? null,
    scd: overrides.scd ?? false,
    remoteLock: overrides.remoteLock ?? null,
    wipeInProgress: overrides.wipeInProgress ?? false,
    darkWake: overrides.darkWake ?? false,
    maxMsgChar: overrides.maxMsgChar ?? 100,
    crowdSourcedLocation: overrides.crowdSourcedLocation ?? null,
    role: overrides.role ?? null,
    lostModeMetadata: overrides.lostModeMetadata ?? null,
    iconUrl: overrides.iconUrl ?? `/api/v1/icloud/findmy/devices/icon?id=${encodeURIComponent(id)}`,
    iconCategory: overrides.iconCategory ?? 'mac',
    address: overrides.address ?? {
      label: 'Apple Park',
      streetAddress: '1 Apple Park Way',
      streetName: 'Apple Park Way',
      locality: 'Cupertino',
      administrativeArea: 'CA',
      stateCode: 'CA',
      country: 'United States',
      countryCode: 'US',
      subAdministrativeArea: 'Santa Clara',
      formattedAddressLines: ['1 Apple Park Way', 'Cupertino, CA 95014'],
      mapItemFullAddress: '1 Apple Park Way, Cupertino, CA 95014',
      fullThroroughfare: '1 Apple Park Way',
      areaOfInterest: [],
    },
    location: overrides.location ?? {
      latitude: 37.3349,
      longitude: -122.009,
      timeStamp: BASE_TS,
      horizontalAccuracy: 12,
      verticalAccuracy: 4,
      altitude: 25,
      speed: 0,
      floorLevel: 0,
      positionType: 'live',
      isOld: false,
      isInaccurate: false,
      locationFinished: true,
      isLocatingInProgress: false,
    },
  };
}

export function makeFindMyFriend(overrides: Partial<FindMyFriendFixture> = {}): FindMyFriendFixture {
  return {
    coordinates: overrides.coordinates ?? [37.7749, -122.4194],
    title: overrides.title ?? 'Alex Mercer',
    subtitle: overrides.subtitle ?? 'San Francisco, CA',
    short_address: overrides.short_address ?? 'San Francisco, CA',
    long_address: overrides.long_address ?? '1 Market St, San Francisco, CA',
    handle: overrides.handle ?? '+15550100001',
    last_updated: overrides.last_updated ?? BASE_TS,
    status: overrides.status ?? 'live',
    is_live: overrides.is_live ?? true,
    locating_in_progress: overrides.locating_in_progress ?? false,
    horizontal_accuracy: overrides.horizontal_accuracy ?? 15,
    vertical_accuracy: overrides.vertical_accuracy ?? 5,
    speed: overrides.speed ?? 0,
    altitude: overrides.altitude ?? 10,
    is_old: overrides.is_old ?? false,
    is_inaccurate: overrides.is_inaccurate ?? false,
    location_finished: overrides.location_finished ?? true,
  };
}

export function makeFaceTimeSession(overrides: Partial<FaceTimeSessionFixture> = {}): FaceTimeSessionFixture {
  const id = nextId();
  return {
    uuid: overrides.uuid ?? `ft-call-${id}`,
    status_id: overrides.status_id ?? 4,
    status: overrides.status ?? 'incoming',
    handle: overrides.handle,
    address: overrides.address ?? overrides.handle?.address ?? '+15550100001',
    display_name: overrides.display_name ?? 'Alex Mercer',
    is_video: overrides.is_video ?? true,
    is_audio: overrides.is_audio ?? false,
    is_telephony: overrides.is_telephony ?? false,
    date_started: overrides.date_started ?? BASE_TS,
    link: overrides.link,
  };
}

export function createDefaultSeed(): MockSeed {
  const alexHandle = makeHandle({
    originalROWID: 1,
    id: 1,
    address: '+15550100001',
    formattedAddress: '+1 (555) 010-0001',
    service: 'iMessage',
  });
  const jordanHandle = makeHandle({
    originalROWID: 2,
    id: 2,
    address: '+15550100002',
    formattedAddress: '+1 (555) 010-0002',
    service: 'SMS',
  });
  const samHandle = makeHandle({
    originalROWID: 3,
    id: 3,
    address: 'sam.rivera@icloud.com',
    formattedAddress: 'sam.rivera@icloud.com',
    service: 'iMessage',
  });

  const imgAttachment = makeAttachment({
    originalROWID: 1,
    id: 1,
    guid: 'att-seed-img-1',
    uti: 'public.png',
    mimeType: 'image/png',
    transferName: 'sunset-photo.png',
    width: 320,
    height: 240,
    bytes: SAMPLE_PNG_BYTES,
    totalBytes: SAMPLE_PNG_BYTES.byteLength,
  });

  const dmChatGuid = 'iMessage;-;+15550100001';
  const smsChatGuid = 'SMS;-;+15550100002';
  const groupChatGuid = 'iMessage;+;chat1000000000000001';

  const dmMessages: MessageFixture[] = [
    makeMessage({
      originalROWID: 10,
      id: 10,
      guid: 'msg-dm-1',
      chatGuid: dmChatGuid,
      handleId: alexHandle.id,
      handle: alexHandle,
      text: 'Hey! Ready for the BlueBubbles E2E test?',
      isFromMe: false,
      dateCreated: BASE_TS - 120_000,
    }),
    makeMessage({
      originalROWID: 11,
      id: 11,
      guid: 'msg-dm-2',
      chatGuid: dmChatGuid,
      handleId: 0,
      text: 'Check out this screenshot!',
      isFromMe: true,
      dateCreated: BASE_TS - 90_000,
      hasAttachments: true,
      attachments: [imgAttachment],
    }),
    makeMessage({
      originalROWID: 12,
      id: 12,
      guid: 'msg-dm-3',
      chatGuid: dmChatGuid,
      handleId: alexHandle.id,
      handle: alexHandle,
      text: 'Looks super crisp on Web Wasm.',
      isFromMe: false,
      dateCreated: BASE_TS - 60_000,
    }),
  ];

  const smsMessages: MessageFixture[] = [
    makeMessage({
      originalROWID: 20,
      id: 20,
      guid: 'msg-sms-1',
      chatGuid: smsChatGuid,
      handleId: jordanHandle.id,
      handle: jordanHandle,
      service: 'SMS',
      text: 'Can you confirm the delivery window?',
      isFromMe: false,
      dateCreated: BASE_TS - 300_000,
    }),
    makeMessage({
      originalROWID: 21,
      id: 21,
      guid: 'msg-sms-2',
      chatGuid: smsChatGuid,
      handleId: jordanHandle.id,
      handle: jordanHandle,
      service: 'SMS',
      text: 'Unread SMS update: package arrives at 3pm.',
      isFromMe: false,
      dateCreated: BASE_TS - 180_000,
    }),
  ];

  const groupMessages: MessageFixture[] = [
    makeMessage({
      originalROWID: 30,
      id: 30,
      guid: 'msg-grp-1',
      chatGuid: groupChatGuid,
      handleId: samHandle.id,
      handle: samHandle,
      text: 'Who is bringing snacks this weekend?',
      isFromMe: false,
      dateCreated: BASE_TS - 400_000,
    }),
    makeMessage({
      originalROWID: 31,
      id: 31,
      guid: 'msg-grp-2',
      chatGuid: groupChatGuid,
      handleId: alexHandle.id,
      handle: alexHandle,
      text: 'I got the chips and salsa covered!',
      isFromMe: false,
      dateCreated: BASE_TS - 240_000,
    }),
  ];

  const dmChat = makeChat({
    originalROWID: 1,
    id: 1,
    guid: dmChatGuid,
    chatIdentifier: '+15550100001',
    displayName: 'Alex Mercer',
    serviceName: 'iMessage',
    style: 45,
    isPinned: true,
    pinIndex: 0,
    hasUnreadMessage: false,
    participants: [alexHandle],
    lastMessage: dmMessages[dmMessages.length - 1],
  });

  const smsChat = makeChat({
    originalROWID: 2,
    id: 2,
    guid: smsChatGuid,
    chatIdentifier: '+15550100002',
    displayName: 'Jordan Lee',
    serviceName: 'SMS',
    style: 45,
    isPinned: false,
    hasUnreadMessage: true,
    participants: [jordanHandle],
    lastMessage: smsMessages[smsMessages.length - 1],
  });

  const groupChat = makeChat({
    originalROWID: 3,
    id: 3,
    guid: groupChatGuid,
    chatIdentifier: 'chat1000000000000001',
    displayName: 'Weekend Crew',
    serviceName: 'iMessage',
    style: 43,
    isPinned: false,
    hasUnreadMessage: false,
    participants: [alexHandle, jordanHandle, samHandle],
    lastMessage: groupMessages[groupMessages.length - 1],
  });

  const contacts: ContactFixture[] = [
    makeContact({
      id: 'contact-alex',
      displayName: 'Alex Mercer',
      firstName: 'Alex',
      lastName: 'Mercer',
      phoneNumbers: [{ address: '+15550100001', label: 'mobile' }],
      emails: [{ address: 'alex.mercer@icloud.com', label: 'home' }],
    }),
    makeContact({
      id: 'contact-jordan',
      displayName: 'Jordan Lee',
      firstName: 'Jordan',
      lastName: 'Lee',
      phoneNumbers: [{ address: '+15550100002', label: 'mobile' }],
      emails: [],
    }),
    makeContact({
      id: 'contact-sam',
      displayName: 'Sam Rivera',
      firstName: 'Sam',
      lastName: 'Rivera',
      phoneNumbers: [],
      emails: [{ address: 'sam.rivera@icloud.com', label: 'home' }],
    }),
  ];

  const findMyDevices: FindMyDeviceFixture[] = [
    makeFindMyDevice({
      id: 'dev-macbook-pro',
      name: 'MacBook Pro',
      deviceDisplayName: 'MacBook Pro',
      modelDisplayName: 'MacBook Pro 16"',
      deviceModel: 'Mac15,10',
      rawDeviceModel: 'Mac15,10',
      deviceClass: 'Mac',
      isConsideredAccessory: false,
      isMac: true,
      thisDevice: true,
      batteryLevel: 0.92,
      iconCategory: 'mac',
      features: { CAN_RING: true },
    }),
    makeFindMyDevice({
      id: 'dev-iphone-16',
      name: 'iPhone 16 Pro',
      deviceDisplayName: 'iPhone 16 Pro',
      modelDisplayName: 'iPhone 16 Pro',
      deviceModel: 'iPhone17,1',
      rawDeviceModel: 'iPhone17,1',
      deviceClass: 'iPhone',
      isConsideredAccessory: false,
      isMac: false,
      thisDevice: false,
      batteryLevel: 0.78,
      iconCategory: 'iphone',
      features: { CAN_RING: true },
      location: {
        latitude: 37.3382,
        longitude: -122.012,
        timeStamp: BASE_TS - 30_000,
        horizontalAccuracy: 8,
        verticalAccuracy: 3,
        altitude: 22,
        speed: 0,
        floorLevel: 0,
        positionType: 'live',
        isOld: false,
        isInaccurate: false,
        locationFinished: true,
        isLocatingInProgress: false,
      },
    }),
    makeFindMyDevice({
      id: 'item-airtag-keys',
      name: 'House Keys',
      deviceDisplayName: 'House Keys',
      modelDisplayName: 'AirTag',
      deviceModel: 'AirTag',
      rawDeviceModel: 'B389',
      deviceClass: 'Accessory',
      isConsideredAccessory: true,
      isMac: false,
      thisDevice: false,
      batteryLevel: 1.0,
      iconCategory: 'airtag',
      role: { emoji: '🔑' },
      features: {
        TRACKER_PROVIDER: 'apple',
        CAN_RING: true,
        CAN_FIND_NEARBY: true,
        HAS_BLE_RING: true,
        SUPPORTS_UWB: true,
        RING_COMPONENTS: ['speaker'],
      },
    }),
    makeFindMyDevice({
      id: 'item-smarttag-backpack',
      name: 'Travel Backpack',
      deviceDisplayName: 'Travel Backpack',
      modelDisplayName: 'Galaxy SmartTag2',
      deviceModel: 'SmartTag2',
      rawDeviceModel: 'EI-T5600',
      deviceClass: 'Accessory',
      isConsideredAccessory: true,
      isMac: false,
      thisDevice: false,
      batteryLevel: 0.65,
      iconCategory: 'smarttag',
      role: { emoji: '🎒' },
      features: {
        TRACKER_PROVIDER: 'samsung',
        CAN_RING: true,
        CAN_FIND_NEARBY: true,
        HAS_BLE_RING: true,
        SUPPORTS_UWB: false,
        RING_COMPONENTS: ['speaker'],
      },
    }),
  ];

  const findMyFriends: FindMyFriendFixture[] = [
    makeFindMyFriend({
      title: 'Alex Mercer',
      subtitle: 'San Francisco, CA',
      short_address: 'San Francisco, CA',
      long_address: '1 Market St, San Francisco, CA',
      handle: '+15550100001',
      coordinates: [37.7937, -122.3965],
      status: 'live',
      is_live: true,
      last_updated: BASE_TS - 10_000,
    }),
    makeFindMyFriend({
      title: 'Sam Rivera',
      subtitle: 'Oakland, CA',
      short_address: 'Oakland, CA',
      long_address: '14th St & Broadway, Oakland, CA',
      handle: 'sam.rivera@icloud.com',
      coordinates: [37.8044, -122.2712],
      status: 'shallow',
      is_live: false,
      last_updated: BASE_TS - 120_000,
    }),
  ];

  return {
    serverInfo: {
      os_version: '15.0.0',
      server_version: '1.9.9',
      server_build_version: 298,
      private_api: true,
      helper_connected: true,
      detected_icloud: 'e2e-user@icloud.com',
      detected_imessage: '+15550109999',
      proxy_service: 'Cloudflare',
      api_versions: [1, 2],
      supportsFaceTimeCalls: true,
      mac_address: '00:11:22:33:44:55',
    },
    handles: [alexHandle, jordanHandle, samHandle],
    chats: [dmChat, smsChat, groupChat],
    messagesByChat: {
      [dmChatGuid]: dmMessages,
      [smsChatGuid]: smsMessages,
      [groupChatGuid]: groupMessages,
    },
    contacts,
    findMyDevices,
    findMyFriends,
    faceTimeSessions: [],
    scheduledMessages: [],
    themeBackup: null,
    settingsBackup: null,
  };
}
