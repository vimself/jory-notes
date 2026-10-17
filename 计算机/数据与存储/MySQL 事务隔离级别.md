---
tags: [类型/概念, 技术/MySQL]
aliases: [事务隔离级别]
created: 2026-10-17
updated: 2026-10-17
---
> 隔离级别决定一个事务能看到别的事务多少中间状态。读未提交会脏读，读已提交会不可重复读。可重复读是 InnoDB 的默认级别，它用快照让普通 SELECT 前后一致。串行化则让读也加锁。级别越高，并发能力越差。

## 典型场景：对账总额和明细对不上

对账脚本在一个事务里做两件事：先算所有账户的余额总和，再把每个账户的余额导出来逐条核对。

```sql
BEGIN;
SELECT SUM(balance) FROM account;   -- 3000
SELECT id, balance FROM account;    -- 逐条加起来却是 3500
COMMIT;
```

两条查询之间，另一个连接给 2 号账户充了 500 元并提交了。如果事务跑在「读已提交」级别下，第二条查询会读到充值后的余额，明细比总额多出 500，对账失败。换成 MySQL 默认的「可重复读」，同一个事务里的两次读看到的是同一份数据，总额和明细就对得上。

隔离级别管的就是这件事：**一个事务执行期间，别的事务提交的修改它能不能看到、什么时候看到**。本篇所有输出都来自 MySQL 8.4.11，测试表如下：

```sql
CREATE TABLE account (
  id      INT PRIMARY KEY,
  name    VARCHAR(16) NOT NULL,
  balance INT         NOT NULL
);
INSERT INTO account VALUES (1, 'alice', 1000), (2, 'bob', 1000), (3, 'carol', 1000);
```

## 事务是什么

**事务**（transaction）是一组 SQL，要么全部生效，要么全部不生效。经典例子是转账：A 扣 100 和 B 加 100 必须一起成功，只扣了钱没加上就是事故。

```sql
BEGIN;                                                    -- 开始事务，也可以写 START TRANSACTION
UPDATE account SET balance = balance - 100 WHERE id = 1;
UPDATE account SET balance = balance + 100 WHERE id = 2;
COMMIT;                                                   -- 提交；想放弃就写 ROLLBACK
```

事务的四个特性合称 ACID。InnoDB 用不同的机制分别实现它们：

| 特性 | 含义 | InnoDB 靠什么 |
| --- | --- | --- |
| 原子性 Atomicity | 全部生效，或者全部撤销 | undo log 记下怎么撤回，见 [[MySQL 日志]] |
| 一致性 Consistency | 事务前后数据都满足约束，比如转账前后余额总和不变 | 是目的，由另外三条加上约束检查共同保证 |
| 隔离性 Isolation | 并发执行的事务互不干扰 | [[MySQL MVCC]] 和 [[MySQL 行锁]] |
| 持久性 Durability | 提交了就不会丢，断电也不丢 | redo log，见 [[MySQL 日志]] |

本篇只讲隔离性。

### autocommit：没写 BEGIN 也在事务里

MySQL 默认打开 `autocommit`（自动提交）：

```sql
SELECT @@autocommit;
```

```text
+--------------+
| @@autocommit |
+--------------+
|            1 |
+--------------+
```

打开时，没有夹在 `BEGIN ... COMMIT` 之间的语句，每条单独算一个事务，执行完就自动提交。所以下文实验里「会话 B 执行一条 UPDATE」，这条 UPDATE 一执行完就已经提交了。

### 坑：DDL 会顺手把事务提交掉

`CREATE TABLE`、`ALTER TABLE` 这类 DDL（改表结构的语句）会**隐式提交**当前事务。把 DDL 夹在事务中间，它前面的修改就被直接提交了，后面的 `ROLLBACK` 撤不回来：

```sql
BEGIN;
UPDATE account SET balance = 0 WHERE id = 3;
CREATE TABLE tmp_log (id INT);
ROLLBACK;
SELECT * FROM account WHERE id = 3;
```

```text
+----+-------+---------+
| id | name  | balance |
+----+-------+---------+
|  3 | carol |       0 |
+----+-------+---------+
```

`ROLLBACK` 没报错，但 carol 的余额已经是 0。执行到 `CREATE TABLE` 的那一刻，前面那条 UPDATE 就已经提交了，`ROLLBACK` 时事务里什么都没剩下。写数据迁移脚本时尤其要注意：建表、改表放在事务外面单独执行。

## 三种并发异常

隔离级别是按「允许发生哪几种异常」来定义的，所以先看异常本身。下面的实验都开两个 mysql 客户端，记作会话 A 和会话 B，按时间顺序交替执行。注释里的数字是当时真实查出来的值。

### 脏读：读到别人还没提交的数据

**脏读**（dirty read）是指读到了另一个事务**还没提交**的修改。那个事务之后可能回滚，你读到的值就从来没真正存在过。

把 A 设成最低的「读未提交」级别来复现：

