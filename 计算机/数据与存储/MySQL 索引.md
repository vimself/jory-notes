---
tags: [类型/概念, 技术/MySQL]
aliases: [InnoDB 索引, 聚簇索引, 二级索引, 回表, 覆盖索引]
created: 2026-10-06
updated: 2026-10-06
---
> InnoDB 的表本身就是一棵按主键排好序的 B+ 树（聚簇索引），其他索引（二级索引）是另外几棵树，叶子里只存索引列和主键值。用二级索引查到主键后还要回主键树再查一次，这一步叫回表；查询要的列在二级索引里全都有，就不用回表，这叫覆盖索引。

## 典型场景：按手机号查一个人

一张 10 万行的用户表，登录时按手机号查人：

```sql
SELECT * FROM tb_user WHERE phone = '13800054321';
```

没建索引时，MySQL 只能一行一行看过去。用 `EXPLAIN ANALYZE`（会真的执行语句，并报告每一步实际花了多久，详见 [[MySQL EXPLAIN]]）看一下：

```text
-> Filter: (tb_user.phone = '13800054321')  (cost=10095 rows=1.02) (actual time=8.03..14.4 rows=1 loops=1)
    -> Table scan on tb_user  (cost=10095 rows=99909) (actual time=0.0368..9.45 rows=100000 loops=1)
```

`Table scan ... rows=100000`：为了找 1 行，读了 10 万行，耗时 14.4 毫秒。给 `phone` 建个索引再查：

```sql
CREATE INDEX idx_phone ON tb_user (phone);
```

```text
-> Index lookup on tb_user using idx_phone (phone='13800054321'), with index condition: (tb_user.phone = '13800054321')  (cost=0.35 rows=1) (actual time=0.00992..0.0103 rows=1 loops=1)
```

只读了 1 行，耗时 0.01 毫秒，快了一千多倍。表越大差距越大：全表扫描的耗时跟行数成正比，走索引的耗时几乎不随行数增长。

下面从 InnoDB 怎么存数据讲起。本篇所有输出都来自 MySQL 8.4.11，测试表结构如下：

```sql
CREATE TABLE tb_user (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  name       VARCHAR(32) NOT NULL,
  age        INT         NOT NULL,
  city       VARCHAR(16) NOT NULL,
  phone      CHAR(11)    NOT NULL,
  created_at DATETIME    NOT NULL
);
-- 插入 10 万行：name 是 user1 ~ user100000，phone 是 138 + 8 位序号
```

## 先说清楚几个词

**索引**：和书末尾的索引是一回事。书后索引按字母排好序，写着「某个词在第几页」，你不用从头翻到尾。数据库的索引也是一份**按某列排好序**的数据结构，告诉 MySQL 符合条件的行在哪。

**InnoDB**：MySQL 默认的存储引擎，也就是真正负责把数据写到磁盘、从磁盘读出来的那一层。本篇讲的都是 InnoDB 的行为。

**页（page）**：InnoDB 读写磁盘的最小单位。哪怕你只要一行，它也要把这一行所在的整页读进内存。页大小由 `innodb_page_size` 决定，默认 16KB：

```sql
SHOW VARIABLES LIKE 'innodb_page_size';
```

```text
+------------------+-------+
| Variable_name    | Value |
+------------------+-------+
| innodb_page_size | 16384 |
+------------------+-------+
```

理解索引的关键就在这里：**查询慢不慢，主要看要读多少页**。从磁盘读一页比在内存里比较几百个值慢得多，所以索引结构的设计目标只有一个：找到目标行的过程中，读的页越少越好。

## 为什么是 B+ 树

先看几个更简单的结构为什么不行。

**有序数组 + 二分查找**：查得快，但插入一行要把后面的数据整体往后挪，10 万行的表每插一行都挪一遍，写不动。

**二叉搜索树**：插入不用挪数据了，但每个节点只能分两个叉。10 万行的二叉树至少有 17 层，要是每层落在不同的页上，一次查找就要读 17 页。

**哈希表**：等值查找一步到位，但哈希把顺序完全打乱了。`phone LIKE '1380005%'`、`age > 30`、`ORDER BY created_at` 这类依赖顺序的查询，哈希表一个都帮不上。

B+ 树的思路是：**既然一次就要读一整页，那就让一个节点占满一页，一页里塞尽可能多的键**。

```text
                    [ 30001 | 60001 | 90001 ]                 ← 根节点（非叶子）：只存键和子节点指针
                   /        |        |        \
   [ 1 | 101 | ... ]  [30001 | ...]  [60001 | ...]  [90001 | ...]   ← 非叶子节点
        |
   [1 号行][2 号行]... ⇄ [101 号行][102 号行]... ⇄ ...           ← 叶子节点：存数据，左右互相链接
```

