// LocalSend v2 protocol data models for HarmonyOS (ArkTS).
// Field names MUST match protocol/README.md and the Android implementation.

export const LocalSendConst = {
  PORT: 53317,
  PROTOCOL_VERSION: '2.0',
  PATH_INFO: '/api/localsend/v2/info',
  PATH_REGISTER: '/api/localsend/v2/register',
  PATH_SEND_REQUEST: '/api/localsend/v2/send-request',
  PATH_SEND: '/api/localsend/v2/send',
  PATH_CANCEL: '/api/localsend/v2/cancel',
  DEVICE_TYPE_MOBILE: 'mobile'
};

export interface DeviceInfo {
  alias: string;
  version: string;
  deviceModel: string;
  deviceType: string;
  fingerprint: string;
  port: number;
  protocol: string;
  download: boolean;
}

export interface FileInfo {
  id: string;
  fileName: string;
  size: number;
  fileType: string;
  sha256?: string | null;
  preview?: string | null;
}

export interface SendRequest {
  info: DeviceInfo;
  files: Record<string, FileInfo>;
}

export interface SendRequestResponse {
  sessionId: string;
  files: Record<string, string>; // fileId -> "accept" | "cancel"
}

export interface CancelRequest {
  sessionId: string;
}

export function createDeviceInfo(alias: string, deviceModel: string, fingerprint: string): DeviceInfo {
  return {
    alias: alias,
    version: LocalSendConst.PROTOCOL_VERSION,
    deviceModel: deviceModel,
    deviceType: LocalSendConst.DEVICE_TYPE_MOBILE,
    fingerprint: fingerprint,
    port: LocalSendConst.PORT,
    protocol: 'http',
    download: true
  };
}

export function guessMime(fileName: string): string {
  const lower = fileName.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.zip')) return 'application/zip';
  return 'application/octet-stream';
}
