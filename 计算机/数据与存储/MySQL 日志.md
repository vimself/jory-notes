---
tags: [类型/概念, 技术/MySQL]
aliases: [redo log, undo log, binlog, 重做日志, 回滚日志, 二进制日志]
created: 2026-10-17
updated: 2026-10-17
---
> MySQL 写数据时会留下三种日志。redo log 记录数据页被改成了什么，崩溃后靠它把已提交的修改补回来；undo log 记录怎么撤销一次修改，事务回滚和 MVCC 读旧版本都靠它；binlog 记录数据发生过哪些变化，主从复制和按时间点恢复靠它。redo log 和 binlog 之间用两阶段提交保证内容一致。

## 典型场景：断电和误删

两个问题：

1. 一条 UPDATE 提交成功，客户端收到了 OK，下一秒机器断电。重启之后，这条修改还在吗？
2. 下午三点，有人执行了一条不带 WHERE 的 `DELETE`，订单表被清空了。最近一次全量备份是凌晨两点。备份之后到三点之间新增的订单，还能找回来吗？

只要日志配置得当，两个问题的答案都是「能」。第一个靠 redo log，第二个靠 binlog。`ROLLBACK` 能撤销修改、[[MySQL MVCC]] 能读到旧版本，靠的是 undo log。

本篇输出来自 MySQL 8.4.11 的默认配置。

## 三种日志一览

MySQL 内部分两层：**服务层**负责连接、解析 SQL、优化执行计划；**存储引擎**负责把数据真正存到磁盘上、再读出来，InnoDB 是默认的存储引擎。三种日志分属不同的层：

| | redo log | undo log | binlog |
| --- | --- | --- | --- |
| 属于 | InnoDB | InnoDB | 服务层，和用哪个存储引擎无关 |
| 记什么 | 数据页被改成了什么 | 修改前的旧值，用来撤销这次修改 | 数据发生了哪些变化，默认按行记录 |
| 用来 | 崩溃恢复 | 事务回滚、MVCC 读旧版本 | 主从复制、按时间点恢复 |
| 留多久 | 对应的数据页写进数据文件后就可以截掉 | 没有事务再需要它时被清理 | 默认保留 30 天 |
| 文件 | `#innodb_redo/#ib_redoN` | `undo_001`、`undo_002` | `binlog.000001`、`binlog.000002`…… |

## 先说清楚两个词

**buffer pool（缓冲池）**：InnoDB 在内存里开的一块缓存，存放从磁盘读上来的数据页（页是 InnoDB 读写磁盘的最小单位，默认 16KB，见 [[MySQL 索引]]）。修改数据时，InnoDB 只改 buffer pool 里的页，把它标记为「脏页」，由后台线程过一阵再写回磁盘上的数据文件。

**刷盘**：把数据真正写到磁盘上。程序调用 `write` 只是把数据交给操作系统，操作系统可能先放在自己的文件缓存里；调用 `fsync` 才能保证数据落到磁盘。MySQL 进程崩溃时，已经交给操作系统的数据不会丢；断电或操作系统崩溃时，还在操作系统缓存里的数据就丢了。

提交时如果只改了内存里的页，还没写回磁盘就断电，已提交的修改就没了。每次提交都把改过的页写回磁盘也不现实，一个事务可能改了散落在各处的几十个页，每页 16KB，全是随机写，太慢。

## redo log：先记账，后改数据

InnoDB 的办法是 **WAL**（Write-Ahead Logging，预写日志）：提交时不急着写数据页，先把「哪个页的哪个位置改成了什么」追加写进 redo log，redo log 落了盘，提交就算成功。数据页什么时候写回磁盘都行。万一崩溃，重启时按 redo log 把还没写回的修改重做一遍。

这样快在两点：redo 记录只描述改动本身，比整个 16KB 的页小得多；而且它是在文件末尾顺序追加，不像写数据页那样到处跳着写。

### LSN 和检查点

redo log 里的位置用 **LSN**（Log Sequence Number，日志序列号）表示，它随着写入只增不减。执行一条 UPDATE 前后，看三个状态值的变化：

```sql
SHOW STATUS LIKE 'Innodb_redo_log_%lsn';
UPDATE test.account SET balance = balance + 1;
SHOW STATUS LIKE 'Innodb_redo_log_%lsn';
```