它有三个特点，每个都对应一个需求：

1. **非叶子节点只存键和指针，不存数据**。这样一页能放下的键很多，一个节点能分出成百上千个叉（这个分叉数叫**扇出**）。扇出越大，树越矮，读的页越少。
2. **所有数据都在叶子节点**，任何查找都走「根 → 中间层 → 叶子」同样长的路径，性能稳定。
3. **叶子节点按键的顺序排好，并且左右相连**。找到范围的起点之后，沿着叶子往右走就能把整个范围读完，不用回到根节点重新找。`BETWEEN`、`>`、`ORDER BY` 都靠这一点。

树有多矮，可以粗算一下。**假设**一个非叶子节点能放 1000 个指针，那么：

| 层数 | 能指向的叶子数 |
| --- | --- |
| 2 层（根 + 叶子） | 1,000 |
| 3 层 | 1,000,000 |
| 4 层 | 1,000,000,000 |

即使每个叶子节点只放十几行，三四层就能装下千万级的行。而根节点和上层节点被访问得最频繁，通常一直待在内存里，真正要读磁盘的往往只有最后一两层。这就是按索引查一行只需读几个页的原因。

和 **B 树**比，区别在第 1 点：B 树的非叶子节点也存数据，同样一页能放的键就少了，树更高，而且范围查询要在树里上上下下地跳。MySQL 官方文档里把 InnoDB 的索引统称为 B-tree，但它的结构就是上面说的 B+ 树，所以中文资料里一般叫 B+ 树。

## 聚簇索引：表本身就是一棵 B+ 树

在 InnoDB 里，**表的数据不是单独存放的，表本身就是一棵按主键排序的 B+ 树**，叶子节点里存的是完整的一行。这棵树叫**聚簇索引**（clustered index），「聚簇」的意思是数据和索引聚在一起存。

所以每张 InnoDB 表都有且只有一个聚簇索引，它这样选：

1. 定义了 `PRIMARY KEY`，就用主键
2. 没有主键，就用第一个所有列都是 `NOT NULL` 的 `UNIQUE` 索引
3. 两者都没有，InnoDB 自己生成一个隐藏的聚簇索引，名字叫 `GEN_CLUST_INDEX`，按一个 6 字节、随插入单调递增的行 ID 排序

第 3 条可以验证。建一张既没主键也没唯一索引的表，然后看 InnoDB 给它建了哪些索引：

```sql
CREATE TABLE t_nopk (name VARCHAR(20));

SELECT i.NAME AS index_name
FROM information_schema.INNODB_INDEXES i
JOIN information_schema.INNODB_TABLES t USING (TABLE_ID)
WHERE t.NAME = 'demo/t_nopk';
```

```text
+-----------------+
| index_name      |
+-----------------+
| GEN_CLUST_INDEX |
+-----------------+
```

你没建索引，表里还是有一个。这个隐藏的行 ID 你在 SQL 里用不了，没法拿它查数据。所以官方建议是**每张表都定义主键**，找不到合适的业务列就加一个自增列。

按主键查是最快的，一次树查找直接拿到整行：

```sql
EXPLAIN SELECT * FROM tb_user WHERE id = 54321;
```

```text
+----+-------------+---------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
| id | select_type | table   | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra |
+----+-------------+---------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | tb_user | NULL       | const | PRIMARY       | PRIMARY | 4       | const |    1 |   100.00 | NULL  |
+----+-------------+---------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
```

`key` 是 `PRIMARY`，`type` 是 `const`（最多匹配一行，最快的一档，`EXPLAIN` 各列的读法见 [[MySQL EXPLAIN]]）。

## 二级索引与回表

除了聚簇索引，你自己建的其他索引都叫**二级索引**（secondary index，也叫辅助索引）。`idx_phone` 就是一个二级索引。

二级索引也是一棵 B+ 树，按 `phone` 排序。它的叶子里**不存整行，只存两样东西：索引列的值和这一行的主键值**：

```text
idx_phone 的叶子：
  ('13800000001', 1)  ('13800000002', 2)  ...  ('13800054321', 54321)  ...
     ↑ phone         ↑ 主键 id
```

所以用 `idx_phone` 执行 `SELECT * FROM tb_user WHERE phone = '13800054321'`，要查**两棵树**：

1. 在 `idx_phone` 树里找到 `'13800054321'`，拿到主键 `54321`
2. 拿着 `54321` 到聚簇索引树里再查一遍，取出整行

