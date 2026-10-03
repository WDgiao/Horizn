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
 * 信息对话框（只有一个「知道了」按钮）
 *
 * 与 confirmDialog 的区别：
 *   那个是"要不要做某件事"，必须给取消/确定两个出口；
 *   这个是"给你看一段信息"，多一个取消键反而让人以为点错了。
 * 用在「关于」这类纯展示的地方（由用户主动点击触发，
 * 与之前那个开机自动弹出的提示不是一回事）。
 *
 * ★ 为什么必须把 UIContext 传进来，而不是用本模块缓存的那个 ★
 *   实测（Mate 80）：toast 用缓存的 uiContext 完全正常（系统日志里有
 *   "Toast node mount to root node"），但 showDialog 用同一个缓存上下文
 *   时**对话框根本不出现**，而且异常被 catch 吞掉、表面上什么都不发生。
 *   toast 是全局浮层，对话框要挂在具体 UI 实例上 —— 缓存的那个上下文
 *   属于入口页，早就不是当前可见实例了。
 *   所以这里要求调用方传"自己页面的 UIContext"。
 *
 * @param ctx 调用方页面的 UIContext（用 this.getUIContext() 取）
 * @param title 标题
 * @param message 正文
 */
export async function infoDialog(ctx: UIContext, title: string, message: string): Promise<void> {
  if (ctx === undefined) {
    return;
  }
  try {
    await ctx.getPromptAction().showDialog({
      title: title,
      message: message,
      buttons: [
        { text: '知道了', color: '#007DFF' }
      ]
    });
  } catch (err) {
    // 不静默吞掉：对话框失败时至少留下可查的日志
    console.error('infoDialog failed: ' + JSON.stringify(err));
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
