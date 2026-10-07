---
tags: [类型/实践, 技术/MySQL]
aliases: [执行计划]
created: 2026-10-06
updated: 2026-10-06
---
> 在 SQL 前面加 `EXPLAIN`，MySQL 不执行它，只告诉你打算怎么执行：走哪个索引、预计读多少行、要不要额外排序。排查慢查询先看四列：`type`（访问方式）、`key`（实际用的索引）、`rows`（预计读的行数）、`Extra`（附加动作）；想看真实耗时，用 `EXPLAIN ANALYZE`。

## 典型场景：这条 SQL 到底走没走索引

接口变慢了，日志里抓到一条 SQL：

```sql
SELECT * FROM tb_user WHERE phone = 13800054321;
```

`phone` 列明明建了索引，SQL 看着也没毛病，可它就是慢。光看 SQL 文本判断不了 MySQL 实际怎么执行它，但加个 `EXPLAIN` 就能看到：

```sql
EXPLAIN SELECT * FROM tb_user WHERE phone = 13800054321;
```

```text
+----+-------------+---------+------------+------+---------------+------+---------+------+-------+----------+-------------+
| id | select_type | table   | partitions | type | possible_keys | key  | key_len | ref  | rows  | filtered | Extra       |
+----+-------------+---------+------------+------+---------------+------+---------+------+-------+----------+-------------+
|  1 | SIMPLE      | tb_user | NULL       | ALL  | idx_phone     | NULL | NULL    | NULL | 99909 |    10.00 | Using where |
+----+-------------+---------+------------+------+---------------+------+---------+------+-------+----------+-------------+
1 row in set, 3 warnings
```

`possible_keys` 里有 `idx_phone`，`key` 却是 `NULL`，`type` 是 `ALL`，`rows` 接近 10 万：索引就在那儿，但没用上，在做全表扫描。末尾的 `3 warnings` 是线索，紧跟着执行 `SHOW WARNINGS`：

```text
| Warning | 1739 | Cannot use ref access on index 'idx_phone' due to type or collation conversion on field 'phone' |
| Warning | 1739 | Cannot use range access on index 'idx_phone' due to type or collation conversion on field 'phone' |
```