第 2 步就叫**回表**。查一行时回表一次不算什么，但如果二级索引命中了 1 万行，就要回表 1 万次，而且这些主键在聚簇索引里通常是分散的，每次可能落在不同的页上。这也是为什么命中行数太多时，优化器宁可全表扫描也不走索引（后面会看到实例）。

二级索引存的是主键值，所以**主键越长，所有二级索引都跟着变大**。官方建议主键尽量短，自增 `INT`/`BIGINT` 比 UUID 字符串更合适。

二级索引只存一部分列，所以它比聚簇索引小得多。InnoDB 的统计表里能直接看到两棵树各占多少页：

```sql
SELECT index_name, stat_name, stat_value
FROM mysql.innodb_index_stats
WHERE database_name = 'demo' AND table_name = 'tb_user'
  AND stat_name IN ('size', 'n_leaf_pages');
```

```text
+------------+--------------+------------+
| index_name | stat_name    | stat_value |
+------------+--------------+------------+
| PRIMARY    | n_leaf_pages |        399 |
| PRIMARY    | size         |        417 |
| idx_phone  | n_leaf_pages |        133 |
| idx_phone  | size         |        161 |
+------------+--------------+------------+
```

`n_leaf_pages` 是叶子页数，`size` 是这个索引一共占用的页数。同样 10 万行，聚簇索引的叶子有 399 页（存整行），`idx_phone` 只有 133 页（只存手机号和 id）。

## 覆盖索引：不回表的查询

再看一眼二级索引的叶子：里面已经有 `phone` 和 `id` 了。如果查询只要这两列，在二级索引里就能直接拿到答案，第 2 步回表可以省掉。

一个索引包含了查询需要的所有列，就叫这个查询的**覆盖索引**（covering index）。它不是一种特殊的索引，而是索引和查询之间的一种关系：同一个 `idx_phone`，对这条查询是覆盖索引，对那条就不是。

对比两条只差在 `SELECT` 列表的查询：

```sql
EXPLAIN SELECT id, phone FROM tb_user WHERE phone = '13800054321';
EXPLAIN SELECT name      FROM tb_user WHERE phone = '13800054321';
```

```text
+------+-----------+---------+-------+------+--------------------------+
| type | key       | key_len | ref   | rows | Extra                    |
+------+-----------+---------+-------+------+--------------------------+
| ref  | idx_phone | 44      | const |    1 | Using where; Using index |   ← 只要 id、phone
| ref  | idx_phone | 44      | const |    1 | Using index condition    |   ← 要 name
+------+-----------+---------+-------+------+--------------------------+
```

（省略了几列，完整列见 [[MySQL EXPLAIN]]。）

