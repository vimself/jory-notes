---
tags: [类型/概念, 技术/MySQL]
aliases: [最左前缀原则, 最左前缀, 复合索引]
created: 2026-10-06
updated: 2026-10-06
---
> 联合索引 `(a, b, c)` 先按 a 排序，a 相同再按 b，b 相同再按 c，就像电话簿先按姓、再按名。所以它只能从最左边的列开始、一列接一列地用（最左前缀原则）；中间跳过一列，或者某一列用了范围条件，后面的列就没法再帮忙缩小查找范围。

## 典型场景：建了索引，换个条件就全表扫描

用户表有 10 万行，运营后台经常按城市和年龄筛人，于是建了一个三列的联合索引：

```sql
CREATE INDEX idx_city_age_name ON tb_user (city, age, name);
```

按城市查，很快：

```sql
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州';
```

```text
| type | key               | key_len | ref   | rows  | Extra |
| ref  | idx_city_age_name | 66      | const | 24450 | NULL  |
```

可某天加了个「按年龄查」的功能，同一个索引，`age` 明明就在里面：

```sql
EXPLAIN SELECT * FROM tb_user WHERE age = 30;
```

```text
| type | possible_keys | key  | key_len | rows  | Extra       |
| ALL  | NULL          | NULL | NULL    | 99909 | Using where |
```

`type` 是 `ALL`，全表扫描，连 `possible_keys` 都是 `NULL`，优化器根本没把这个索引当候选。

