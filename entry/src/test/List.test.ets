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
import geminiModelFilterTest from './gemini_model_filter.test';
import frontendSpecV2Test from './frontend_spec_v2.test';
import contextOrderLabelTest from './context_order_label.test';
import frontendInteractionTest from './frontend_interaction.test';
import cardImpresTest from './card_impres.test';
import chatSymbolColorTest from './chat_symbol_color.test';
import stFrontendFallbackTest from './st_frontend_fallback.test';

export default function testsuite() {
  promptSegmentOrderTest();
  lorebookActivationTest();
  lorebookStickyServiceTest();
  chapterMemoryIndexerTest();
  memoryLoadRefServiceTest();
  statusSchemaTest();
  geminiModelFilterTest();
  frontendSpecV2Test();
  contextOrderLabelTest();
  frontendInteractionTest();
  cardImpresTest();
  chatSymbolColorTest();
  stFrontendFallbackTest();
}