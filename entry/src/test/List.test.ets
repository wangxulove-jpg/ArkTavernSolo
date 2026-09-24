/**
 * 本地单元测试入口(List.test.ets)
 * 由 hvigor test 的本地测试运行器加载。
 */

import promptSegmentOrderTest from './prompt_segment_order.test';
import lorebookActivationTest from './lorebook_activation.test';
import lorebookStickyServiceTest from './lorebook_sticky_service.test';
import chapterMemoryIndexerTest from './chapter_memory_indexer.test';
import memoryLoadRefServiceTest from './memory_load_ref_service.test';
import statusSchemaTest from './status_schema.test';

export default function testsuite() {
  promptSegmentOrderTest();
  lorebookActivationTest();
  lorebookStickyServiceTest();
  chapterMemoryIndexerTest();
  memoryLoadRefServiceTest();
  statusSchemaTest();
}