本篇的输出都来自 MySQL 8.4.11，测试表的结构见 [[MySQL 索引#典型场景：按手机号查一个人]]，`EXPLAIN` 各列的含义见 [[MySQL EXPLAIN]]。下面的输出只保留了相关的几列。

## 联合索引怎么排序

**联合索引**（也叫复合索引）是建在多个列上的一个索引。它和单列索引一样是一棵 B+ 树（见 [[MySQL 索引]]），区别在于排序规则：**先按第一列排，第一列相同的再按第二列排，前两列都相同的再按第三列排**。

强制按 `idx_city_age_name` 的顺序读出前几行看看：

```sql
SELECT city, age, name, id
FROM tb_user FORCE INDEX (idx_city_age_name)
ORDER BY city, age, name
LIMIT 6;
```

```text
+--------+-----+-----------+-------+
| city   | age | name      | id    |
+--------+-----+-----------+-------+
| 上海   |  19 | user1     |     1 |
| 上海   |  19 | user10001 | 10001 |
| 上海   |  19 | user1001  |  1001 |
| 上海   |  19 | user10201 | 10201 |
| 上海   |  19 | user10401 | 10401 |
| 上海   |  19 | user10601 | 10601 |
+--------+-----+-----------+-------+
```

城市相同、年龄相同时，`name` 按字符串排序（所以 `user10001` 排在 `user1001` 前面）。把整棵树的叶子摊开，大致是这样：

```text
(上海,19,user1) (上海,19,user10001) ... (上海,20,...) ... (上海,67,...) (北京,18,...) ... (杭州,18,...) ... (杭州,30,...) ...
└──────────────── city = 上海 ─────────────────────────┘ └──── 北京 ──┘     └───────── 杭州 ─────────┘
```

拿电话簿来想最直观：电话簿先按姓排，同姓再按名排。

- 找「姓张的」：翻到张那一段，连续的一片，很快
- 找「姓张、名伟的」：在张那一段里再按名找，更快
- 找「名叫伟的」：所有姓的人里都可能有叫伟的，散落在整本书里，只能从头翻到尾

`WHERE age = 30` 就是第三种情况。在这个索引里，`age = 30` 的行分散在每个城市各自的那一段里，没有一段连续区间可以直接定位。

## 最左前缀原则

上面的规律总结起来就是**最左前缀原则**：联合索引只能从最左边的列开始，按列的顺序连续使用。`(city, age, name)` 能用的前缀只有三种：`(city)`、`(city, age)`、`(city, age, name)`。

用 `EXPLAIN` 里的 `key_len` 能看出到底用上了几列。`key_len` 是用到的索引部分的字节数，本表中 `city` 占 66、`age` 占 4、`name` 占 130（怎么算见 [[MySQL EXPLAIN#key_len：用上了联合索引的几列]]）：

| key_len | 用上的列 |
| --- | --- |
| 66 | `city` |
| 70 | `city` + `age` |
| 200 | `city` + `age` + `name` |

依次实测：

```sql
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州';
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' AND age = 30;
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' AND age = 30 AND name = 'user12';
EXPLAIN SELECT * FROM tb_user WHERE age = 30;
EXPLAIN SELECT * FROM tb_user WHERE age = 30 AND name = 'user12';
```

```text
| type | key               | key_len | ref               | rows  |
| ref  | idx_city_age_name | 66      | const             | 24450 |   ← city
| ref  | idx_city_age_name | 70      | const,const       |   500 |   ← city + age
| ref  | idx_city_age_name | 200     | const,const,const |     1 |   ← 三列全用上
| ALL  | NULL              | NULL    | NULL              | 99909 |   ← 缺了 city
| ALL  | NULL              | NULL    | NULL              | 99909 |   ← 缺了 city
```

每多用上一列，`rows`（估计要读的行数）就少一大截。后两条缺了最左列 `city`，索引完全用不上。

### WHERE 里的书写顺序无所谓

「最左」说的是**索引定义里列的顺序**，不是 `WHERE` 里条件的书写顺序。把条件倒过来写：

```sql
EXPLAIN SELECT * FROM tb_user WHERE name = 'user12' AND age = 30 AND city = '杭州';
```

```text
| type | key               | key_len | ref               | rows |
| ref  | idx_city_age_name | 200     | const,const,const |    1 |
```

和正着写完全一样。优化器会自己重排 `AND` 连接的条件，你不用迁就索引的顺序写 SQL。

### 跳过中间一列

只给 `city` 和 `name`，跳过了 `age`：

```sql
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' AND name = 'user12';
```

```text
| type | key               | key_len | ref   | rows  | filtered | Extra                 |
| ref  | idx_city_age_name | 66      | const | 24450 |    10.00 | Using index condition |
```

`key_len` 是 66，只有 `city` 用来定位。回到电话簿：姓张的那一段里是按名排的，但这里的「名」是 `age`，`name` 排在第三位。没有指定 `age`，杭州这一段里的 `name` 就是乱序的，没法拿它缩小范围。

不过 `Extra` 里的 `Using index condition` 说明 `name` 也不是完全没用上，见下面的[[#索引条件下推]]。

### 范围条件之后的列

把 `age = 30` 换成范围条件 `age > 60`：

```sql
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' AND age > 60 AND name = 'user12';
```

```text
| type  | key               | key_len | rows | Extra                 |
| range | idx_city_age_name | 70      | 1500 | Using index condition |
```

`key_len` 是 70：`city` 和 `age` 用上了，`name` 没有。原因和跳过一列一样：在杭州这一段里，`age > 60` 的行是 `(杭州,62,…)`、`(杭州,64,…)`、`(杭州,66,…)` 依次排下来的（测试数据里杭州的年龄都是偶数）。`name` 只在 `age` 相同的一小段里有序，跨过不同的 `age` 就又乱了，所以 `name = 'user12'` 的行在这个区间里是分散的。

MySQL 官方文档对此的描述是：对 `=`、`<=>`、`IS NULL`，优化器会继续用后面的列确定扫描区间；遇到 `>`、`<`、`>=`、`<=`、`!=`、`<>`、`BETWEEN`、`LIKE` 时，这一列会用上，但后面的列不再参与。

但实测里有个出入。把 `>` 换成 `>=`：

```sql
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' AND age >= 60 AND name = 'user12';
```

```text
| type  | key               | key_len | rows | Extra                 |
| range | idx_city_age_name | 200     | 1989 | Using index condition |
```

在 MySQL 8.4.11 上，`key_len` 显示 200，说明扫描区间的起点用上了 `name`：可以直接从 `(杭州, 60, user12)` 开始扫。但 `rows` 是 1989，比 `>` 的 1500 还多，说明 `name` 并没有帮它跳过 `age > 60` 那一大片，扫的仍然是从起点到杭州这一段末尾的整个区间。

两个结论：一是 `name` 在范围条件之后基本帮不上忙，这一点在设计索引时要考虑进去；二是「后面的列用不上」这类口诀和实际行为会有出入，**以 `EXPLAIN` 的 `key_len` 和 `rows` 为准**。

## 索引条件下推

回到「跳过中间一列」那个例子：`city = '杭州' AND name = 'user12'`。`name` 没法帮忙定位，但它的值就在索引里。

**没有**这个优化时，执行过程是：

1. 在索引里找到一条 `city = '杭州'` 的记录
2. 拿主键回表，读出整行（回表的概念见 [[MySQL 索引#二级索引与回表]]）
3. 交给 MySQL 服务层判断 `name = 'user12'`，不符合就丢掉

杭州有 12500 行，就要回表 12500 次，最后只留下 1 行。

**索引条件下推**（Index Condition Pushdown，简称 ICP）把第 3 步提前了：存储引擎在索引里读到一条记录时，先用索引里已有的列判断 `name = 'user12'`，不符合的直接跳过，**符合的才回表**。回表次数从 12500 降到 1。

`EXPLAIN` 的 `Extra` 显示 **`Using index condition`** 就说明用上了 ICP。几个要点：

- ICP 默认开启，由 `optimizer_switch` 里的 `index_condition_pushdown` 开关控制
- 对 InnoDB 来说，ICP 只用于二级索引。聚簇索引的叶子本来就是整行，不存在回表，下推没有收益
- 适用于 `range`、`ref`、`eq_ref`、`ref_or_null` 这几种访问方式
- 引用子查询、存储函数的条件不能下推

关掉 ICP，用 `EXPLAIN ANALYZE`（真正执行并报告每一步实际读了多少行）对比一下。`SET optimizer_switch` 只影响当前会话：

```sql
SET optimizer_switch = 'index_condition_pushdown=off';
EXPLAIN ANALYZE SELECT * FROM tb_user WHERE city = '杭州' AND name = 'user12';
```

```text
-> Filter: (tb_user.`name` = 'user12')  (cost=557 rows=2445) (actual time=3.86..8.65 rows=1 loops=1)
    -> Index lookup on tb_user using idx_city_age_name (city='杭州')  (cost=557 rows=24450) (actual time=2.08..8.14 rows=12500 loops=1)
```

从下往上读：索引查找交出了 12500 行（每行都回过表），上面的 `Filter` 再把它们筛到 1 行，总共 8.65 毫秒。重新打开 ICP：

```sql
SET optimizer_switch = 'index_condition_pushdown=on';
EXPLAIN ANALYZE SELECT * FROM tb_user WHERE city = '杭州' AND name = 'user12';
```

```text
-> Index lookup on tb_user using idx_city_age_name (city='杭州'), with index condition: (tb_user.`name` = 'user12')  (cost=557 rows=24450) (actual time=1.05..1.05 rows=1 loops=1)
```

`name = 'user12'` 变成了索引查找自带的 `with index condition`，索引查找直接只交出 1 行，耗时 1.05 毫秒。

## 例外：跳跃扫描

开头说 `WHERE age = 30` 用不上索引。但如果查询只要索引里有的列：

```sql
EXPLAIN SELECT city, age, name FROM tb_user WHERE age = 30;
```

```text
| type  | key               | key_len | rows | Extra                                  |
| range | idx_city_age_name | 70      | 9990 | Using where; Using index for skip scan |
```

缺了最左列，索引照样用上了。这是 MySQL 的**跳跃扫描**（skip scan）：既然 `city` 只有 8 个不同的值，那就挨个枚举，转化成 `city = '上海' AND age = 30`、`city = '北京' AND age = 30`……每个城市各做一次范围扫描。

它的适用条件很苛刻，主要几条：

- 只查一张表，不用 `GROUP BY` 或 `DISTINCT`
- 查询用到的列**全部在这个索引里**（上面换成 `SELECT *` 就又变回全表扫描了）
- 被跳过的列后面那一列（这里是 `age`）上要有范围或等值条件

所以别指望它兜底。跳跃扫描由 `optimizer_switch` 的 `skip_scan` 开关控制，默认开启。

## 排序也讲最左前缀

索引的叶子本来就是排好序的，`ORDER BY` 如果正好符合索引的顺序，MySQL 直接按索引顺序读出来就行，不用再排一次。是否额外排序，看 `Extra` 里有没有 **`Using filesort`**（这个名字有误导性，它指的是额外的排序步骤，不一定用到磁盘文件）。

```sql
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' ORDER BY age;
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' AND age = 30 ORDER BY name LIMIT 10;
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' ORDER BY name LIMIT 10;
```

```text
| type | key               | key_len | rows  | Extra          |
| ref  | idx_city_age_name | 66      | 24450 | NULL           |   ← 杭州段内本来就按 age 排好
| ref  | idx_city_age_name | 70      |   500 | NULL           |   ← 杭州、30 岁段内本来就按 name 排好
| ref  | idx_city_age_name | 66      | 24450 | Using filesort |   ← 杭州段内 name 是乱的，要另排
```

判断方法和 `WHERE` 一样：`WHERE` 里用等值固定住的前几列，加上 `ORDER BY` 的列，能不能连成索引的一个最左前缀。`city` 固定 + `ORDER BY age` 连成 `(city, age)`，可以；`city` 固定 + `ORDER BY name` 中间缺了 `age`，不行。

## OR 会打断索引

```sql
EXPLAIN SELECT * FROM tb_user WHERE city = '杭州' OR age = 30;
```

```text
| type | possible_keys     | key  | rows  | Extra       |
| ALL  | idx_city_age_name | NULL | 99909 | Using where |
```

`AND` 是在 `city = '杭州'` 那一段里再筛，`OR` 是两个集合求并：`age = 30` 的那部分人散落在各个城市，用这个索引找不出来，只能全表扫描。可以给 `age` 单独建索引，或者把查询拆成两条再用 `UNION` 合并。

## 怎么设计列的顺序

联合索引的列顺序决定了它能服务哪些查询。设计时按这几条排：

1. **等值查询的列放前面，范围查询的列放后面**。`WHERE city = ? AND age > ?` 建 `(city, age)`，两列都能用上；建成 `(age, city)`，`age` 是范围条件，`city` 就用不上了
2. **最常单独出现的列放最左**。`(city, age)` 能顺带服务只按 `city` 查的场景，不用再单独建 `(city)`，单列索引 `(city)` 就成了多余的
3. **排序列接在等值列后面**。`WHERE city = ? ORDER BY age` 建 `(city, age)`，查询和排序一个索引全包
4. **顺手考虑覆盖**。高频查询只多要一两列，把它们放到索引末尾，就能变成覆盖索引免掉回表（见 [[MySQL 索引#覆盖索引：不回表的查询]]）。比如 `SELECT id, name FROM tb_user WHERE city = ? AND age = ?`，`(city, age, name)` 就能覆盖：

```sql
EXPLAIN SELECT id, city, age, name FROM tb_user WHERE city = '杭州' AND age = 30;
```

```text
| type | key               | key_len | ref         | rows | Extra       |
| ref  | idx_city_age_name | 70      | const,const |  500 | Using index |
```

`id` 不在索引定义里，但二级索引的叶子本来就存着主键，所以也算覆盖。

设计完用 `EXPLAIN` 验证 `key`、`key_len` 和 `Extra`，读法见 [[MySQL EXPLAIN]]。

## 参考

- [MySQL 8.4 Reference Manual: Multiple-Column Indexes](https://dev.mysql.com/doc/refman/8.4/en/multiple-column-indexes.html)
- [MySQL 8.4 Reference Manual: Range Optimization](https://dev.mysql.com/doc/refman/8.4/en/range-optimization.html)
- [MySQL 8.4 Reference Manual: Index Condition Pushdown Optimization](https://dev.mysql.com/doc/refman/8.4/en/index-condition-pushdown-optimization.html)
