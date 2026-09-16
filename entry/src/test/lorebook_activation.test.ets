/**
 * 世界书激活方式枚举测试(v45: 新增 OnDemandPinned 按需锁定)
 *
 * 验证:
 * - 枚举值字符串与持久化格式一致
 * - 新老模式互斥且都存在
 */

import { describe, it, expect } from '@ohos/hypium';
import { LorebookActivationMode, isValidActivationMode } from '../main/ets/models/Lorebook';

export default function lorebookActivationTest() {
  describe('LorebookActivationMode', () => {
    it('on_demand_pinned_has_persisted_value', 0, () => {
      expect(LorebookActivationMode.OnDemandPinned).assertEqual('OnDemandPinned');
    });

    it('on_demand_pinned_passes_validation', 0, () => {
      expect(isValidActivationMode(LorebookActivationMode.OnDemandPinned)).assertTrue();
      expect(isValidActivationMode(LorebookActivationMode.FollowGlobal)).assertTrue();
      expect(isValidActivationMode(LorebookActivationMode.FullInject)).assertTrue();
      expect(isValidActivationMode(LorebookActivationMode.OnDemand)).assertTrue();
      // 非法字符串应被拒绝
      expect(isValidActivationMode('Whatever' as LorebookActivationMode)).assertFalse();
    });

    it('legacy_modes_unchanged', 0, () => {
      expect(LorebookActivationMode.FollowGlobal).assertEqual('FollowGlobal');
      expect(LorebookActivationMode.FullInject).assertEqual('FullInject');
      expect(LorebookActivationMode.OnDemand).assertEqual('OnDemand');
    });

    it('all_modes_distinct', 0, () => {
      const values: string[] = [
        LorebookActivationMode.FollowGlobal,
        LorebookActivationMode.FullInject,
        LorebookActivationMode.OnDemand,
        LorebookActivationMode.OnDemandPinned
      ];
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < values.length; i++) {
        expect(seen.has(values[i])).assertFalse();
        seen.add(values[i]);
      }
    });
  });
}