```text
+-------------------------------------+----------+
| Variable_name                       | Value    |
+-------------------------------------+----------+
| Innodb_redo_log_checkpoint_lsn      | 34570932 |
| Innodb_redo_log_current_lsn         | 34570932 |
| Innodb_redo_log_flushed_to_disk_lsn | 34570932 |
+-------------------------------------+----------+
+-------------------------------------+----------+
| Variable_name                       | Value    |
+-------------------------------------+----------+
| Innodb_redo_log_checkpoint_lsn      | 34570932 |
| Innodb_redo_log_current_lsn         | 34572790 |
| Innodb_redo_log_flushed_to_disk_lsn | 34572790 |
+-------------------------------------+----------+
```

- `current_lsn` 涨了 1858：这条 UPDATE 产生了 1858 字节的 redo
- `flushed_to_disk_lsn` 跟着涨到同一个值：提交时 redo 已经刷盘了，这正是持久性的保证
- `checkpoint_lsn` 没动：被改的数据页还在内存里，没有写回数据文件

**检查点**（checkpoint）之前的修改，对应的数据页都已经写回磁盘，这部分 redo 不再需要。崩溃恢复从最近的检查点开始，把它之后的 redo 重放一遍。检查点不断往前推，最老的 redo 也就随之被截掉，所以 redo log 只占固定大小的空间。

### 文件和容量

redo log 占多大空间由 `innodb_redo_log_capacity` 决定，默认 100MB：

```sql
SHOW VARIABLES LIKE 'innodb_redo_log_capacity';    -- 104857600
```

InnoDB 维持 32 个 redo 文件，每个占容量的 1/32，放在数据目录的 `#innodb_redo` 子目录下。正在使用的叫 `#ib_redoN`，备用的带 `_tmp` 后缀：

```text
-rw-r----- 1 mysql mysql 3276800 Oct 17 09:18 #ib_redo9
-rw-r----- 1 mysql mysql 3276800 Oct 17 09:10 #ib_redo10_tmp
-rw-r----- 1 mysql mysql 3276800 Oct 17 09:10 #ib_redo11_tmp
……（一直到 #ib_redo40_tmp）
```

每个文件覆盖一段 LSN，可以在 `performance_schema` 里查到：

```sql
SELECT FILE_NAME, START_LSN, END_LSN FROM performance_schema.innodb_redo_log_files;
```

```text
+---------------------------+-----------+----------+
| FILE_NAME                 | START_LSN | END_LSN  |
+---------------------------+-----------+----------+
| ./#innodb_redo/#ib_redo9  |  29480960 | 32755712 |
| ./#innodb_redo/#ib_redo10 |  32755712 | 36030464 |
+---------------------------+-----------+----------+
```

容量可以在线调整，例如调到 8GB：`SET GLOBAL innodb_redo_log_capacity = 8589934592;`。写入很密集时容量偏小，检查点就得频繁推进，后台被迫更积极地写回脏页。

### 提交时刷不刷盘：innodb_flush_log_at_trx_commit

「提交时 redo 落盘」是默认行为，由 `innodb_flush_log_at_trx_commit` 控制：

| 值 | 提交时做什么 | MySQL 进程崩溃 | 断电或系统崩溃 |
| --- | --- | --- | --- |
| `1`（默认） | 写入并刷盘 | 不丢 | 不丢 |
| `2` | 写入操作系统，每秒刷盘一次 | 不丢 | 可能丢最近约 1 秒的事务 |
| `0` | 什么都不做，每秒写入并刷盘一次 | 可能丢最近约 1 秒的事务 | 可能丢最近约 1 秒的事务 |

区别全在前面说的 `write` 和 `fsync`：设成 2 时 redo 已经交给操作系统，进程崩溃不影响；设成 0 时 redo 还在 MySQL 自己的内存里，进程一崩就没了。「每秒一次」的间隔由 `innodb_flush_log_at_timeout` 控制，默认 1 秒。只有 1 能完全满足 ACID 的持久性，0 和 2 是拿数据安全换写入速度。

## undo log：记下怎么撤回

