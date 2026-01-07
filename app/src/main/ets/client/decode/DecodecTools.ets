// DecodecTools - 解码器工具类
// HarmonyOS版本实现

export class DecodecTools {
  private static isSupportOpusValue: boolean | null = null;
  private static isSupportH265Value: boolean | null = null;

  // HarmonyOS支持的解码器
  // 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/avcodec-support-formats-V5
  static isSupportOpus(): boolean {
    if (DecodecTools.isSupportOpusValue !== null) {
      return DecodecTools.isSupportOpusValue;
    }

    // HarmonyOS API 12+ 支持 Opus 解码
    // 参考官方文档，HarmonyOS 支持 Opus 音频解码
    DecodecTools.isSupportOpusValue = true;
    return DecodecTools.isSupportOpusValue;
  }

  static isSupportH265(): boolean {
    if (DecodecTools.isSupportH265Value !== null) {
      return DecodecTools.isSupportH265Value;
    }

    // HarmonyOS 支持 H.265/HEVC 硬件解码
    // 大部分HarmonyOS设备都支持H.265解码
    DecodecTools.isSupportH265Value = true;
    return DecodecTools.isSupportH265Value;
  }

  // HarmonyOS使用统一的OH_VideoDecoder API
  // 不需要像Android那样选择特定的解码器名称
  static getVideoDecoder(h265: boolean): string {
    // HarmonyOS 自动选择最优解码器
    return h265 ? 'OH_HEVC_Decoder' : 'OH_AVC_Decoder';
  }

  // 检查是否支持H264/AVC（几乎所有设备都支持）
  static isSupportH264(): boolean {
    return true;
  }
}
