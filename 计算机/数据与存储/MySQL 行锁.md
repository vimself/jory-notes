---
tags: [类型/概念, 技术/MySQL]
aliases: [InnoDB 行锁, 记录锁, 间隙锁, 临键锁, Next-Key Lock]
created: 2026-10-17
updated: 2026-10-17
---
> InnoDB 的行锁加在索引记录上，分三种。记录锁只锁一条记录；间隙锁锁两条记录之间的空隙，专门挡插入；临键锁是记录锁加上它前面的间隙。可重复读下，加锁读、UPDATE、DELETE 默认用临键锁，所以会挡住看起来和你无关的插入。查询要是没走索引，整张表的记录都会被锁上。

## 典型场景：只锁了一行，别人插入却卡住了

用户表的 `age` 列上有普通索引。会话 A 要给 25 岁的用户发券，先把他们锁住：

```sql
-- 会话 A
BEGIN;
SELECT * FROM user WHERE age = 25 FOR UPDATE;
```

```text
+----+------+-----+
| id | name | age |
+----+------+-----+
| 20 | bob  |  25 |
+----+------+-----+
```

这时会话 B 注册一个 20 岁的新用户：

```sql
-- 会话 B
INSERT INTO user VALUES (21, 'eve', 20);
```

B 卡住了，等到超时（默认 50 秒）报错：

```text
ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction
```

A 只查到 bob 一行，跟一个 20 岁的新用户没有任何关系，B 为什么要等？把新用户的年龄换成 33，插入却立刻成功。原因是 A 锁住的不只是 bob 这一条记录，还有 bob 前后的两段「空隙」。

本篇输出来自 MySQL 8.4.11，默认的可重复读隔离级别，测试表如下：

```sql
CREATE TABLE user (
  id   INT PRIMARY KEY,
  name VARCHAR(16) NOT NULL,
  age  INT         NOT NULL,
  KEY idx_age (age)
);
INSERT INTO user VALUES (10, 'alice', 18), (20, 'bob', 25), (30, 'carol', 32), (40, 'dave', 40);
```

## 先说清楚几个词

**共享锁（S）和排他锁（X）**：行锁的两种模式。S 锁让持有者读这一行，多个事务可以同时持有同一行的 S 锁；X 锁让持有者修改或删除这一行，和任何其他锁都冲突。`SELECT ... FOR SHARE` 加 S 锁，`SELECT ... FOR UPDATE`、`UPDATE`、`DELETE` 加 X 锁。普通 `SELECT` 不加锁，读的是 [[MySQL MVCC]] 的快照。

**意向锁（IS、IX）**：表级的锁。事务给某些行加 S 锁或 X 锁之前，要先在表上加 IS 或 IX，表示「这张表里有行被我锁着」。意向锁之间互不冲突，只和 `LOCK TABLES ... WRITE` 这类整表锁冲突。下面每个查锁结果的第一行 `TABLE IX` 就是它，后文不再提。

**锁加在索引记录上**：InnoDB 锁的不是抽象的「行」，而是**索引里的一条条记录**。表没有定义任何索引时，InnoDB 就锁它自动生成的隐藏聚簇索引（[[MySQL 索引]]）。在可重复读下，加锁读、UPDATE、DELETE 扫描过哪些索引记录，就锁哪些；WHERE 条件后面有没有把这一行过滤掉，不影响加锁。

## 怎么看加了哪些锁

开着事务的时候，从另一个会话查：

```sql
SELECT INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks;
```

各列的意思：

- `LOCK_TYPE`：`TABLE` 是表锁，`RECORD` 是行锁
- `LOCK_MODE`：`X` 或 `S`，后面的后缀说明锁的是什么
  - `X,REC_NOT_GAP`：记录锁，只锁这条记录
  - `X,GAP`：间隙锁，只锁这条记录**前面**的空隙
  - `X`（没有后缀）：临键锁，这条记录加它前面的空隙
  - `X,GAP,INSERT_INTENTION`：插入意向锁，插入时申请的，见下文
- `LOCK_DATA`：锁在哪条索引记录上。主键索引显示主键值；二级索引显示「索引列值, 主键值」
- `LOCK_STATUS`：`GRANTED` 是已经拿到，`WAITING` 是正在等

## 三种行锁