每次修改一行之前，InnoDB 都先写一条 undo 记录，内容是怎么把这次修改撤销掉：插入了一行，撤销就是把它删掉；改了一行，就记下改之前的旧值；删除一行时并不立刻删，只是打上删除标记，同样记一条 undo。

它有两个用途：

- **回滚**：`ROLLBACK` 时按相反顺序执行这个事务的 undo 记录，把数据恢复原样。事务的原子性就靠它
- **MVCC**：undo 记录里的旧值串成版本链，快照读沿着它找到自己该看的版本，见 [[MySQL MVCC]]

undo log 分两类，清理时机不同：

- **insert undo**：只在回滚时用得上，事务一提交就可以丢弃，因为新插入的行没有更早的版本需要还原
- **update undo**：MVCC 也要用。只要还有某个事务的快照可能需要它来还原旧版本，就不能丢

undo log 存放在独立的 undo 表空间里，实例初始化时默认建两个：

```sql
SELECT NAME, SPACE_TYPE, STATE FROM information_schema.INNODB_TABLESPACES WHERE SPACE_TYPE = 'Undo';
```

```text
+-----------------+------------+--------+
| NAME            | SPACE_TYPE | STATE  |
+-----------------+------------+--------+
| innodb_undo_001 | Undo       | active |
| innodb_undo_002 | Undo       | active |
+-----------------+------------+--------+
```

对应数据目录下的 `undo_001`、`undo_002` 两个文件。

### purge 和 history list

不再被任何事务需要的 update undo，由后台的 **purge**（清除）线程清理。打了删除标记的行，也是在 purge 时才被真正删掉。已提交、等待 purge 的 undo 排成一个列表，叫 **history list**，它的长度显示在 `SHOW ENGINE INNODB STATUS` 的 `TRANSACTIONS` 一节里，正常情况下是个很小的数。

### 实测：一个不提交的快照，拖住一万个旧版本

会话 A 拍下快照，然后既不提交也不回滚；会话 B 对同一行做一万次更新，每次都是一个独立的事务：

```sql
-- 准备：每调用一次，就对 1 号账户做 n 次自增，每次 UPDATE 都自动提交
DELIMITER //
CREATE PROCEDURE bump(n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < n DO
    UPDATE account SET balance = balance + 1 WHERE id = 1;
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;
```

```sql
SHOW ENGINE INNODB STATUS\G    -- History list length 0

-- 会话 A
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT balance FROM account WHERE id = 1;    -- 900

-- 会话 B
CALL bump(10000);

SHOW ENGINE INNODB STATUS\G    -- History list length 10001

-- 会话 A
SELECT balance FROM account WHERE id = 1;    -- 还是 900，别的连接查是 10900
COMMIT;

-- 5 秒后
SHOW ENGINE INNODB STATUS\G    -- History list length 1
```

A 的快照还开着，B 产生的一万个旧版本 purge 一个也不能清：A 随时可能来读，得能沿版本链一路退回 900。A 一提交，purge 几秒内就清空了。

生产环境里这种事务往往开了几个小时，后果有两个：undo 表空间持续膨胀；这个事务每次读一行，都要沿着很长的版本链往回走，越读越慢。undo 表空间超过 `innodb_max_undo_log_size`（默认 1GB）时，如果开着 `innodb_undo_log_truncate`（实测默认是 `ON`），InnoDB 会在 purge 清空后把它截回 16MB，但截断要等用着它的事务全部结束，长事务不结束，空间就收不回来。

找出开了很久的事务（实际使用时把阈值换成 60 秒之类的值）：

```sql
SELECT trx_mysql_thread_id, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS seconds,
       trx_state, trx_query
FROM information_schema.innodb_trx
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 1;
```

```text
+---------------------+---------------------+---------+-----------+-----------+
| trx_mysql_thread_id | trx_started         | seconds | trx_state | trx_query |
+---------------------+---------------------+---------+-----------+-----------+
|                  18 | 2026-10-17 09:24:10 |       3 | RUNNING   | NULL      |
+---------------------+---------------------+---------+-----------+-----------+
```

`trx_query` 为 `NULL` 表示这个连接此刻空闲，事务却没结束，多半是代码里漏了提交。`trx_mysql_thread_id` 就是连接 ID，可以拿去 `KILL`。

## binlog：记下数据发生了什么变化