`Extra` 里的 **`Using index`** 就是覆盖索引的标志，意思是只用索引树里的信息就拿到了所有列，不需要再去读真正的数据行。第二条要 `name`，`idx_phone` 里没有，只能回表，就没有 `Using index`。第二条里的 `Using index condition` 是另一个优化（索引条件下推），在 [[MySQL 联合索引#索引条件下推]] 里讲。

覆盖索引在实践中的用法：

- **别写 `SELECT *`**，只查需要的列，才有机会用上覆盖索引
- 高频查询只多要一两列时，可以把这几列加进联合索引，让它变成覆盖索引，比如 `(city, age, name)` 能覆盖「按城市和年龄查名字」，见 [[MySQL 联合索引]]
- 二级索引自带主键，所以 `SELECT id, ...` 里的 `id` 不用额外加进索引

## 建了索引却用不上

B+ 树能加速查询，是因为它**按列的原始值排好了序**。凡是让「按原始值排的顺序」派不上用场的写法，索引就用不上。下面四种都是实测结果，`type` 为 `ALL` 表示全表扫描。

**对索引列套函数**：

```sql
EXPLAIN SELECT * FROM tb_user WHERE LEFT(phone, 7) = '1380005';
```

```text
| type | possible_keys | key  | rows  | Extra       |
| ALL  | NULL          | NULL | 99909 | Using where |
```

索引里排好序的是 `phone`，不是 `LEFT(phone, 7)`。MySQL 不知道函数结果和原值之间的顺序关系，只能每行算一遍再比。这个需求改写成前缀匹配就能走索引：

```sql
EXPLAIN SELECT * FROM tb_user WHERE phone LIKE '1380005%';
```

```text
| type  | possible_keys | key       | rows  | Extra                 |
| range | idx_phone     | idx_phone | 18560 | Using index condition |
```

**`LIKE` 以通配符开头**：

```sql
EXPLAIN SELECT * FROM tb_user WHERE phone LIKE '%54321';
```

```text
| type | possible_keys | key  | rows  | Extra       |
| ALL  | NULL          | NULL | 99909 | Using where |
```

`'1380005%'` 能用，是因为所有以 `1380005` 开头的值在 B+ 树里是挨在一起的一段。`'%54321'` 是按结尾找，结尾相同的值散落在树的各处，没有一段连续区间可以扫。这和查字典一样：找「以 qu 开头的词」翻到 q 那部分就行，找「以 tion 结尾的词」只能整本翻。

**字符串列和数字比较（隐式类型转换）**：

```sql
EXPLAIN SELECT * FROM tb_user WHERE phone = 13800054321;   -- 数字没加引号
SHOW WARNINGS;
```

```text
| type | possible_keys | key  | rows  | Extra       |
| ALL  | idx_phone     | NULL | 99909 | Using where |

| Warning | 1739 | Cannot use ref access on index 'idx_phone' due to type or collation conversion on field 'phone' |
| Warning | 1739 | Cannot use range access on index 'idx_phone' due to type or collation conversion on field 'phone' |
```

`possible_keys` 里有 `idx_phone`，`key` 却是 `NULL`：优化器知道有这个索引，但用不了。警告说得很直白，`phone` 这一列上发生了类型转换。字符串和数字比较时，MySQL 会把两边按数字比，而很多不同的字符串转成数字后是同一个值：

```sql
SELECT ' 13800054321'   = 13800054321 AS 前面带空格,
       '013800054321'   = 13800054321 AS 前面带零,
       '13800054321abc' = 13800054321 AS 后面带字母;
```

```text
+-----------------+--------------+-----------------+
| 前面带空格      | 前面带零     | 后面带字母      |
+-----------------+--------------+-----------------+
|               1 |            1 |               1 |
+-----------------+--------------+-----------------+
```

三个都等于 `13800054321`。这些字符串在按字符串排序的索引里散落在不同位置，MySQL 没法用索引一次定位到「所有转成数字等于 13800054321 的值」，只能逐行转换再比较。

反过来，整数列和字符串常量比较时，转换发生在常量那一侧，索引照用：

```sql
EXPLAIN SELECT * FROM tb_user WHERE id = '54321';
```

```text
| type  | key     | key_len | rows |
| const | PRIMARY | 4       |    1 |
```

**列是字符串类型，传进来的值就要是字符串。**手机号、身份证号、订单号这类「长得像数字」的字符串列最容易踩坑。

**命中的行太多**：

```sql
EXPLAIN SELECT * FROM tb_user WHERE phone > '13800000000';
```

```text
| type | possible_keys | key  | rows  | filtered | Extra       |
| ALL  | idx_phone     | NULL | 99909 |    50.00 | Using where |
```

这条写法完全没问题，索引也在 `possible_keys` 里，但所有手机号都大于 `'13800000000'`。走索引意味着几乎每一行都要回表一次，还不如顺序把聚簇索引从头读到尾。优化器估算过成本，主动放弃了索引。官方文档的说法是：查询要访问表里大部分行时，顺序读比走索引快。这种情况不是 bug，不需要修。

## 索引不是越多越好

每个索引都是一棵独立的 B+ 树，代价有两份：

- **写变慢**：每次 `INSERT`、`DELETE`，以及修改了索引列的 `UPDATE`，都要同步改动每一棵相关的树
- **占空间**：每个二级索引都存一份索引列加主键

聚簇索引按主键排序，主键的插入顺序也会影响空间利用。InnoDB 往聚簇索引插入新记录时，会给每页留出 1/16 的空闲。按主键顺序插入（比如自增 id），每页能填到大约 15/16；随机顺序插入（比如 UUID），新行要插到已有数据的中间，页会被拆分，每页的填充率在 1/2 到 15/16 之间。这又是一个主键用自增整数的理由。

建索引前确认两点：这个列是否出现在高频查询的 `WHERE`、`ORDER BY` 或 `JOIN` 里；能否并入已有的联合索引。多个列一起查的情况见 [[MySQL 联合索引]]；判断一条 SQL 实际用了哪个索引见 [[MySQL EXPLAIN]]。

## 参考

- [MySQL 8.4 Reference Manual: Clustered and Secondary Indexes](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)
- [MySQL 8.4 Reference Manual: The Physical Structure of an InnoDB Index](https://dev.mysql.com/doc/refman/8.4/en/innodb-physical-structure.html)
- [MySQL 8.4 Reference Manual: How MySQL Uses Indexes](https://dev.mysql.com/doc/refman/8.4/en/mysql-indexes.html)