主键索引里有 10、20、30、40 四条记录，它们把整个取值范围切成了 5 段间隙：

```text
   (-∞,10)   10   (10,20)   20   (20,30)   30   (30,40)   40   (40,+∞)
    间隙     记录    间隙    记录    间隙    记录    间隙    记录    间隙
```

最后一段 `(40,+∞)` 后面没有真实记录，InnoDB 用一条叫 **supremum** 的伪记录表示「比所有值都大」，锁这段间隙时就锁在它上面。

### 记录锁：只锁一条记录

按主键等值查，查到了：

```sql
SELECT * FROM user WHERE id = 20 FOR UPDATE;
```

```text
+------------+-----------+---------------+-------------+-----------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE     | LOCK_STATUS | LOCK_DATA |
+------------+-----------+---------------+-------------+-----------+
| NULL       | TABLE     | IX            | GRANTED     | NULL      |
| PRIMARY    | RECORD    | X,REC_NOT_GAP | GRANTED     | 20        |
+------------+-----------+---------------+-------------+-----------+
```

只有 `id = 20` 这一条记录锁（record lock）。用唯一索引按等值找一行，结果最多一行，不会有别的行混进来，所以不需要锁间隙。这是加锁最少的情况。

### 间隙锁：锁住两条记录之间的空隙

按主键等值查一个**不存在**的值：

```sql
SELECT * FROM user WHERE id = 25 FOR UPDATE;
```

```text
Empty set (0.00 sec)
```

```text
+------------+-----------+-----------+-------------+-----------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE | LOCK_STATUS | LOCK_DATA |
+------------+-----------+-----------+-------------+-----------+
| NULL       | TABLE     | IX        | GRANTED     | NULL      |
| PRIMARY    | RECORD    | X,GAP     | GRANTED     | 30        |
+------------+-----------+-----------+-------------+-----------+
```

一行都没查到，却加了一把锁。`X,GAP` 落在 30 上，意思是「30 **前面**的那段间隙」，也就是 `(20,30)`。之后别的事务要插入 id 在 21 到 29 之间的行，都得等。

锁一个空位置是为了挡幻读。A 刚刚确认了「id = 25 不存在」，如果别人这时插进一条 25，A 下次当前读就会看到它（见 [[MySQL 事务隔离级别]]）。可重复读级别要挡住它，就得把 25 可能落进去的那段间隙锁住。

间隙锁（gap lock）有两个特点，后面讲死锁时会用到：

- **它只挡插入**。间隙锁的唯一作用是不让别人往这段空隙里插数据，不影响别人读写间隙两端的记录
- **间隙锁之间不冲突**。两个事务可以同时持有同一段间隙的间隙锁，S 型和 X 型的间隙锁也没有区别

### 临键锁：记录加上它前面的间隙

**临键锁**（next-key lock）= 一条记录的记录锁 + 这条记录前面那段间隙的间隙锁，锁住的是一个左开右闭区间。锁在 40 上的临键锁，范围是 `(30,40]`。

按主键查一个范围：

```sql
SELECT * FROM user WHERE id >= 30 FOR UPDATE;
```

```text
+------------+-----------+---------------+-------------+------------------------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE     | LOCK_STATUS | LOCK_DATA              |
+------------+-----------+---------------+-------------+------------------------+
| NULL       | TABLE     | IX            | GRANTED     | NULL                   |
| PRIMARY    | RECORD    | X             | GRANTED     | supremum pseudo-record |
| PRIMARY    | RECORD    | X             | GRANTED     | 40                     |
| PRIMARY    | RECORD    | X,REC_NOT_GAP | GRANTED     | 30                     |
+------------+-----------+---------------+-------------+------------------------+
```

逐条看：

- 30 上是记录锁：范围从 30 开始，30 前面的间隙不在条件范围内，不用锁
- 40 上是临键锁：锁住 `(30,40]`
- supremum 上是临键锁：supremum 不是真记录，实际效果就是锁住 `(40,+∞)`

合起来，id ≥ 30 的整个范围都被锁住了，现在和将来插进来的行都算。可重复读级别正是靠临键锁挡住加锁读的幻读。

## 回到开头：普通索引上的等值查询

开头那条 `WHERE age = 25 FOR UPDATE` 实际加的锁：

