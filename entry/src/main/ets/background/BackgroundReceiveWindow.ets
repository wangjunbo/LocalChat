import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

// A bounded handover window for the current LAN session, not a permanent service.
export class BackgroundReceiveWindow {
  private requestId: number = -1;
  private background: boolean = false;
  private generation: number = 0;

  enter(enabled: boolean, checkpoint: () => void): void {
    if (this.background) { return; }
    this.background = true;
    const generation = ++this.generation;
    checkpoint();
    if (!enabled) { return; }
    try {
      const request = backgroundTaskManager.requestSuspendDelay('完成邻聊局域网消息收发及状态保存', () => {
        if (generation !== this.generation || !this.background) { return; }
        // Release before the system suspends us; never repeatedly renew in background.
        try { checkpoint(); } finally { this.release(); }
      });
      this.requestId = request.requestId;
      if (request.actualDelayTime <= 0) { this.release(); return; }
      console.info(`LocalChat: background receive window granted ${request.actualDelayTime} ms`);
    } catch (_) {
      // Quota exhaustion and service errors must not interrupt the Ability lifecycle.
      console.warn('LocalChat: background receive window unavailable');
    }
  }

  leave(): void {
    this.background = false;
    this.generation++;
    this.release();
  }

  private release(): void {
    const id = this.requestId;
    this.requestId = -1;
    if (id === -1) { return; }
    try { backgroundTaskManager.cancelSuspendDelay(id); }
    catch (_) { console.warn('LocalChat: background receive window release unavailable'); }
  }
}
