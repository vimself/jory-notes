---
tags: [类型/概念, 技术/MySQL]
aliases: [MVCC, 多版本并发控制, Multi-Version Concurrency Control]
created: 2026-10-17
updated: 2026-10-17
---
> MVCC（多版本并发控制）让 InnoDB 的普通 SELECT 不加锁也能读到一致的数据。每次修改都把旧版本留在 undo log 里，串成一条版本链；读的时候拿着快照那一刻的事务名单（ReadView）沿链往回找，取第一个对自己可见的版本。这样读不挡写，写也不挡读。

## 典型场景：一边跑报表，一边有人在改数据

一个统计报表要在一个事务里跑十几条查询，期间订单表一直有人在写。报表有两个要求：所有查询必须基于同一时刻的数据，不然前后数字对不上；报表跑多久，写入就不能被它挡多久。

只靠锁做不到。要让数据在报表期间不变，就得把读过的行都锁上，写入全部排队。InnoDB 的做法是数据被修改时保留旧版本：报表读事务开始那一刻的版本，写入者照常写最新版本，两边互不等待。这套机制叫 MVCC（Multi-Version Concurrency Control，多版本并发控制）。

本篇输出来自 MySQL 8.4.11，沿用 [[MySQL 事务隔离级别]] 里的 `account` 表，隔离级别是默认的可重复读。

## 先看效果：同一个事务，同一行，读出两个值

```sql
-- 会话 A
BEGIN;
SELECT balance FROM account WHERE id = 1;    -- 2000

-- 会话 B
UPDATE account SET balance = balance + 100 WHERE id = 1;
```

```text
Query OK, 1 row affected (0.00 sec)
```

B 立刻返回了，没有被 A 的事务挡住。回到 A，连查三次：

```sql
-- 会话 A
SELECT balance FROM account WHERE id = 1;              -- 2000
SELECT balance FROM account WHERE id = 1 FOR SHARE;    -- 2100
SELECT balance FROM account WHERE id = 1;              -- 2000
COMMIT;
```

同一个事务、同一行，加了 `FOR SHARE` 读出 2100，不加读出 2000，而且读过 2100 之后再普通读，又回到 2000。这说明这一行此刻同时存在两个版本：2100 是最新版本，2000 是 A 的快照里的版本。

这里的两种读要分清：

- **快照读**（官方叫 consistent nonlocking read）：普通的 `SELECT`，读快照里的版本，不加锁
- **当前读**（官方叫 locking read）：`SELECT ... FOR UPDATE`、`SELECT ... FOR SHARE`，以及 `UPDATE`、`DELETE`，读最新的已提交版本，同时加锁

MVCC 只服务于快照读。当前读靠锁来保证正确，见 [[MySQL 行锁]]。

## 旧版本存在哪：隐藏列和版本链

### 每行都有隐藏列

InnoDB 给聚簇索引（表本身那棵按主键排序的 B+ 树，见 [[MySQL 索引]]）里的每一行都加了几个看不到的列：

| 隐藏列 | 大小 | 内容 |
| --- | --- | --- |
| `DB_TRX_ID` | 6 字节 | 最后一次插入或修改这一行的事务 ID。删除在内部也算一次修改，只是给行打上删除标记 |
| `DB_ROLL_PTR` | 7 字节 | 回滚指针，指向 undo log 里的一条记录，那条记录能把这一行还原成修改前的样子 |
| `DB_ROW_ID` | 6 字节 | 表既没有主键也没有合适的唯一索引时，InnoDB 拿它当隐藏主键；否则不出现在索引里 |

`SELECT` 查不到它们，但 InnoDB 的锁信息里会打印记录的原始字节，隐藏列就在里面。打开锁信息输出，开一个事务改一行，先不提交：

```sql
SET GLOBAL innodb_status_output_locks = ON;

BEGIN;
UPDATE account SET balance = 1234 WHERE id = 2;
SELECT trx_id FROM information_schema.innodb_trx;    -- 21939
```

在另一个会话里执行 `SHOW ENGINE INNODB STATUS\G`，`TRANSACTIONS` 一节有这么一段：

```text
RECORD LOCKS space id 3 page no 4 n bits 72 index PRIMARY of table `test`.`account` trx id 21939 lock_mode X locks rec but not gap
Record lock, heap no 3 PHYSICAL RECORD: n_fields 5; compact format; info bits 0
 0: len 4; hex 80000002; asc     ;;
 1: len 6; hex 0000000055b3; asc     U ;;
 2: len 7; hex 02000001362cbc; asc     6, ;;
 3: len 3; hex 626f62; asc bob;;
 4: len 4; hex 800004d2; asc     ;;
```

表只定义了 3 列，物理记录里却有 5 个字段：

- 0 号是主键 `id`，`80000002` 去掉开头的 8 就是 2
- 1 号长 6 字节，十六进制 `55b3` 换成十进制是 21939，正好是刚才那个事务的 ID，这就是 `DB_TRX_ID`
- 2 号长 7 字节，是 `DB_ROLL_PTR`
- 3、4 号是 `name` 和 `balance`，`4d2` 就是 1234

