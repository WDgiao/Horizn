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
