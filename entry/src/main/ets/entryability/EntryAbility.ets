import { MessageNotifications } from '../notifications/MessageNotifications';
import { ChatStore } from '../store/ChatStore';
import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private notifications?: MessageNotifications;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const store = ChatStore.shared(this.context);
    this.notifications = new MessageNotifications(this.context, store);
    this.handleWant(want);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  private handleWant(want: Want): void {
    const peer = want.parameters?.chatPeer;
    if (typeof peer === 'string') { ChatStore.shared(this.context).openFromNotification(peer); }
  }
  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void { this.handleWant(want); }
  onDestroy(): void {
    ChatStore.shared(this.context).stop();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      this.notifications?.enable();
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    ChatStore.shared(this.context).setForeground(true);
    // Ability has brought to foreground
    ChatStore.shared(this.context).start();
    ChatStore.shared(this.context).refresh();
  }

  onBackground(): void {
    ChatStore.shared(this.context).setForeground(false);
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}