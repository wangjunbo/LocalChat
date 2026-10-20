import { util } from '@kit.ArkTS';
export const SERVICE_TYPE: string = '_lanternchat._tcp';
export const FRAME_LIMIT: number = 128 * 1024;
export const CHUNK_SIZE: number = 48 * 1024;
export class Packet {
  kind: string = '';
  id: string = util.generateRandomUUID();
  sender?: string;
  name?: string;
  text?: string;
  size?: number;
  data?: string;
  onlineFor?: number;
  supportsHeartbeat?: boolean;
  runID?: string;
  supportsProgress?: boolean;
  deviceType?: string;
  // Original send time in Unix epoch milliseconds.
  sentAt?: number;
  constructor(kind: string = '', id?: string) {
    this.kind = kind;
    if (id !== undefined) { this.id = id; }
  }
}
export function encodePacket(packet: Packet): ArrayBuffer {
  const body = new util.TextEncoder().encodeInto(JSON.stringify(packet));
  if (body.length === 0 || body.length > FRAME_LIMIT) { throw new Error('消息超过协议长度限制'); }
  const frame = new Uint8Array(body.length + 4);
  new DataView(frame.buffer).setUint32(0, body.length, false);
  frame.set(body, 4);
  return frame.buffer;
}
export class Framer {
  private pending: Uint8Array = new Uint8Array(0);
  append(data: ArrayBuffer): Packet[] {
    const merged = new Uint8Array(this.pending.length + data.byteLength);
    merged.set(this.pending);
    merged.set(new Uint8Array(data), this.pending.length);
    const packets: Packet[] = [];
    let offset = 0;
    while (merged.length - offset >= 4) {
      const size = new DataView(merged.buffer).getUint32(offset, false);
      if (size === 0 || size > FRAME_LIMIT) { throw new Error('无效的数据包长度'); }
      if (merged.length - offset < size + 4) { break; }
      const text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(merged.slice(offset + 4, offset + 4 + size));
      const packet = JSON.parse(text) as Packet;
      if (!packet || typeof packet.kind !== 'string' || typeof packet.id !== 'string' || packet.id.length > 64) {
        throw new Error('无效的数据包');
      }
      packets.push(packet);
      offset += size + 4;
    }
    this.pending = merged.slice(offset);
    return packets;
  }
}

export function messageDate(packet: Packet): number {
  const sentAt = packet.sentAt;
  return typeof sentAt === 'number' && Number.isFinite(sentAt) && sentAt >= 0 && sentAt <= 253402300799999 ? sentAt : Date.now();
}