```sql
-- 会话 A
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
BEGIN;
SELECT balance FROM account WHERE id = 1;    -- 1000

-- 会话 B
BEGIN;
UPDATE account SET balance = balance - 100 WHERE id = 1;    -- 没提交

-- 会话 A
SELECT balance FROM account WHERE id = 1;    -- 900：读到了 B 没提交的修改

-- 会话 B
ROLLBACK;

-- 会话 A
SELECT balance FROM account WHERE id = 1;    -- 1000：刚才的 900 从来没生效过
COMMIT;
```

如果 A 拿着那个 900 去做后续计算，算出来的结果就建立在一个不存在的数据上。

### 不可重复读：同一行读两次，值变了

**不可重复读**（non-repeatable read）是指同一个事务里两次读**同一行**，中间别的事务修改了这一行并**提交**了，两次读到的值不一样。开头的对账场景就是它。在「读已提交」级别下复现：

```sql
-- 会话 A
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN;
SELECT SUM(balance) FROM account;    -- 3000

-- 会话 B
UPDATE account SET balance = balance + 500 WHERE id = 2;    -- autocommit，立即提交

-- 会话 A
SELECT id, balance FROM account;
COMMIT;
```

```text
+----+---------+
| id | balance |
+----+---------+
|  1 |    1000 |
|  2 |    1500 |
|  3 |    1000 |
+----+---------+
```

总额是 3000，明细加起来是 3500。和脏读不同，B 已经提交了，A 读到的 1500 是真实存在的数据。问题出在 A 在一个事务里先后读到了两个时间点的数据。

### 幻读：同样的条件查两次，多出了行

**幻读**（phantom read）是指同一个事务里按**同一个条件**查两次，第二次多出了几行（或者少了几行），因为中间别的事务插入（或删除）了满足条件的行并提交了。多出来的行叫幻影行（phantom row）。

```sql
-- 会话 A
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN;
SELECT * FROM account WHERE balance >= 1000;    -- 3 行

-- 会话 B
INSERT INTO account VALUES (4, 'dave', 2000);

-- 会话 A
SELECT * FROM account WHERE balance >= 1000;
COMMIT;
```

```text
+----+-------+---------+
| id | name  | balance |
+----+-------+---------+
|  1 | alice |    1000 |
|  2 | bob   |    1000 |
|  3 | carol |    1000 |
|  4 | dave  |    2000 |
+----+-------+---------+
```

不可重复读是已有的行**值变了**，幻读是满足条件的**行数变了**。这个区别决定了防起来的难度：防不可重复读，只要管住读过的那几行；防幻读，还得管住那些「现在还不存在、将来可能被插进来的行」，后者难得多，[[MySQL 行锁]] 里的间隙锁就是为它准备的。

## 四种隔离级别

SQL 标准定义了四个级别，从低到高，每个级别挡住的异常如下：

| 隔离级别 | 脏读 | 不可重复读 | 幻读 |
| --- | --- | --- | --- |
| READ UNCOMMITTED 读未提交 | 会 | 会 | 会 |
| READ COMMITTED 读已提交（RC） | 不会 | 会 | 会 |
| REPEATABLE READ 可重复读（RR） | 不会 | 不会 | 标准允许出现；InnoDB 挡住了大部分，见下文 |
| SERIALIZABLE 串行化 | 不会 | 不会 | 不会 |

InnoDB 的默认级别是可重复读。各级别在 InnoDB 里的具体做法：

- **读未提交**：普通 SELECT 不加锁，能读到别的事务还没提交的修改，其余行为和读已提交相同。
- **读已提交**：每条普通 SELECT 都重新拍一份快照，所以能看到别的事务刚提交的修改。加锁时只锁记录本身，不锁记录之间的间隙。
- **可重复读**：事务里第一条普通 SELECT 执行时拍一份快照，之后的普通 SELECT 都读这一份。加锁读、UPDATE、DELETE 会把扫描过的范围连同间隙一起锁住（用唯一索引按等值查到一行时例外，只锁那一行）。
- **串行化**：在可重复读的基础上，显式事务里的普通 SELECT 会被自动改成 `SELECT ... FOR SHARE`（加共享锁的读），读和写互相阻塞。

「快照」怎么拍、怎么读，在 [[MySQL MVCC]] 里讲；「锁记录」和「锁间隙」的区别，在 [[MySQL 行锁]] 里讲。下面用实验看可重复读和串行化的实际表现。

### 可重复读：普通 SELECT 前后一致

把不可重复读的实验换到可重复读级别下，重做一遍：

```sql
-- 会话 A
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
SELECT SUM(balance) FROM account;    -- 3000

-- 会话 B
UPDATE account SET balance = balance + 500 WHERE id = 2;

-- 会话 A
SELECT id, balance FROM account;     -- 2 号还是 1000，和总额对得上
COMMIT;
SELECT id, balance FROM account;     -- 事务结束后再查，2 号才变成 1500
```

幻读的实验也一样：B 插入一行新数据并提交后，A 在同一个事务里再用普通 SELECT 查，看到的还是原来那几行。

### 可重复读下的幻读：快照读和当前读混用

可重复读挡住的是**普通 SELECT** 的幻读。普通 SELECT 读快照，这叫**快照读**；UPDATE、DELETE、`SELECT ... FOR UPDATE` 不读快照，读的是最新已提交的数据，这叫**当前读**。两种读在一个事务里混着用，幻读就回来了：

