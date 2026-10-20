export const APP_VERSION: string = '1.0.9';
export const ASSISTANT_ID: string = 'local-assistant';
export class Peer {
  id: string = '';
  name: string = '';
  online: boolean = false;
  deviceType: string = '';
}
export class Message {
  unread: boolean = false;
  id: string = '';
  peer: string = '';
  text: string = '';
  mine: boolean = false;
  date: number = Date.now();
  name: string = '';
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