这张表有主键，所以没有 `DB_ROW_ID`。看完记得关掉：`SET GLOBAL innodb_status_output_locks = OFF;`

### 版本链

修改一行时，InnoDB 先把修改前的内容写进 undo log，再改这一行，把 `DB_TRX_ID` 写成当前事务 ID，`DB_ROLL_PTR` 指向刚写的那条 undo 记录。undo 记录里同样保存着旧版本的事务 ID 和上一个回滚指针，于是一个版本指向更早的版本，串成一条**版本链**（下图的事务 ID 是示意值）：

```text
聚簇索引里的行（最新版本）
┌──────────────────────────────────┐
│ id=1  balance=2100  trx_id=300   │──roll_ptr──┐
└──────────────────────────────────┘            ▼
                          undo：balance=2000  trx_id=200 ──roll_ptr──┐
                                                                     ▼
                                                undo：balance=1500  trx_id=100
```

快照读从最新版本出发，沿着链往回走，返回第一个「对我可见」的版本。怎么算可见，由 ReadView 决定。undo log 存在哪、什么时候清理，见 [[MySQL 日志]]。

## ReadView：哪个版本可见

**ReadView**（读视图）就是「快照」的真身。它不复制任何数据，只记下拍快照那一刻系统里各个事务的状态：

| 内容 | 含义 | InnoDB 源码里的字段 |
| --- | --- | --- |
| 活跃事务列表 | 拍快照时还没提交的读写事务的 ID | `m_ids` |
| 低水位 | 活跃事务里最小的 ID；列表为空时等于高水位 | `m_up_limit_id` |
| 高水位 | 拍快照时下一个待分配的事务 ID | `m_low_limit_id` |

事务 ID 是递增分配的，所以这三项足以判断任何一个版本是在快照之前还是之后提交的。读源码时要留意，`m_low_limit_id` 存的是高水位，`m_up_limit_id` 存的是低水位，名字和含义是反着的。

拿版本链上某个版本的 `DB_TRX_ID` 去判断：

1. 是当前事务自己改的：**可见**
2. 小于低水位：拍快照前就提交了，**可见**
3. 大于等于高水位：拍快照之后才开始的事务改的，**不可见**
4. 落在两者之间：在活跃列表里，说明拍快照时还没提交，**不可见**；不在列表里，说明已经提交了，**可见**

不可见就顺着回滚指针取上一个版本，接着判断。一直走到链的尽头都没有可见版本，说明这一行是快照之后才插入的，对这次读来说它不存在，快照读不会出现幻影行就是这个原因。找到的可见版本如果带删除标记，这一行对这次读来说就是已经删除了。

### 走一遍

按时间顺序（事务 ID 是示意值，假设期间没有别的事务）：

1. 事务 100 把余额改成 1500，提交
2. 事务 200 把余额改成 2000，**没提交**
3. 事务 A 执行第一条 SELECT，拍下 ReadView：活跃列表 `[200]`，低水位 200，高水位 201
4. 事务 200 提交；之后事务 300 把余额改成 2100，也提交了
5. 事务 A 再查这一行

第 5 步沿着版本链判断：

- 最新版本 `trx_id=300`：300 ≥ 高水位 201，快照之后才开始的事务，不可见，往回走
- 上一个版本 `trx_id=200`：在活跃列表里，不可见，往回走
- 再上一个 `trx_id=100`：100 < 低水位 200，可见，返回 1500

第二条最容易想错：事务 200 在第 4 步已经提交了，A 还是看不到它的修改。ReadView 是拍快照那一刻的名单，之后谁提交都不会更新它。

## RC 和 RR 只差在什么时候拍快照

读已提交（RC）和可重复读（RR）用的是同一套版本链和可见性规则，区别只有一个：

- **RC**：每条快照读都重新拍一个 ReadView，所以总能看到最新已提交的数据
- **RR**：事务里**第一条快照读**执行时拍一个 ReadView，之后一直用它

[[MySQL 事务隔离级别]] 里 RC 的不可重复读、RR 的前后一致，都是这一个区别造成的。

### 坑：RR 的快照不是在 BEGIN 时拍的

`BEGIN` 只是开启事务，并不拍快照，所以它和第一条 SELECT 之间 B 提交的修改，A 照样看得到：

```sql
-- 会话 A
BEGIN;

-- 会话 B
UPDATE account SET balance = 1500 WHERE id = 1;

-- 会话 A
SELECT balance FROM account WHERE id = 1;    -- 1500，看到了 BEGIN 之后 B 提交的修改
COMMIT;
```

要在开始事务的同时就拍快照，用 `START TRANSACTION WITH CONSISTENT SNAPSHOT`：