```text
+------------+-----------+---------------+-------------+-----------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE     | LOCK_STATUS | LOCK_DATA |
+------------+-----------+---------------+-------------+-----------+
| NULL       | TABLE     | IX            | GRANTED     | NULL      |
| idx_age    | RECORD    | X,GAP         | GRANTED     | 32, 30    |
| idx_age    | RECORD    | X             | GRANTED     | 25, 20    |
| PRIMARY    | RECORD    | X,REC_NOT_GAP | GRANTED     | 20        |
+------------+-----------+---------------+-------------+-----------+
```

要看懂它，先回忆二级索引的结构：`idx_age` 的记录按 `(age, id)` 排序，所以 `LOCK_DATA` 显示的是一对值。四条记录依次是 `(18,10)`、`(25,20)`、`(32,30)`、`(40,40)`。

- `(25,20)` 上的临键锁：锁住 bob 这条记录，以及它前面到 `(18,10)` 的间隙
- `(32,30)` 上的间隙锁：`age` 不是唯一索引，找到一个 25 之后，后面可能还有别的 25，InnoDB 要继续往后扫，扫到 `(32,30)` 发现不是 25 才停下。这条记录不满足条件，所以只锁它前面的间隙，不锁记录本身
- 主键 20 上的记录锁：通过二级索引加排他锁时，InnoDB 还会把对应的聚簇索引记录也锁上

在 `idx_age` 上，被锁住的是 `(18,10)` 和 `(32,30)` 之间的整段，两端都不含。新插入的行在 `idx_age` 里的位置只要落进这一段，就得等。逐个试了几条插入（B 的锁等待超时设成 1 秒）：

| 插入 `(id, age)` | 在 idx_age 里的位置 | 结果 |
| --- | --- | --- |
| `(21, 20)` | `(20,21)`：在 `(18,10)` 和 `(25,20)` 之间 | 阻塞 |
| `(22, 30)` | `(30,22)`：在 `(25,20)` 和 `(32,30)` 之间 | 阻塞 |
| `(23, 33)` | `(33,23)`：在 `(32,30)` 之后 | 成功 |
| `(11, 18)` | `(18,11)`：在 `(18,10)` 之后 | 阻塞 |
| `(5, 18)` | `(18,5)`：在 `(18,10)` 之前 | 成功 |
| `(29, 32)` | `(32,29)`：在 `(32,30)` 之前 | 阻塞 |
| `(31, 32)` | `(32,31)`：在 `(32,30)` 之后 | 成功 |

后四行最容易想错：同样是 18 岁，id 是 11 就被挡，id 是 5 就能插。间隙的边界是 `(age, id)` 这一对值，不只是 `age`，所以边界上的年龄能不能插，还要看主键落在哪一边。

插入被挡住时，`data_locks` 里会多出一行 `WAITING`：

```text
+------------+-----------+------------------------+-------------+-----------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE              | LOCK_STATUS | LOCK_DATA |
+------------+-----------+------------------------+-------------+-----------+
| NULL       | TABLE     | IX                     | GRANTED     | NULL      |
| NULL       | TABLE     | IX                     | GRANTED     | NULL      |
| idx_age    | RECORD    | X,GAP                  | GRANTED     | 32, 30    |
| idx_age    | RECORD    | X                      | GRANTED     | 25, 20    |
| idx_age    | RECORD    | X,GAP,INSERT_INTENTION | WAITING     | 25, 20    |
| PRIMARY    | RECORD    | X,REC_NOT_GAP          | GRANTED     | 20        |
+------------+-----------+------------------------+-------------+-----------+
```

`X,GAP,INSERT_INTENTION` 是**插入意向锁**：INSERT 在真正插入之前，先对要插入的那段间隙申请这把锁。几个事务往同一段间隙里插不同的位置，插入意向锁彼此不冲突，可以并行；但它和别人持有的间隙锁、临键锁冲突，所以 B 在这里等 A。

## 没走索引：整张表都被锁住

按没有索引的 `name` 列加锁：

```sql
SELECT * FROM user WHERE name = 'bob' FOR UPDATE;
```