```sql
-- 会话 A
BEGIN;
SELECT * FROM account WHERE balance >= 1000;    -- 4 行：alice、bob、carol、dave

-- 会话 B
INSERT INTO account VALUES (5, 'erin', 2000);

-- 会话 A
SELECT * FROM account WHERE balance >= 1000;    -- 还是 4 行，快照生效
UPDATE account SET balance = balance + 1 WHERE balance >= 1000;
```

```text
Query OK, 5 rows affected (0.00 sec)
Rows matched: 5  Changed: 5  Warnings: 0
```

A 看到的明明是 4 行，UPDATE 却改了 5 行。再查一次：

```sql
SELECT * FROM account WHERE balance >= 1000;
```

```text
+----+-------+---------+
| id | name  | balance |
+----+-------+---------+
|  1 | alice |    1001 |
|  2 | bob   |    1001 |
|  3 | carol |    1001 |
|  4 | dave  |    2001 |
|  5 | erin  |    2001 |
+----+-------+---------+
```

erin 凭空出现了：UPDATE 是当前读，它看到了 B 刚提交的 erin 并改了它；erin 这一行的最新版本是 A 自己改出来的，而一个事务总能看到自己的修改，于是 A 再做快照读时，erin 也出现了。官方文档对此的说明是：快照作用于事务里的 SELECT，不一定作用于 DML。

要避免这种情况，原则是：**打算基于读到的结果去写，就从一开始用加锁读**。在可重复读下，`SELECT ... FOR UPDATE` 会锁住扫描到的记录和它们之间的间隙，别的事务插不进来：

```sql
-- 会话 A
BEGIN;
SELECT * FROM account WHERE id >= 4 FOR UPDATE;    -- dave、erin

-- 会话 B
INSERT INTO account VALUES (6, 'frank', 2000);     -- 卡住，等 A 提交
```

B 一直等到锁等待超时：

```text
ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction
```

### 串行化：读也加锁

串行化级别下，A 只用普通 SELECT，不写 `FOR UPDATE`，B 的插入照样被挡住：

```sql
-- 会话 A
SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN;
SELECT * FROM account WHERE id >= 4;    -- 被自动改成了加锁读

-- 会话 B
INSERT INTO account VALUES (6, 'frank', 2000);
```

```text
ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction
```

代价是读写互相阻塞：一个大查询开着事务，别人就改不了它读过的范围，并发能力大幅下降。有个例外：不在显式事务里、单独执行的 SELECT（autocommit 打开时）自成一个只读事务，不会被改成加锁读。

## 查看和设置隔离级别

```sql
SELECT @@transaction_isolation;          -- 当前会话
SELECT @@GLOBAL.transaction_isolation;   -- 全局默认值
```

```text
+-------------------------+
| @@transaction_isolation |
+-------------------------+
| REPEATABLE-READ         |
+-------------------------+
```

`SET TRANSACTION` 有三种写法，作用范围不同：

| 写法 | 作用范围 |
| --- | --- |
| `SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED;` | 之后新建的连接，已经存在的连接不受影响；需要 `CONNECTION_ADMIN` 权限 |
| `SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;` | 当前连接之后的所有事务，正在进行的事务不受影响 |
| `SET TRANSACTION ISOLATION LEVEL READ COMMITTED;` | 只管当前连接的**下一个**事务，之后恢复会话的设置 |

第三种不能在事务进行中执行：

```sql
BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

```text
ERROR 1568 (25001): Transaction characteristics can't be changed while a transaction is in progress
```

想让服务器启动时就用某个级别，写进配置文件。注意值里用短横线代替空格：

```ini
[mysqld]
transaction-isolation = READ-COMMITTED
```

在 Spring 里还可以按方法单独指定，`@Transactional(isolation = ...)` 默认跟随数据库的设置，见 [[Spring 事务管理]]。

## 选哪个级别

- **默认的可重复读**：大多数场景直接用。记住它只保证普通 SELECT 前后一致；要基于读到的数据去写，用 `SELECT ... FOR UPDATE`。
- **读已提交**：不锁间隙，并发插入时锁等待和死锁更少；代价是同一事务里两次读可能不一致。在这个级别下，binlog 只支持行格式，`binlog_format=MIXED` 时服务器会自动改用行格式记录，详见 [[MySQL 日志]]。
- **读未提交**：会读到最终可能被回滚的数据，几乎没有使用的理由。
- **串行化**：读写互相阻塞，只在确实需要严格串行、又能接受低并发时才用。

不管哪个级别，两个事务修改同一行都得排队：写操作总要给行加排他锁，后来的那个只能等前一个提交或回滚。

## 参考

- [MySQL 8.4 Reference Manual: Transaction Isolation Levels](https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-isolation-levels.html)
- [MySQL 8.4 Reference Manual: Consistent Nonlocking Reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)
- [MySQL 8.4 Reference Manual: SET TRANSACTION Statement](https://dev.mysql.com/doc/refman/8.4/en/set-transaction.html)
