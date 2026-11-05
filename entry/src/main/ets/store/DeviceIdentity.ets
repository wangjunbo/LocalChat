import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

// This alias must remain stable across application updates.
const ALIAS: string = 'localchat.device-identity.v1';

export function restoreDeviceIdentity(previous: string): string {
  const encoder = new util.TextEncoder();
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, encoder.encodeInto(ALIAS));
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  try {
    const records = asset.querySync(query);
    if (records.length !== 1) { throw new Error('设备身份记录异常'); }
    const value = records[0].get(asset.Tag.SECRET) as Uint8Array;
    const id = new util.TextDecoder().decodeToString(value);
    if (!validIdentity(id)) { throw new Error('设备身份已损坏'); }
    return id;
  } catch (error) {
    // An unavailable service or a permission error is not a missing identity.
    if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw error as Error; }
  }
  const id = validIdentity(previous) ? previous : util.generateRandomUUID();
  const attributes: asset.AssetMap = new Map();
  attributes.set(asset.Tag.ALIAS, encoder.encodeInto(ALIAS));
  attributes.set(asset.Tag.SECRET, encoder.encodeInto(id));
  attributes.set(asset.Tag.IS_PERSISTENT, true);
  attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_POWERED_ON);
  // Do not enable cloud synchronization: different physical devices need different identities.
  attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
  asset.addSync(attributes);
  return id;
}

function validIdentity(id: string): boolean {
  return /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(id);
}