binlog（binary log，二进制日志）属于服务层，记录所有修改数据的操作，`SELECT`、`SHOW` 这类不改数据的语句不记。MySQL 8.4 默认开启：

```sql
SHOW VARIABLES LIKE 'log_bin';    -- ON
SHOW BINARY LOGS;
```

```text
+---------------+-----------+-----------+
| Log_name      | File_size | Encrypted |
+---------------+-----------+-----------+
| binlog.000001 |   2996309 | No        |
| binlog.000002 |      9569 | No        |
+---------------+-----------+-----------+
```

文件名按序号递增，`binlog.index` 记录现有文件的清单。默认保留 30 天（`binlog_expire_logs_seconds` = 2592000），过期自动删除。查看当前正在写哪个文件、写到了哪个位置：

```sql
SHOW BINARY LOG STATUS;
```

老教程里的 `SHOW MASTER STATUS` 在 8.4 里已经删除，执行会直接报语法错误。

事务执行期间，它的修改先缓存在这个连接自己的 binlog 缓存里，提交时整个事务一次性写进 binlog。所以 binlog 里每个事务的内容是连续的，事务之间按提交顺序排列。

### 三种格式

| 格式 | 记录什么 |
| --- | --- |
| `ROW`（默认） | 每一行改之前和改之后的值 |
| `STATEMENT` | 原始的 SQL 语句 |
| `MIXED` | 默认按语句记，遇到不安全的语句自动改成按行记 |

**不安全的语句**是指在另一台机器上重放时，结果可能和原来不一样的语句。按语句记录时，MySQL 会当场提示：

```sql
SET SESSION binlog_format = 'STATEMENT';
DELETE FROM account LIMIT 1;
SHOW WARNINGS;
```

```text
+-------+------+---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Level | Code | Message                                                                                                                                                                                                                         |
+-------+------+---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Note  | 1592 | Unsafe statement written to the binary log using statement format since BINLOG_FORMAT = STATEMENT. The statement is unsafe because it uses a LIMIT clause. This is unsafe because the set of rows included cannot be predicted. |
+-------+------+---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
```

没有 `ORDER BY` 的 `LIMIT 1` 删的是「随便一行」，主库删了 alice，从库重放这条语句时删的可能是 bob，两边数据就对不上了。行格式直接记「删了主键为 1 的那一行」，没有这种问题。

`binlog_format` 这个变量本身也已经被标记为废弃，设置它时会收到警告：

```text
| Warning | 1287 | '@@binlog_format' is deprecated and will be removed in a future release. |
```

手册在这个变量的说明里写道：行格式以外的格式将来也可能被移除，新搭的复制环境只应使用行格式。所以直接用默认的 `ROW` 就好。行格式默认记录整行所有列的前后值（`binlog_row_image` = `FULL`）；设成 `MINIMAL` 只记能定位到这一行的列和实际改了的列，binlog 更小，但出事时能从里面找回的信息也更少。

### 看 binlog 里有什么

`SHOW BINLOG EVENTS` 列出一个 binlog 文件里的事件。下面是建库建表、插入两行、再插入一行、改一行、清空表之后的内容（截取后半段）：

```sql
SHOW BINLOG EVENTS IN 'binlog.000003';
```

