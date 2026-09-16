/**
 * ChapterMemoryIndexer 单元测试(v46 分级记忆索引)
 *
 * 覆盖:
 * - parseChapterEntities:v46 新格式头部行 / 旧格式 Markdown 段回退 / 空输入
 * - buildEntityIndex:同实体跨章节合并、person→place→time 排序、按章节数降序
 * - groupChaptersByEntity:按实体分组且按涉及章节数降序
 * - matchEntities / matchEntityChapterIds:ASCII 忽略大小写、中文精确包含、章节去重
 * - serializeEntityIndex / parseEntityIndexJson:往返一致、损坏 JSON 兜底
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  parseChapterEntities,
  buildEntityIndex,
  groupChaptersByEntity,
  matchEntities,
  matchEntityChapterIds,
  serializeEntityIndex,
  parseEntityIndexJson,
  ChapterEntities,
  EntityIndex,
  EntityChapterGroup,
  EntityIndexEntry
} from '../main/ets/services/ChapterMemoryIndexer';
import { createChatMemory, ChatMemory } from '../main/ets/models/ChatMemory';

function makeChapter(id: string, summary: string, createdAt: number): ChatMemory {
  return createChatMemory(id, 'chat1', 'branch1', 's', 'e', 0, 9, summary, createdAt);
}

export default function chapterMemoryIndexerTest() {
  describe('ChapterMemoryIndexer', () => {
    it('parse_new_format_header_lines', 0, () => {
      const summary: string =
        '参与者: 张三(主角), 李四\n'
        + '地点: 酒馆\n'
        + '时间: 第三夜\n\n'
        + '## 关键事件\n发生了一些事';
      const entities: ChapterEntities = parseChapterEntities(summary);
      expect(entities.persons.length).assertEqual(2);
      expect(entities.persons[0]).assertEqual('张三');
      expect(entities.persons[1]).assertEqual('李四');
      expect(entities.places.length).assertEqual(1);
      expect(entities.places[0]).assertEqual('酒馆');
      expect(entities.times.length).assertEqual(1);
      expect(entities.times[0]).assertEqual('第三夜');
    });

    it('parse_fullwidth_colon_and_identity_stripped', 0, () => {
      const summary: string =
        '参与者：张三（主角）、李四\n'
        + '地点：迷雾森林\n'
        + '时间：次日清晨';
      const entities: ChapterEntities = parseChapterEntities(summary);
      expect(entities.persons.join(',')).assertEqual('张三,李四');
      expect(entities.places.join(',')).assertEqual('迷雾森林');
      expect(entities.times.join(',')).assertEqual('次日清晨');
    });

    it('parse_legacy_markdown_sections', 0, () => {
      const summary: string =
        '## 时间与地点\n第三夜。地点是酒馆\n\n'
        + '## 参与者\n张三、李四\n\n'
        + '## 关键事件\n发生了一些事';
      const entities: ChapterEntities = parseChapterEntities(summary);
      expect(entities.persons.join(',')).assertEqual('张三,李四');
      // 旧格式:取时间与地点段的首句(到句号为止)作为时间
      expect(entities.times.join(',')).assertEqual('第三夜');
      // 旧格式不解析地点
      expect(entities.places.length).assertEqual(0);
    });

    it('parse_empty_returns_empty', 0, () => {
      const entities: ChapterEntities = parseChapterEntities('');
      expect(entities.persons.length).assertEqual(0);
      expect(entities.places.length).assertEqual(0);
      expect(entities.times.length).assertEqual(0);
    });

    it('parse_no_entities_returns_empty', 0, () => {
      const entities: ChapterEntities = parseChapterEntities('## 关键事件\n毫无信息量的普通文本');
      expect(entities.persons.length).assertEqual(0);
      expect(entities.times.length).assertEqual(0);
    });

    it('build_index_merges_same_entity_across_chapters', 0, () => {
      const chapters: ChatMemory[] = [
        makeChapter('a', '参与者: 张三(主角)\n地点: 酒馆\n时间: 第一夜', 100),
        makeChapter('b', '参与者: 张三、王五\n地点: 酒馆\n时间: 第二夜', 200)
      ];
      const index: EntityIndex = buildEntityIndex(chapters);
      // 找到张三
      let zhang: EntityIndexEntry | undefined = undefined;
      for (let i = 0; i < index.entries.length; i++) {
        if (index.entries[i].name === '张三') {
          zhang = index.entries[i];
        }
      }
      expect(zhang === undefined).assertFalse();
      expect(zhang!.chapterIds.join(',')).assertEqual('a,b');
    });

    it('build_index_sorted_person_place_time', 0, () => {
      const chapters: ChatMemory[] = [
        makeChapter('a', '参与者: 张三\n地点: 酒馆\n时间: 第一夜', 100)
      ];
      const index: EntityIndex = buildEntityIndex(chapters);
      expect(index.entries.length).assertEqual(3);
      expect(index.entries[0].kind).assertEqual('person');
      expect(index.entries[0].name).assertEqual('张三');
      expect(index.entries[1].kind).assertEqual('place');
      expect(index.entries[1].name).assertEqual('酒馆');
      expect(index.entries[2].kind).assertEqual('time');
      expect(index.entries[2].name).assertEqual('第一夜');
    });

    it('group_chapters_by_entity_sorted_by_count_desc', 0, () => {
      const chapters: ChatMemory[] = [
        makeChapter('a', '参与者: 张三\n地点: 酒馆\n时间: 第一夜', 100),
        makeChapter('b', '参与者: 张三、李四\n地点: 酒馆\n时间: 第二夜', 200)
      ];
      const groups: EntityChapterGroup[] = groupChaptersByEntity(chapters);
      // 张三 2 章、酒馆 2 章排在前面;李四 1 章存在于分组中
      expect(groups[0].name).assertEqual('张三');
      expect(groups[0].chapters.length).assertEqual(2);
      expect(groups[1].name).assertEqual('酒馆');
      expect(groups[1].chapters.length).assertEqual(2);
      // 降序:前两组章节数不少于后续组
      expect(groups[0].chapters.length).assertLargerOrEqual(groups[2].chapters.length);
      let lisi: EntityChapterGroup | undefined = undefined;
      for (let i = 0; i < groups.length; i++) {
        if (groups[i].name === '李四') {
          lisi = groups[i];
        }
      }
      expect(lisi === undefined).assertFalse();
      expect(lisi!.chapters.length).assertEqual(1);
    });

    it('match_entities_ascii_case_insensitive', 0, () => {
      const index: EntityIndex = buildEntityIndex([
        makeChapter('a', '参与者: Alice\n地点: Tavern\n时间: Night1', 100)
      ]);
      const matched: string[] = matchEntities(index, ['hello alice, meet at tavern']);
      expect(matched.length).assertLarger(0);
      expect(matched.includes('Alice')).assertTrue();
      expect(matched.includes('Tavern')).assertTrue();
    });

    it('match_entities_chinese_exact_contain', 0, () => {
      const index: EntityIndex = buildEntityIndex([
        makeChapter('a', '参与者: 张三\n地点: 酒馆\n时间: 第三夜', 100)
      ]);
      const matched: string[] = matchEntities(index, ['张三来到了酒馆']);
      expect(matched.includes('张三')).assertTrue();
      expect(matched.includes('酒馆')).assertTrue();
      expect(matched.includes('第三夜')).assertFalse();
    });

    it('match_entity_chapter_ids_deduplicated', 0, () => {
      const index: EntityIndex = buildEntityIndex([
        makeChapter('a', '参与者: 张三、李四\n地点: 酒馆\n时间: 第一夜', 100)
      ]);
      const ids: string[] = matchEntityChapterIds(index, ['张三和李四都在酒馆']);
      expect(ids.length).assertEqual(1);
      expect(ids[0]).assertEqual('a');
    });

    it('serialize_parse_roundtrip', 0, () => {
      const index: EntityIndex = buildEntityIndex([
        makeChapter('a', '参与者: 张三\n地点: 酒馆\n时间: 第一夜', 100)
      ]);
      const json: string = serializeEntityIndex(index);
      const parsed: EntityIndex = parseEntityIndexJson(json);
      expect(parsed.entries.length).assertEqual(index.entries.length);
      expect(parsed.entries[0].name).assertEqual(index.entries[0].name);
      expect(parsed.entries[0].chapterIds.join(',')).assertEqual(index.entries[0].chapterIds.join(','));
    });

    it('parse_invalid_json_returns_empty', 0, () => {
      const index: EntityIndex = parseEntityIndexJson('not-json');
      expect(index.entries.length).assertEqual(0);
      const empty: EntityIndex = parseEntityIndexJson('');
      expect(empty.entries.length).assertEqual(0);
    });
  });
}