`phone` 是 `CHAR(11)`，传进来的却是不带引号的数字，发生了类型转换，索引失效。把值改成 `'13800054321'` 就好了（为什么类型转换会让索引失效，见 [[MySQL 索引#建了索引却用不上]]）。

本篇的输出都来自 MySQL 8.4.11，测试表的结构见 [[MySQL 索引#典型场景：按手机号查一个人]]，上面有主键 `id`、单列索引 `idx_phone (phone)` 和联合索引 `idx_city_age_name (city, age, name)`。

## 怎么用

```sql
EXPLAIN SELECT ...;           -- 只看计划，不执行
EXPLAIN ANALYZE SELECT ...;   -- 真的执行，报告每一步实际的耗时和行数
SHOW WARNINGS;                -- 紧跟在 EXPLAIN 后面执行，看优化器的警告和改写后的 SQL
```

普通的 `EXPLAIN` 只生成计划，不执行查询，再慢的 SQL 也是立刻返回。`EXPLAIN ANALYZE` 会**真的执行一遍**，对很慢的查询或者 `UPDATE`/`DELETE` 要小心。

`EXPLAIN` 后面也能接 `UPDATE`、`DELETE`、`INSERT`，最常用的还是 `SELECT`。

## 输出各列

每张表（包括子查询、派生表）对应一行输出。12 列的含义：

| 列 | 含义 | 怎么看 |
| --- | --- | --- |
| `id` | `SELECT` 的编号 | 子查询会有不同的编号 |
| `select_type` | 这个 `SELECT` 的类型 | 普通查询是 `SIMPLE` |
| `table` | 这一行说的是哪张表 | 别名、`<subquery2>` 这类派生表也会出现在这里 |
| `partitions` | 命中的分区 | 没用分区表时是 `NULL` |
| `type` | **访问方式** | 重点看，见下一节 |
| `possible_keys` | 可能用到的索引 | 候选名单 |
| `key` | **实际用的索引** | `NULL` 就是没用索引 |
| `key_len` | 用到的索引长度（字节） | 联合索引里用上了几列，见后文 |
| `ref` | 跟索引比较的是什么 | `const` 表示常量，`库.表.列` 表示来自别的表 |
| `rows` | **预计要读的行数** | 估算值，不是精确值 |
| `filtered` | 预计有百分之几的行能通过剩下的条件 | 估算值 |
| `Extra` | **附加信息** | 重点看，见后文 |

`possible_keys` 和 `key` 要对照着看：

- `possible_keys` 有值、`key` 为 `NULL`：有候选索引，但优化器没用。可能是成本上不划算（命中行太多），也可能是写法让索引失效（比如上面的类型转换）
- 两个都是 `NULL`：根本没有能用的索引，考虑建一个

## type：访问方式，从好到坏

`type` 说的是 MySQL 怎么在这张表里找行。常见的几种，从快到慢：

| type | 含义 | 本表的例子 |
| --- | --- | --- |
| `system` | 表里只有一行，`const` 的特例 | — |
| `const` | 用主键或唯一索引等值查找，最多一行 | `WHERE id = 54321` |
| `eq_ref` | 联表时，对前一张表的每一行，用主键或唯一非空索引在这张表里只找到一行 | `JOIN tb_user u ON u.id = o.user_id` |
| `ref` | 用普通索引（或唯一索引的最左前缀）等值查找，可能有多行 | `WHERE phone = '13800054321'` |
| `range` | 用索引扫描一个范围 | `WHERE id BETWEEN 100 AND 200` |
| `index` | 把整棵索引树从头扫到尾 | `SELECT phone FROM tb_user` |
| `ALL` | 全表扫描 | `WHERE age = 30` |

还有几种不常见的：`fulltext`（用全文索引）、`ref_or_null`（类似 `ref`，额外找 `NULL` 值）、`index_merge`（同时用多个索引再合并结果）、`unique_subquery` 和 `index_subquery`（某些 `IN` 子查询）。

几个实测输出，对照着看：

```sql
EXPLAIN SELECT * FROM tb_user WHERE id = 54321;
EXPLAIN SELECT * FROM tb_user WHERE id BETWEEN 100 AND 200;
EXPLAIN SELECT phone FROM tb_user;
```

```text
| type  | possible_keys | key       | key_len | ref   | rows  | Extra       |
| const | PRIMARY       | PRIMARY   | 4       | const |     1 | NULL        |
| range | PRIMARY       | PRIMARY   | 4       | NULL  |   101 | Using where |
| index | NULL          | idx_phone | 44      | NULL  | 99909 | Using index |
```

第三条没有 `WHERE`，要读全部 10 万行，`type` 却是 `index` 而不是 `ALL`。因为只要 `phone` 这一列，`idx_phone` 里就有，而且二级索引比整张表小得多（见 [[MySQL 索引#二级索引与回表]]），扫索引比扫表读的页少。`index` 只是比 `ALL` 好一点，本质上还是全扫。

联表时每张表各占一行：

```sql
EXPLAIN SELECT o.id, u.name FROM tb_order o JOIN tb_user u ON u.id = o.user_id;
```

```text
| table | type   | possible_keys | key     | key_len | ref            | rows |
| o     | ALL    | NULL          | NULL    | NULL    | NULL           | 2000 |
| u     | eq_ref | PRIMARY       | PRIMARY | 4       | demo.o.user_id |    1 |
```

读法：先全表扫 `tb_order` 的 2000 行，每一行拿 `user_id`（`ref` 列的 `demo.o.user_id`）到 `tb_user` 的主键里找 1 行。总共要读的行数大约是各行 `rows` 相乘，这里是 2000 × 1。

**判断标准**：一般要求至少到 `range`，最好到 `ref`。`ALL` 和 `index` 出现在大表上，就要找原因。但也有例外：小表全扫很正常；命中大部分行的查询，优化器会主动选 `ALL`，因为这时候顺序读比走索引再回表更快。

## key_len：用上了联合索引的几列

对联合索引来说，`key` 只告诉你用了哪个索引，用上了**几列**要看 `key_len`。它是用到的索引列的字节数之和，每列的字节数这样算（字符集是 `utf8mb4`，每个字符按最多 4 字节算）：

| 列类型 | 字节数 | 本表实测 |
| --- | --- | --- |
| `INT` | 4 | `id`、`age`：4 |
| `CHAR(n)` | n × 4 | `phone CHAR(11)`：44 |
| `VARCHAR(n)` | n × 4 + 2（2 字节记录实际长度） | `city VARCHAR(16)`：66；`name VARCHAR(32)`：130 |
| 允许 `NULL` 的列 | 在上面基础上 + 1（1 字节标记是否为 NULL） | `VARCHAR(16) NULL`：67 |

`NULL` 那一行是另建了一张表验证的：

```sql
CREATE TABLE t_len (a VARCHAR(16) NULL, b VARCHAR(16) NOT NULL, c CHAR(16) NOT NULL,
                    KEY ka (a), KEY kb (b), KEY kc (c));
EXPLAIN SELECT * FROM t_len WHERE a = 'x';   -- key_len 67
EXPLAIN SELECT * FROM t_len WHERE b = 'x';   -- key_len 66
EXPLAIN SELECT * FROM t_len WHERE c = 'x';   -- key_len 64
```

于是 `idx_city_age_name (city, age, name)` 的 `key_len`：

| key_len | 算式 | 用上的列 |
| --- | --- | --- |
| 66 | 66 | `city` |
| 70 | 66 + 4 | `city`、`age` |
| 200 | 66 + 4 + 130 | 三列全用上 |

实际用法：建了 `(city, age, name)`，`WHERE` 里三列都给了，`key_len` 却是 66，说明只有 `city` 在帮忙定位，后两列为什么没用上，要按最左前缀原则去查，见 [[MySQL 联合索引]]。

## rows 和 filtered 是估算

`rows` 是优化器根据统计信息**估**出来的，不是真实数字。用 `COUNT(*)` 对比一下就知道差多少：

```sql
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州';
-- rows: 24450

SELECT COUNT(*) FROM tb_user WHERE city = '杭州';
-- 12500
```

估了 24450，实际 12500，差了将近一倍。所以 `rows` 只用来看数量级：几行、几千行还是几十万行。拿它跟另一个执行计划的 `rows` 比较是合理的，当成精确值用就不对了。

估算偏差太大，可能让优化器选错索引。统计信息过时的时候，可以执行 `ANALYZE TABLE 表名` 重新收集。

`filtered` 是另一个估算：通过 `key` 找到的 `rows` 行里，预计有百分之几能满足剩下的条件。`rows × filtered%` 约等于这张表最终交给下一步的行数。

## Extra：附加动作

`Extra` 告诉你除了按 `type` 找行之外，MySQL 还额外做了什么。常见的几个：

| Extra | 含义 | 好坏 |
| --- | --- | --- |
| `Using index` | 只读索引就拿到了所有列，没有回表（覆盖索引） | 好 |
| `Using index condition` | 用上了索引条件下推，先用索引里的列过滤，再回表 | 好 |
| `Using where` | 读出行之后，还要用 `WHERE` 条件过滤一遍 | 中性 |
| `Using filesort` | 不能按索引顺序直接输出，需要额外排一次序 | 大结果集上要注意 |
| `Using temporary` | 要建临时表来存中间结果，常见于 `GROUP BY` | 大结果集上要注意 |
| `Using index for skip scan` | 用上了跳跃扫描 | 能用，但条件苛刻 |

`Using index` 和 `Using index condition` 名字很像，意思完全不同：前者是**不回表**，后者是**少回表**。两者的原理分别见 [[MySQL 索引#覆盖索引：不回表的查询]] 和 [[MySQL 联合索引#索引条件下推]]。

`Using where` 本身不说明好坏。官方文档提醒的是反过来的情况：`type` 是 `ALL` 或 `index`，`Extra` 里却**没有** `Using where`，说明在读整张表又不过滤，除非你就是要全部数据，否则 SQL 可能写错了。

排序和分组的几个实测：

```sql
EXPLAIN SELECT * FROM tb_user ORDER BY created_at LIMIT 10;
EXPLAIN SELECT city, COUNT(*) FROM tb_user GROUP BY city;
EXPLAIN SELECT age,  COUNT(*) FROM tb_user GROUP BY age;
EXPLAIN SELECT name, COUNT(*) FROM tb_user GROUP BY name ORDER BY COUNT(*) DESC LIMIT 5;
```

```text
| type  | key               | rows  | Extra                                        |
| ALL   | NULL              | 99909 | Using filesort                               |   ← created_at 没索引，只能排序
| index | idx_city_age_name | 99909 | Using index                                  |   ← 按 city 分组，索引本来就按 city 排好
| index | idx_city_age_name | 99909 | Using index; Using temporary                 |   ← age 在索引里不是按顺序排的，要临时表分组
| index | idx_city_age_name | 99909 | Using index; Using temporary; Using filesort |   ← 分组用临时表，按 COUNT(*) 排序还要再排一次
```

第二条和第三条用的是同一个索引，差别只在分组的列：`city` 是联合索引的最左列，相同城市的行在索引里是挨在一起的，扫一遍就能数完；`age` 排在第二列，相同年龄的行分散在各个城市里，只能建临时表一边扫一边累计。

## EXPLAIN ANALYZE：看真实耗时

普通 `EXPLAIN` 只是计划，`EXPLAIN ANALYZE` 会真的执行，然后用树形格式报告每一步：

```sql
EXPLAIN ANALYZE SELECT * FROM tb_user WHERE city = '杭州' ORDER BY name LIMIT 10;
```

```text
-> Limit: 10 row(s)  (cost=2758 rows=10) (actual time=8.62..8.63 rows=10 loops=1)
    -> Sort: tb_user.`name`, limit input to 10 row(s) per chunk  (cost=2758 rows=24450) (actual time=8.62..8.63 rows=10 loops=1)
        -> Index lookup on tb_user using idx_city_age_name (city='杭州')  (cost=2758 rows=24450) (actual time=0.511..7.89 rows=12500 loops=1)
```

**读法：缩进最深的先执行，从下往上看。** 每一行是一个步骤，括号里分两组：

- `(cost=… rows=…)`：优化器的估算，和普通 `EXPLAIN` 的 `rows` 是同一个东西
- `(actual time=A..B rows=N loops=L)`：实际执行的结果。`A` 是返回第一行的耗时，`B` 是这一步全部完成的耗时，单位毫秒；`N` 是实际返回的行数；`loops` 是这一步执行了几次（联表时内层表会执行多次，这时 time 是每次的平均值）

上面这个例子从下往上读：

1. 用 `idx_city_age_name` 找 `city = '杭州'`，估计 24450 行，**实际 12500 行**，耗时 7.89 毫秒
2. 按 `name` 排序（就是普通 `EXPLAIN` 里的 `Using filesort`），只保留前 10 行
3. `LIMIT` 输出 10 行，总耗时 8.63 毫秒

时间大部分花在第 1 步，读了 12500 行只为最后要 10 行。如果这是高频查询，加一个 `(city, name)` 的索引，杭州这一段在索引里本来就按 `name` 排好了：

```sql
CREATE INDEX idx_city_name ON tb_user (city, name);
EXPLAIN ANALYZE SELECT * FROM tb_user WHERE city = '杭州' ORDER BY name LIMIT 10;
```

```text
-> Limit: 10 row(s)  (cost=2725 rows=10) (actual time=0.189..0.19 rows=10 loops=1)
    -> Index lookup on tb_user using idx_city_name (city='杭州')  (cost=2725 rows=24126) (actual time=0.189..0.189 rows=10 loops=1)
```

`Sort` 那一步没了，索引查找读到第 10 行就停（`rows=10`），耗时从 8.63 毫秒降到 0.19 毫秒。

估算行数和实际行数差得多的那一步，是优化器可能选错的地方，普通 `EXPLAIN` 看不出这种偏差。

`EXPLAIN ANALYZE` 只支持这种树形格式。普通 `EXPLAIN` 也可以用 `EXPLAIN FORMAT=TREE` 输出同样的树形结构（只是没有 `actual` 那一组），另外还支持 `FORMAT=JSON`。

## 排查流程

拿到一条慢 SQL，按这个顺序看：

1. **`EXPLAIN` 一下，先看 `type`**：大表出现 `ALL` 或 `index`，就是在全扫
2. **再看 `key`**：是不是你期望的那个索引？`possible_keys` 有候选但 `key` 是 `NULL`，紧跟着 `SHOW WARNINGS` 看有没有类型转换这类提示，再对照 [[MySQL 索引#建了索引却用不上]] 里那几种写法
3. **联合索引看 `key_len`**：算一下用上了几列，跟预期不符就按 [[MySQL 联合索引]] 的最左前缀原则查
4. **看 `rows`**：数量级是否合理
5. **看 `Extra`**：大结果集上的 `Using filesort`、`Using temporary` 往往是耗时大头；有没有机会变成 `Using index`
6. **改完再 `EXPLAIN ANALYZE`**：用实际耗时和实际行数确认真的变快了

## 参考

- [MySQL 8.4 Reference Manual: EXPLAIN Output Format](https://dev.mysql.com/doc/refman/8.4/en/explain-output.html)
- [MySQL 8.4 Reference Manual: EXPLAIN Statement](https://dev.mysql.com/doc/refman/8.4/en/explain.html)