```text
+---------------+------+----------------+-----------+-------------+------------------------------------------------------------------------------------------------------------------------------+
| Log_name      | Pos  | Event_type     | Server_id | End_log_pos | Info                                                                                                                         |
+---------------+------+----------------+-----------+-------------+------------------------------------------------------------------------------------------------------------------------------+
| binlog.000003 |  614 | Anonymous_Gtid |         1 |         693 | SET @@SESSION.GTID_NEXT= 'ANONYMOUS'                                                                                         |
| binlog.000003 |  693 | Query          |         1 |         764 | BEGIN                                                                                                                        |
| binlog.000003 |  764 | Table_map      |         1 |         825 | table_id: 97 (shop.orders)                                                                                                   |
| binlog.000003 |  825 | Write_rows     |         1 |         893 | table_id: 97 flags: STMT_END_F                                                                                               |
| binlog.000003 |  893 | Xid            |         1 |         924 | COMMIT /* xid=30373 */                                                                                                       |
| binlog.000003 |  924 | Anonymous_Gtid |         1 |        1003 | SET @@SESSION.GTID_NEXT= 'ANONYMOUS'                                                                                         |
| binlog.000003 | 1003 | Query          |         1 |        1074 | BEGIN                                                                                                                        |
| binlog.000003 | 1074 | Table_map      |         1 |        1135 | table_id: 123 (shop.orders)                                                                                                  |
| binlog.000003 | 1135 | Write_rows     |         1 |        1187 | table_id: 123 flags: STMT_END_F                                                                                              |
| binlog.000003 | 1187 | Xid            |         1 |        1218 | COMMIT /* xid=30414 */                                                                                                       |
| binlog.000003 | 1218 | Anonymous_Gtid |         1 |        1297 | SET @@SESSION.GTID_NEXT= 'ANONYMOUS'                                                                                         |
| binlog.000003 | 1297 | Query          |         1 |        1377 | BEGIN                                                                                                                        |
| binlog.000003 | 1377 | Table_map      |         1 |        1438 | table_id: 123 (shop.orders)                                                                                                  |
| binlog.000003 | 1438 | Update_rows    |         1 |        1504 | table_id: 123 flags: STMT_END_F                                                                                              |
| binlog.000003 | 1504 | Xid            |         1 |        1535 | COMMIT /* xid=30415 */                                                                                                       |
| binlog.000003 | 1535 | Anonymous_Gtid |         1 |        1614 | SET @@SESSION.GTID_NEXT= 'ANONYMOUS'                                                                                         |
| binlog.000003 | 1614 | Query          |         1 |        1685 | BEGIN                                                                                                                        |
| binlog.000003 | 1685 | Table_map      |         1 |        1746 | table_id: 123 (shop.orders)                                                                                                  |
| binlog.000003 | 1746 | Delete_rows    |         1 |        1831 | table_id: 123 flags: STMT_END_F                                                                                              |
| binlog.000003 | 1831 | Xid            |         1 |        1862 | COMMIT /* xid=30419 */                                                                                                       |
+---------------+------+----------------+-----------+-------------+------------------------------------------------------------------------------------------------------------------------------+
```

`Pos` 是事件在文件里的起始字节位置，`End_log_pos` 是结束位置。每个事务都是同一个结构：

- `Anonymous_Gtid`：事务的全局编号，这台机器没开 GTID 所以是匿名的，见 [[MySQL 主从复制]]
- `Query BEGIN`：事务开始
- `Table_map`：声明接下来的行事件作用于哪张表
- `Write_rows` / `Update_rows` / `Delete_rows`：插入、更新、删除的行数据
- `Xid`：事务提交，`xid` 是这个事务的编号，两阶段提交时靠它和 InnoDB 对账

行数据本身是二进制的，`SHOW BINLOG EVENTS` 不显示。要看具体改了什么，用 `mysqlbinlog` 工具把行事件解码成带注释的伪 SQL：

```bash
mysqlbinlog --base64-output=DECODE-ROWS -v /var/lib/mysql/binlog.000003
```

### 按时间点恢复：找回误删之前的数据

回到开头的第二个问题。完整的恢复流程是「全量备份 + 重放 binlog」：

**1. 定期全量备份，并记下备份时的 binlog 位置。**

```bash
mysqldump -uroot --single-transaction --source-data=2 --databases shop > full.sql
```

`--single-transaction` 在一个可重复读事务里导出，得到同一时刻的一致数据，不阻塞业务读写。它只对 InnoDB 这类事务表有效，导出期间别对这些表做 DDL；和 `--source-data` 一起用时，开头会短暂加一次全局读锁。`--source-data=2` 把备份时刻的 binlog 文件名和位置以注释的形式写进备份文件：

```text
--
-- Position to start replication or point-in-time recovery from
--

-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='binlog.000003', SOURCE_LOG_POS=924;
```

意思是：这份备份包含了 `binlog.000003` 位置 924 之前的所有修改。

**2. 备份之后照常有写入，然后出事了。** 上面那段 binlog 里，924 之后依次是：插入一行（924～1218）、更新一行（1218～1535）、误删全表（1535～1862）。

**3. 找到误操作的位置。** 在 `SHOW BINLOG EVENTS` 里找到 `Delete_rows`，它所在的事务从 1535 开始。要恢复的就是 924 到 1535 之间的事务。