```sql
-- 会话 A
START TRANSACTION WITH CONSISTENT SNAPSHOT;

-- 会话 B
UPDATE account SET balance = 2000 WHERE id = 1;

-- 会话 A
SELECT balance FROM account WHERE id = 1;    -- 1500，B 的修改看不到
COMMIT;
```

需要快照时间点精确落在事务开始那一刻时用它。一般业务代码里事务开头就是查询，两种写法差别不大。

### 顺带：只读事务没有事务 ID

只做普通 SELECT 的事务，InnoDB 不给它分配事务 ID，只有执行了写操作或加锁读才分配。在 `information_schema.innodb_trx` 里能看出来：

```sql
-- 会话 A
BEGIN;
SELECT balance FROM account WHERE id = 1;

-- 会话 B
SELECT trx_id, trx_state FROM information_schema.innodb_trx;
```

```text
+-----------------+-----------+
| trx_id          | trx_state |
+-----------------+-----------+
| 551059521802240 | RUNNING   |
+-----------------+-----------+
```

这个很大的数字不是真正的事务 ID，只是给只读事务显示用的。A 执行一条 UPDATE 之后再查：

```text
+--------+-----------+
| trx_id | trx_state |
+--------+-----------+
|   1874 | RUNNING   |
+--------+-----------+
```

这才分到了真正的事务 ID。这样设计的好处是：ReadView 的活跃列表只需要记读写事务，大量只读查询不会把列表撑大，拍快照也就更快。

## 坑：先读出来、算好、再写回去，会丢更新

MVCC 让快照读不加锁，代价是你读到的可能已经不是最新值。如果在应用里拿这个值算出新值再写回去，别人在中间做的修改就会被覆盖，这叫**丢失更新**（lost update）。

```sql
-- 会话 A：准备扣 200
BEGIN;
SELECT balance FROM account WHERE id = 1;    -- 1000，应用算出 1000 - 200 = 800

-- 会话 B：同时充值 100
UPDATE account SET balance = balance + 100 WHERE id = 1;    -- 变成 1100，已提交

-- 会话 A：把算好的 800 写回去
UPDATE account SET balance = 800 WHERE id = 1;
COMMIT;
SELECT balance FROM account WHERE id = 1;    -- 800
```

正确结果应该是 1000 + 100 − 200 = 900，B 充的 100 没了。A 的 UPDATE 本身是当前读，确实看到了 1100，可是它写的是一个写死的 800，根本不看原值。

三种改法：

**让数据库自己算**。`SET balance = balance - 200` 在当前读的基础上计算，读到的是 B 提交后的 1100：

```sql
UPDATE account SET balance = balance - 200 WHERE id = 1;    -- 结果 900
```

**读的时候就加锁**。用 `SELECT ... FOR UPDATE` 读，这一行被锁住，B 的 UPDATE 只能等 A 提交：

```sql
-- 会话 A
BEGIN;
SELECT balance FROM account WHERE id = 1 FOR UPDATE;    -- 1000

-- 会话 B
UPDATE account SET balance = balance + 100 WHERE id = 1;    -- 卡住

-- 会话 A
UPDATE account SET balance = 800 WHERE id = 1;
COMMIT;
```

A 提交后 B 才执行完，耗时反映了等待：

```text
Query OK, 1 row affected (2.03 sec)
```

B 在 800 的基础上加 100，最终是 900。

**乐观锁**：表里加一个版本号列，更新时带上读到的版本号，`UPDATE ... SET balance = 800, version = version + 1 WHERE id = 1 AND version = 读到的值`，影响行数是 0 就说明被别人改过，重新读再算。适合冲突少、不想长时间持锁的场景，细节见 [[乐观锁]]。

## 坑：长事务拖住旧版本

只要还有一个 ReadView 可能用到某个旧版本，这个版本就不能从 undo log 里清掉。一个开了快照迟迟不提交的事务，会让这段时间里所有的修改都留着旧版本，undo log 越积越大。实测和排查方法见 [[MySQL 日志]] 里 undo log 一节。

所以只读的事务也要及时提交，不要在事务里等用户输入、调外部接口。

## 快照管不了 DDL

快照只覆盖数据的版本，不覆盖表结构。快照建立之后，另一个会话 `DROP TABLE` 了，快照读也读不到这张表；`ALTER TABLE` 如果是通过复制一张新表完成的，快照读会报 `ER_TABLE_DEF_CHANGED` 错误，提示表定义已经变了、请重试事务。

## 参考

- [MySQL 8.4 Reference Manual: InnoDB Multi-Versioning](https://dev.mysql.com/doc/refman/8.4/en/innodb-multi-versioning.html)
- [MySQL 8.4 Reference Manual: Consistent Nonlocking Reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)
- [MySQL 8.4 Reference Manual: Optimizing InnoDB Read-Only Transactions](https://dev.mysql.com/doc/refman/8.4/en/innodb-performance-ro-txn.html)
- [MySQL Server 8.4 源码：read0types.h（ReadView 定义）](https://github.com/mysql/mysql-server/blob/8.4/storage/innobase/include/read0types.h)