```text
+------------+-----------+-----------+-------------+------------------------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE | LOCK_STATUS | LOCK_DATA              |
+------------+-----------+-----------+-------------+------------------------+
| NULL       | TABLE     | IX        | GRANTED     | NULL                   |
| PRIMARY    | RECORD    | X         | GRANTED     | supremum pseudo-record |
| PRIMARY    | RECORD    | X         | GRANTED     | 10                     |
| PRIMARY    | RECORD    | X         | GRANTED     | 20                     |
| PRIMARY    | RECORD    | X         | GRANTED     | 30                     |
| PRIMARY    | RECORD    | X         | GRANTED     | 40                     |
+------------+-----------+-----------+-------------+------------------------+
```

结果只有 bob 一行，锁却加在了每一条记录和每一段间隙上。没有索引可用，InnoDB 只能全表扫描，扫过的每条记录都加临键锁。效果等于锁了整张表：任何行都改不了，任何位置都插不进。

所以 `UPDATE`、`DELETE` 和加锁读的 WHERE 条件一定要能走索引。上线前用 [[MySQL EXPLAIN]] 看一眼：加锁语句的 `type` 是 `ALL`，跑起来就会锁住全表。

## 读已提交下：基本只剩记录锁

把隔离级别换成读已提交，重做开头的实验：

```sql
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN;
SELECT * FROM user WHERE age = 25 FOR UPDATE;
```

```text
+------------+-----------+---------------+-------------+-----------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE     | LOCK_STATUS | LOCK_DATA |
+------------+-----------+---------------+-------------+-----------+
| NULL       | TABLE     | IX            | GRANTED     | NULL      |
| idx_age    | RECORD    | X,REC_NOT_GAP | GRANTED     | 25, 20    |
| PRIMARY    | RECORD    | X,REC_NOT_GAP | GRANTED     | 20        |
+------------+-----------+---------------+-------------+-----------+
```

间隙锁和临键锁都没了，只剩两条记录锁。B 插入 `(21, 'eve', 20)` 立刻成功。

在读已提交下，没走索引的 `name = 'bob'` 也只在 bob 上留了记录锁：扫描时不满足 WHERE 的行，判断完就把锁放掉了。读已提交只在检查外键约束和唯一键冲突时才用间隙锁。

代价是幻读挡不住了。要不要换隔离级别，见 [[MySQL 事务隔离级别]]。

## 坑：先查后插的死锁

「不存在就插入」是很常见的写法：

```sql
BEGIN;
SELECT * FROM user WHERE id = 25 FOR UPDATE;   -- 查不到
INSERT INTO user VALUES (25, 'erin', 28);      -- 那就插入
COMMIT;
```

单个会话跑没问题，两个会话并发跑就会死锁。A 查 25，B 查 26，两个 id 都不存在：

```sql
-- 会话 A
BEGIN;
SELECT * FROM user WHERE id = 25 FOR UPDATE;    -- Empty set

-- 会话 B
BEGIN;
SELECT * FROM user WHERE id = 26 FOR UPDATE;    -- Empty set
```

```text
+------------+-----------+-----------+-------------+-----------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE | LOCK_STATUS | LOCK_DATA |
+------------+-----------+-----------+-------------+-----------+
| NULL       | TABLE     | IX        | GRANTED     | NULL      |
| NULL       | TABLE     | IX        | GRANTED     | NULL      |
| PRIMARY    | RECORD    | X,GAP     | GRANTED     | 30        |
| PRIMARY    | RECORD    | X,GAP     | GRANTED     | 30        |
+------------+-----------+-----------+-------------+-----------+
```

两个事务都拿到了 `(20,30)` 的间隙锁。间隙锁之间不冲突，所以谁也没挡住谁。接着各自插入：

```sql
-- 会话 A
INSERT INTO user VALUES (25, 'erin', 28);     -- 等：插入意向锁和 B 的间隙锁冲突

-- 会话 B
INSERT INTO user VALUES (26, 'frank', 29);
```

```text
ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction
```

A 等 B 释放间隙锁，B 也在等 A 释放间隙锁，互相等待，构成死锁。InnoDB 默认开着死锁检测（`innodb_deadlock_detect`），发现死锁后立即回滚其中一个事务，这次回滚的是 B。B 的整个事务被撤销，间隙锁随之释放，A 的插入随即完成：

```text
Query OK, 1 row affected (1.02 sec)
```

最近一次死锁的详情在 `SHOW ENGINE INNODB STATUS` 的 `LATEST DETECTED DEADLOCK` 一节，下面省略了记录的十六进制内容：

