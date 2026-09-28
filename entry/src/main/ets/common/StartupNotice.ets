/**
 * 启动提示：早期阶段说明
 *
 * 为什么要有这个弹窗：
 *   这个项目目前只验证了**解码器可用性**，其余功能（UI 设计、交互细节）
 *   大量处于"能跑通就行"的状态，部分格式的进度条拖动等已知有问题。
 *   与其让使用者自己撞上各种粗糙之处再以为软件坏了，
 *   不如启动时先把话说清楚 —— 期望值先对齐，体验反而更好。
 *
 * 实现方式：复用 common/Toast.ets 里的 UIContext（PromptAction），
 *   用系统对话框而不是自绘弹窗 —— 系统的能自动适配深浅色/字号/无障碍，
 *   也不需要自己处理返回键与遮罩。
 */

import { UIContext } from '@kit.ArkUI';

/** 由首页在启动时注入的 UI 上下文 */
let uiContext: UIContext | undefined = undefined;

/**
 * 本次进程内是否已经弹过
 *
 * 为什么要这个标志：首页的 aboutToAppear 正常只跑一次，
 * 但页面重建（例如极端的内存回收后回前台）可能让它再跑一次；
 * 同一句话反复弹会很烦，所以保证一个进程只弹一次。
 * 注意这个"记住"是进程级的、不落盘 —— 下次启动仍会提示，
 * 这对"早期阶段"的说明是合适的（而不是"只提示一次就永不再提"）。
 */
let shownThisSession: boolean = false;

/**
 * 注入 UI 上下文
 * @param ctx 当前 UI 上下文（首页 getUIContext()）
 */
export function initStartupNotice(ctx: UIContext): void {
  uiContext = ctx;
}

/**
 * 早期阶段提示的正文
 *
 * 单独抽成常量是为了方便随时改文案 —— 这个项目还在快速变动，
 * 文案很可能要跟着版本更新，不希望改字还要翻实现代码。
 */
const NOTICE_MESSAGE: string =
  '本项目依然处于极早期阶段，只验证了解码器的可用性。\n\n' +
  '其他功能仍然存在大量 bug，例如部分格式可能存在进度条拖动无效等。\n\n' +
  '由于是早期阶段，UI 设计等几乎全是为了验证功能可用性，而非最终版本。\n\n' +
  '项目目前程序开发仅有 1 人，多日熬夜测试。若感兴趣，感谢支持。';

/**
 * 弹出早期阶段提示
 *
 * 调用时机：首页 aboutToAppear 里 initToast 之后。
 * 之所以不放在 EntryAbility.onCreate：那时 UI 还没起来，
 * PromptAction 拿不到 UIContext，会直接失败。
 */
export async function showStartupNotice(): Promise<void> {
  if (shownThisSession) {
    return;
  }
  const ctx: UIContext | undefined = uiContext;
  if (ctx === undefined) {
    // UI 上下文还没注入：说明调用时机不对。静默跳过而不是抛错 ——
    // 一句提示弹不出来不该影响应用启动
    return;
  }
  shownThisSession = true;
  try {
    await ctx.getPromptAction().showDialog({
      title: '关于本项目',
      message: NOTICE_MESSAGE,
      buttons: [
        {
          text: '我知道了',
          color: '#007DFF'
        }
      ]
    });
  } catch (err) {
    // 对话框弹出失败不影响主流程；把标志还原，下次进首页还可以再试
    shownThisSession = false;
    console.error('showStartupNotice failed: ' + JSON.stringify(err));
  }
}
