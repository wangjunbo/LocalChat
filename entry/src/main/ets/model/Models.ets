export const APP_VERSION: string = '1.0.30';
export const ASSISTANT_ID: string = 'local-assistant';
export class Peer {
  id: string = '';
  name: string = '';
  online: boolean = false;
  deviceType: string = '';
}
export class Message {
  pendingDelivery: boolean = false;
  unread: boolean = false;
  id: string = '';
  peer: string = '';
  text: string = '';
  mine: boolean = false;
  date: number = Date.now();
  name: string = '';
  savedUri: string = '';
  path: string = '';
  bytes: number = 0;
  transferred: number = 0;
  status: string = '';
}
export class Attachment {
  id: string = '';
  name: string = '';
  path: string = '';
  size: number = 0;
}
export class Archive {
  peers: Peer[] = [];
  messages: Message[] = [];
}
export function isImage(path: string): boolean {
  return /\.(png|jpe?g|gif|webp|bmp|heic)$/i.test(path);
}
export function sizeLabel(bytes: number): string {
  if (bytes < 1024) { return `${bytes} B`; }
  if (bytes < 1048576) { return `${(bytes / 1024).toFixed(1)} KB`; }
  if (bytes < 1073741824) { return `${(bytes / 1048576).toFixed(1)} MB`; }
  return `${(bytes / 1073741824).toFixed(2)} GB`;
}

export function formatMessageDate(timestamp: number): string {
  const date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) { return ''; }
  const year = date.getFullYear().toString().padStart(4, '0');
  const month = (date.getMonth() + 1).toString().padStart(2, '0');
  const day = date.getDate().toString().padStart(2, '0');
  const hour = date.getHours().toString().padStart(2, '0');
  const minute = date.getMinutes().toString().padStart(2, '0');
  const second = date.getSeconds().toString().padStart(2, '0');
  return `${year}-${month}-${day} ${hour}:${minute}:${second}`;
}

export class IncomingShare {
  peer: string = '';
  id: string = '';
  files: Attachment[] = [];
  text: string = '';
}
