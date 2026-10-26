import { common } from '@kit.AbilityKit';
import { insightIntent } from '@kit.IntentsKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BuildProfile from 'BuildProfile';

// Intents Kit requires Huawei onboarding/allowlisting. Failures must never block sharing.
export class ShareContacts {
  static async record(context: common.UIAbilityContext, id: string, name: string): Promise<void> {
    try {
      const bytes = await context.resourceManager.getMediaContent($r('app.media.share_contact_icon').id);
      const now = Date.now();
      const intent: insightIntent.InsightIntent = {
        intentName: 'SendMessage', intentVersion: '1.0', identifier: util.generateRandomUUID(),
        intentActionInfo: {
          actionMode: 'EXECUTED', executedTimeSlots: { executedStartTime: now, executedEndTime: now }
        },
        intentEntityInfo: {
          entityId: id, entityName: 'Contact', name: name,
          icon: `data:image/png;base64,${new util.Base64Helper().encodeToStringSync(bytes)}`,
          phoneNumbers: [],
          extras: {
            shareParams: {
              bundleName: BuildProfile.BUNDLE_NAME, moduleName: 'entry', abilityName: 'EntryAbility',
              action: 'ohos.want.action.sendData'
            }
          }
        }
      };
      await insightIntent.shareIntent(context, [intent]);
    } catch (error) {
      hilog.warn(0, 'LocalChat', 'Share contact recommendation unavailable: %{public}s', JSON.stringify(error));
    }
  }

  static async remove(context: common.UIAbilityContext, id: string): Promise<void> {
    try { await insightIntent.deleteEntity(context, 'Contact', [id]); }
    catch (error) {
      hilog.warn(0, 'LocalChat', 'Share contact removal unavailable: %{public}s', JSON.stringify(error));
    }
  }
}
