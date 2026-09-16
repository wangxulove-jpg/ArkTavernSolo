/**
 * 本地单元测试入口(List.test.ets)
 * 由 hvigor test 的本地测试运行器加载。
 */

import promptSegmentOrderTest from './prompt_segment_order.test';
import lorebookActivationTest from './lorebook_activation.test';

export default function testsuite() {
  promptSegmentOrderTest();
  lorebookActivationTest();
}