```text
*** (1) TRANSACTION:
TRANSACTION 1930, ACTIVE 2 sec inserting
INSERT INTO user VALUES (25, 'erin', 28)

*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 4 page no 4 n bits 80 index PRIMARY of table `test`.`user` trx id 1930 lock_mode X locks gap before rec

*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 4 page no 4 n bits 80 index PRIMARY of table `test`.`user` trx id 1930 lock_mode X locks gap before rec insert intention waiting

*** (2) TRANSACTION:
TRANSACTION 1931, ACTIVE 1 sec inserting
INSERT INTO user VALUES (26, 'frank', 29)

*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 4 page no 4 n bits 80 index PRIMARY of table `test`.`user` trx id 1931 lock_mode X locks gap before rec

*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 4 page no 4 n bits 80 index PRIMARY of table `test`.`user` trx id 1931 lock_mode X locks gap before rec insert intention waiting

*** WE ROLL BACK TRANSACTION (2)
```

两边都是「持有 `locks gap before rec`，等待 `insert intention`」，和上面的分析一致。

几种应对：

- **应用层捕获 1213，重试整个事务**。死锁回滚的是整个事务，只重试最后一条语句没有用。不管采用下面哪种改法，这一条都要有
- **去掉前面的加锁查询，直接插入**，靠主键或唯一索引兜底：重复时会报 1062，应用捕获后按「已存在」处理
- **改用读已提交**：加锁查询查不到行时不留间隙锁。同样的两个会话在读已提交下实测，两条插入都直接成功

## 坑：锁等待超时只回滚那一条语句

死锁会回滚整个事务，锁等待超时却不会。默认情况下，超时只撤销正在等锁的那一条语句，事务本身还开着：

```sql
-- 会话 A 锁住 id >= 30 的范围
BEGIN;
SELECT * FROM user WHERE id >= 30 FOR UPDATE;

-- 会话 B
SET SESSION innodb_lock_wait_timeout = 2;
BEGIN;
INSERT INTO user VALUES (1, 'zoe', 22);     -- 成功
INSERT INTO user VALUES (50, 'yan', 23);    -- 等 2 秒后 ERROR 1205
SELECT * FROM user WHERE id IN (1, 50);
```

```text
+----+------+-----+
| id | name | age |
+----+------+-----+
|  1 | zoe  |  22 |
+----+------+-----+
```

第一条插入还在，事务状态仍是 `RUNNING`。如果应用捕获 1205 后不处理、接着往下走并提交，就会提交一个只做了一半的事务。所以捕获到 1205 时，要么显式 `ROLLBACK`，要么只重试这一条语句。想让超时直接回滚整个事务，可以在启动时打开 `innodb_rollback_on_timeout`（默认关闭）。

等待多久由 `innodb_lock_wait_timeout` 决定，默认 50 秒：

```sql
SELECT @@innodb_lock_wait_timeout;    -- 50
```

## 排查：谁锁住了我

插入或更新卡住时，用 `sys.innodb_lock_waits` 找出挡路的连接：

```sql
SELECT waiting_pid, waiting_query, blocking_pid, blocking_query, sql_kill_blocking_connection
FROM sys.innodb_lock_waits\G
```

```text
*************************** 1. row ***************************
                 waiting_pid: 17
               waiting_query: INSERT INTO user VALUES (21, 'eve', 20)
                blocking_pid: 18
              blocking_query: NULL
sql_kill_blocking_connection: KILL 18
```

`blocking_query` 是 `NULL`，说明挡路的连接此刻没在执行任何语句：它开了事务、加了锁，然后就停在那里，既不提交也不回滚。生产环境里多半是代码里漏了提交，或者事务里夹着一次很慢的外部调用。确认可以放弃它的修改后，执行最后一列给出的 `KILL 18`，连接断开时它的事务会被回滚，锁随之释放。

## 参考

- [MySQL 8.4 Reference Manual: InnoDB Locking](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html)
- [MySQL 8.4 Reference Manual: Locks Set by Different SQL Statements in InnoDB](https://dev.mysql.com/doc/refman/8.4/en/innodb-locks-set.html)
- [MySQL 8.4 Reference Manual: Deadlock Detection](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlock-detection.html)
- [MySQL 8.4 Reference Manual: InnoDB Error Handling](https://dev.mysql.com/doc/refman/8.4/en/innodb-error-handling.html)
