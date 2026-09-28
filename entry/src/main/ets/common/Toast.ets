import { UIContext } from '@kit.ArkUI';

/** 当前 UI 上下文，由入口页面在启动时注入 */
let uiContext: UIContext | undefined = undefined;

/**
 * 注入 UI 上下文
 * UIContext.getPromptAction() 是官方推荐的调用方式，
 * 直接使用 @ohos.promptAction 的全局 showToast 已废弃。
 * @param ctx 当前 UI 上下文
 */
export function initToast(ctx: UIContext): void {
  uiContext = ctx;
}

/**
 * 单按钮的信息对话框（只有一个「知道了」）
 *
 * ★ 2026-09-29 自检新增：原先 StartupNotice.ets 自己又存了一份 uiContext，
 *   于是同一个东西在 Process 里有两个来源（initToast / initStartupNotice），
 *   谁先谁后、哪个更新，全靠调用方自觉 —— 这类"同一事实存两份"
 *   迟早会分叉（比如以后某个页面只调了其中一个）。
 *   统一收敛到这里：需要弹系统对话框就都走这一个上下文。
 *
 * @param title 标题
 * @param message 正文
 * @param buttonText 按钮文字
 */
export async function showInfoDialog(title: string, message: string,
                                     buttonText: string): Promise<void> {
  if (uiContext === undefined) {
    // 上下文还没注入：说明调用时机不对。
    // 不抛错 —— 一句提示弹不出来不该影响主流程
    throw new Error('UIContext not initialized');
  }
  await uiContext.getPromptAction().showDialog({
    title: title,
    message: message,
    buttons: [
      { text: buttonText, color: '#007DFF' }
    ]
  });
}

/**
 * 业务代码能否使用对话框（UI 上下文是否已注入）
 *
 * 供 StartupNotice 这类"上下文没准备好就静默跳过"的模块判断用，
 * 避免它们自己去读一个私有的 uiContext 副本。
 */
export function isPromptReady(): boolean {
  return uiContext !== undefined;
}

/**
 * 确认对话框
 * 用 UIContext 的 PromptAction 弹系统对话框，比自定义对话框更稳
 * @param title 标题
 * @param message 正文
 * @returns 用户是否点了「确定」
 */
export async function confirmDialog(title: string, message: string): Promise<boolean> {
  if (uiContext === undefined) {
    return false;
  }
  try {
    const result = await uiContext.getPromptAction().showDialog({
      title: title,
      message: message,
      buttons: [
        { text: '取消', color: '#8E8E93' },
        { text: '确定', color: '#007DFF' }
      ]
    });
    // index 0 是「取消」，1 是「确定」
    return result.index === 1;
  } catch (err) {
    return false;
  }
}

/**
 * 全局轻提示
 * 供各个页面调用，逻辑等同于原型的 showToast(text)
 * @param text 提示内容
 */
export function showToast(text: string): void {
  try {
    if (uiContext === undefined) {
      return;
    }
    uiContext.getPromptAction().showToast({
      message: text,
      duration: 1600,
      bottom: 120
    });
  } catch (err) {
    // 提示失败不应影响主流程，静默忽略
  }
}