**4. 先导入全量备份，再重放这一段 binlog。**

```bash
mysql -uroot -p < full.sql
mysqlbinlog --start-position=924 --stop-position=1535 /var/lib/mysql/binlog.000003 | mysql -uroot -p
```

`--start-position` 从这个位置开始的事件都会输出；`--stop-position` 从这个位置开始的事件**都不输出**。所以 1535 开始的那个误删事务正好被排除在外。如果误删之后还有正常的写入，再用 `--start-position=1862` 把后面的部分也重放一遍。

用 `mysqlbinlog` 的 `--start-datetime`、`--stop-datetime` 按时间截取也可以，但官方建议只用时间来**定位**，真正重放时还是用位置，按时间截取更容易漏掉事件。

## 两阶段提交：redo log 和 binlog 怎么对上账

一个事务提交时，redo log 和 binlog 都要写。两次写之间要是崩溃了，就会出现一边有、一边没有的情况：

- redo 有、binlog 没有：重启后主库上有这笔数据，但从库永远收不到，用 binlog 做的恢复里也没有它
- binlog 有、redo 没有：重启后主库上这笔数据没了，从库上却有

为了避免这种情况，MySQL 把提交拆成两步，这就是**两阶段提交**：

1. **prepare**：InnoDB 写好 redo，把事务标记为「已准备」，这时还不算提交
2. **写 binlog**：把整个事务写进 binlog，`sync_binlog=1` 时刷盘
3. **commit**：InnoDB 把事务标记为已提交

崩溃重启时，MySQL 先扫描最新的 binlog 文件，收集里面所有事务的 xid，然后逐个检查 InnoDB 里处于「已准备」状态的事务：xid 在 binlog 里出现过，就提交；没出现过，就回滚。binlog 末尾写了一半的事务会被截掉。

按崩溃的时刻分：

| 崩溃发生在 | binlog 里有它吗 | 重启后 |
| --- | --- | --- |
| prepare 之前 | 没有 | 事务没准备好，回滚 |
| prepare 之后、binlog 写完之前 | 没有 | 回滚，两边都没有 |
| binlog 写完之后、commit 之前 | 有 | 提交，两边都有 |

判断依据始终是 binlog 里有没有这个事务的 `Xid`，所以两边不会出现一边有、一边没有。

### 双 1 配置

两阶段提交要真正生效，前提是两边的日志在提交时都落了盘。`sync_binlog` 控制 binlog 什么时候刷盘：

| 值 | 含义 |
| --- | --- |
| `1`（默认） | 每次提交前刷盘。最安全，也最慢 |
| `0` | MySQL 不主动刷盘，交给操作系统决定。断电或系统崩溃时，已提交的事务可能不在 binlog 里 |
| `N` | 每攒够 N 组提交刷一次盘。断电或系统崩溃时同样可能丢 |

官方建议用 InnoDB 做主从复制时，`sync_binlog=1` 和 `innodb_flush_log_at_trx_commit=1` 同时设上，俗称「双 1」，两项都是默认值。为了提速改掉其中任何一个，都可能在断电后出现主库有、从库没有，或者反过来的数据不一致。

即使是双 1 也有一个前提：磁盘说「写好了」就真的写好了。有些操作系统和磁盘会对刷盘请求谎报完成，这种情况下双 1 也保证不了持久性。

## 参考

- [MySQL 8.4 Reference Manual: Redo Log](https://dev.mysql.com/doc/refman/8.4/en/innodb-redo-log.html)
- [MySQL 8.4 Reference Manual: Undo Tablespaces](https://dev.mysql.com/doc/refman/8.4/en/innodb-undo-tablespaces.html)
- [MySQL 8.4 Reference Manual: Purge Configuration](https://dev.mysql.com/doc/refman/8.4/en/innodb-purge-configuration.html)
- [MySQL 8.4 Reference Manual: The Binary Log](https://dev.mysql.com/doc/refman/8.4/en/binary-log.html)
- [MySQL 8.4 Reference Manual: Binary Logging Options and Variables](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html)
- [MySQL 8.4 Reference Manual: Point-in-Time Recovery Using Event Positions](https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery-positions.html)
- [MySQL 8.4 Reference Manual: mysqlbinlog](https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog.html)
