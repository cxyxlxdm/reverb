/**
 * 纯字符串 ↔ 对象的转换,放到 **TaskPool 子线程**里做。
 *
 * 只给"一次几百 KB 到几 MB"的场合用(目前是备份的导出/导入)。
 * 为什么只搬这两步而不是整个备份流程:备份的**组装**要读各个 store,
 * 那些对象都住在 UI 线程上,搬不过去;而 `stringify`/`parse` 是纯数据运算,
 * 搬走零语义风险 —— 备份是数据安全相关的路径,能不动的逻辑就不动。
 *
 * 跨线程的那次结构化拷贝是原生实现,比 JS 侧的序列化便宜得多。
 */

/// 带缩进的序列化(备份文件是给人看的,保留 pretty print)。
@Concurrent
export async function stringifyPrettyConcurrent(value: Object): Promise<string> {
  return JSON.stringify(value, null, 2);
}

/// 解析成对象;不是对象(顶层是数组或非法 JSON)则返回 null。
@Concurrent
export async function parseObjectConcurrent(text: string): Promise<Record<string, Object> | null> {
  try {
    const o: Object = JSON.parse(text);
    return Array.isArray(o) ? null : o as Record<string, Object>;
  } catch (e) {
    return null;
  }
}
