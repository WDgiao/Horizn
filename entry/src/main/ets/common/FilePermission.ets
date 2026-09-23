import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';

/** 扫描公共目录所需的运行时权限 */
export const SCAN_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY'
];

/**
 * 申请公共目录读取权限
 * 注意：应用自身沙箱目录（filesDir / cacheDir）无需任何权限即可访问，
 * 因此即使用户拒绝授权，沙箱内的媒体文件依然可以被搜索到。
 *
 * @param context 应用上下文
 * @returns 是否全部授权通过
 */
export async function requestScanPermissions(context: common.Context): Promise<boolean> {
  try {
    const atManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(context, SCAN_PERMISSIONS);
    const codes: number[] = result.authResults;
    for (let i = 0; i < codes.length; i++) {
      if (codes[i] !== 0) {
        return false;
      }
    }
    return true;
  } catch (err) {
    return false;
  }
}
