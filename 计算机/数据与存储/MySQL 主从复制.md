---
tags: [类型/实践, 技术/MySQL]
aliases: [MySQL Replication]
created: 2026-10-17
updated: 2026-10-17
---
> 主从复制让一台或多台从库自动跟上主库的数据：主库把每个事务写进 binlog，从库的 I/O 线程把 binlog 拉过来存成 relay log，SQL 线程再把它重放一遍。默认是异步复制，主库不等从库，所以从库总会落后一点，刚写完立刻去从库读可能读不到；从库也必须设成只读，否则一次误写就能让复制停下来。

## 典型场景：给数据库加一台只读副本

一个商品网站读多写少，查询把数据库的 CPU 占满了，写入却没多少。想加一台机器分担查询：所有写操作仍然发给原来的库（**主库**，官方叫 source），新机器上的数据自动和主库保持一致，只接查询（**从库**，官方叫 replica）。从库还能当热备：主库坏了，把从库提上来顶替。

## 原理：三个线程，两份日志

复制的原料是主库的 binlog，它按提交顺序记录了主库上的每一次数据修改，详见 [[MySQL 日志]]。

```text
       主库                                        从库
┌──────────────────┐                     ┌──────────────────────────────┐
│ 事务提交           │                     │                              │
│   ↓              │  ① I/O 线程连上来     │  I/O 线程（接收）              │
│ binlog           │ ←──────────────────  │   ↓                          │
│   ↓              │  ② 推送 binlog 事件   │  relay log（中继日志）         │
│ Binlog Dump 线程  │ ──────────────────→  │   ↓                          │
└──────────────────┘                     │  SQL 线程（协调）→ worker 线程  │
                                         │   ↓ ③ 重放                    │
                                         │  从库的数据                    │
                                         └──────────────────────────────┘
```

- **Binlog Dump 线程**（主库）：每连上来一个从库，主库就为它开一个线程，把 binlog 里的内容发过去
- **I/O 线程**（从库，也叫接收线程）：执行 `START REPLICA` 后创建，负责连接主库、请求 binlog，把收到的事件原样写进本地的 **relay log**（中继日志）
- **SQL 线程**（从库，也叫应用线程）：读 relay log，把里面的事务在从库上重新执行一遍

拆成「先存下来，再执行」两步，好处是两边速度互不拖累：重放慢了，接收照样进行，主库那边的 binlog 早早就到了从库手里。

MySQL 8.4 默认开了多线程重放：`replica_parallel_workers` 默认是 4，SQL 线程变成协调者，把事务分给 4 个 worker 线程并行执行；`replica_preserve_commit_order` 默认打开，保证并行执行的事务仍按 relay log 里的顺序（也就是主库上的提交顺序）提交，从库不会出现主库上从未出现过的中间状态。

## 动手搭一套一主一从

### 1. 起两个容器

起两个 MySQL 8.4.11 容器，放进同一个 Docker 网络，彼此用容器名就能访问。下面用空 root 密码只是为了本机实验省事：

```bash
docker network create jn-repl

docker run -d --name jn-source --network jn-repl -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
  mysql:8.4 --server-id=1 --gtid-mode=ON --enforce-gtid-consistency=ON

docker run -d --name jn-replica --network jn-repl -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
  mysql:8.4 --server-id=2 --gtid-mode=ON --enforce-gtid-consistency=ON
```

三个参数的意思：

- `--server-id`：每台参与复制的 MySQL 都要有一个不同的编号，binlog 里的每个事件都带着产生它的服务器编号。两台一样会怎样，见后文的坑
- `--gtid-mode=ON`：开启 **GTID**（Global Transaction Identifier，全局事务标识）。每个事务提交时得到一个全局唯一的编号，格式是 `服务器UUID:序号`，比如 `2be7b58d-ca0c-11f1-b1e6-6a97465e5805:12` 就是那台服务器上提交的第 12 个事务
- `--enforce-gtid-consistency=ON`：拒绝执行那些没法安全地用 GTID 记录的语句，开 GTID 时必须一起打开

### 2. 主库：建复制账号

从库要用一个账号登录主库来拉 binlog，这个账号只需要 `REPLICATION SLAVE` 权限（权限名还是旧叫法）：

```sql
-- 在主库上执行
CREATE USER 'repl'@'%' IDENTIFIED BY 'repl_pass';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
```

顺便建点数据，待会看它能不能同步过去：

```sql
CREATE DATABASE shop;
CREATE TABLE shop.orders (id INT AUTO_INCREMENT PRIMARY KEY, item VARCHAR(32) NOT NULL, amount INT NOT NULL);
INSERT INTO shop.orders (item, amount) VALUES ('keyboard', 299);
```

### 3. 从库：指向主库，开始复制

```sql
-- 在从库上执行
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = 'jn-source',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl',
  SOURCE_PASSWORD = 'repl_pass',
  SOURCE_AUTO_POSITION = 1,
  GET_SOURCE_PUBLIC_KEY = 1;

START REPLICA;
```

- `SOURCE_AUTO_POSITION = 1`：用 GTID 自动定位。从库把自己执行过哪些 GTID 告诉主库，主库把缺的那些发过来，不用人去找 binlog 的文件名和位置
- `GET_SOURCE_PUBLIC_KEY = 1`：MySQL 8.4 的账号默认用 `caching_sha2_password` 认证，在不加密的连接上需要先向主库要一把公钥来加密密码。漏了这一项会怎样，见后文的坑

实验里主库的 binlog 是从初始化开始完整保留的，从库能从第一个事务追起。生产环境的主库往往已经跑了很久，旧的 binlog 早就过期删除了，这时要先把一份全量备份导入从库，再从备份对应的位置开始复制，备份方法见 [[MySQL 日志]] 里的 `mysqldump`。不用 GTID 的老办法，是把备份文件里记下的文件名和位置填进 `SOURCE_LOG_FILE`、`SOURCE_LOG_POS`。

### 4. 检查复制状态

```sql
SHOW REPLICA STATUS\G
```

截取其中最常看的几项：

```text
             Replica_IO_State: Waiting for source to send event
                  Source_Host: jn-source
              Source_Log_File: binlog.000002
          Read_Source_Log_Pos: 1481
               Relay_Log_File: f70d40e18ce4-relay-bin.000003
        Relay_Source_Log_File: binlog.000002
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
          Exec_Source_Log_Pos: 1481
        Seconds_Behind_Source: 0
                Last_IO_Error: 
               Last_SQL_Error: 
    Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
           Retrieved_Gtid_Set: 2be7b58d-ca0c-11f1-b1e6-6a97465e5805:1-10
                Auto_Position: 1
```

- `Replica_IO_Running` 和 `Replica_SQL_Running` 都是 `Yes`：两个线程都在正常工作。**这是第一眼要看的**
- `Read_Source_Log_Pos`：I/O 线程从主库读到了哪个位置；`Exec_Source_Log_Pos`：SQL 线程执行到了哪个位置。两个值相等，说明收到的都执行完了
- `Seconds_Behind_Source`：从库落后主库的估计秒数
- `Retrieved_Gtid_Set`：已经收到的主库事务，这里是主库 UUID 下的第 1 到 10 个
- `Last_IO_Error`、`Last_SQL_Error`：出错时原因写在这里

老教程里的 `SHOW SLAVE STATUS`、`START SLAVE`、`CHANGE MASTER TO` 在 8.4 里都已删除，执行会直接报语法错误：

```text
ERROR 1064 (42000): You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'SLAVE STATUS' at line 1
```

两边的线程也能直接看到。主库上：

```sql
SELECT ID, USER, HOST, COMMAND, STATE FROM information_schema.PROCESSLIST WHERE USER = 'repl';
```

```text
+----+------+------------------+------------------+-----------------------------------------------------------------+
| ID | USER | HOST             | COMMAND          | STATE                                                           |
+----+------+------------------+------------------+-----------------------------------------------------------------+
| 10 | repl | 172.19.0.3:38330 | Binlog Dump GTID | Source has sent all binlog to replica; waiting for more updates |
+----+------+------------------+------------------+-----------------------------------------------------------------+
```

从库上：

```sql
SELECT NAME, PROCESSLIST_STATE FROM performance_schema.threads WHERE NAME LIKE 'thread/sql/replica%';
```

```text
+---------------------------+----------------------------------------------------------+
| NAME                      | PROCESSLIST_STATE                                        |
+---------------------------+----------------------------------------------------------+
| thread/sql/replica_io     | Waiting for source to send event                         |
| thread/sql/replica_sql    | Replica has read all relay log; waiting for more updates |
| thread/sql/replica_worker | Waiting for an event from Coordinator                    |
| thread/sql/replica_worker | Waiting for an event from Coordinator                    |
| thread/sql/replica_worker | Waiting for an event from Coordinator                    |
| thread/sql/replica_worker | Waiting for an event from Coordinator                    |
+---------------------------+----------------------------------------------------------+
```

和原理图一一对应：主库一个 Dump 线程，从库一个 I/O 线程、一个协调用的 SQL 线程、4 个 worker。从库的数据目录里也多出了 relay log 文件：`f70d40e18ce4-relay-bin.000002`、`f70d40e18ce4-relay-bin.000003` 和索引文件 `f70d40e18ce4-relay-bin.index`，文件名前缀是从库的主机名。

在从库上查一下，主库那行数据已经过来了：

```sql
SELECT * FROM shop.orders;
```

```text
+----+----------+--------+
| id | item     | amount |
+----+----------+--------+
|  1 | keyboard |    299 |
+----+----------+--------+
```

### 5. 把从库设成只读

```sql
-- 在从库上执行
SET GLOBAL super_read_only = ON;
```

为什么非设不可，以及为什么是 `super_read_only` 而不是 `read_only`，见下面第二个坑。要让重启后依然生效，把 `super_read_only = ON` 写进从库的配置文件。

## 坑：刚写完，去从库读不到

默认的复制是**异步**的：主库提交事务时只管写自己的 binlog，不等任何从库收到。从库收到之后还要排队重放。所以一个事务在主库提交和在从库可见之间，总有一段时间差。

把从库的 SQL 线程停掉，可以把这段时间差放大来看：

```sql
-- 从库
STOP REPLICA SQL_THREAD;

-- 主库
INSERT INTO shop.orders (item, amount) VALUES ('mouse', 99);

-- 从库
SELECT * FROM shop.orders;
```

```text
+----+----------+--------+
| id | item     | amount |
+----+----------+--------+
|  1 | keyboard |    299 |
+----+----------+--------+
```

主库上已经提交的 mouse 在从库上看不到。复制状态里能看出卡在哪一步：

```text
          Read_Source_Log_Pos: 1773
           Replica_IO_Running: Yes
          Replica_SQL_Running: No
          Exec_Source_Log_Pos: 1481
        Seconds_Behind_Source: NULL
           Retrieved_Gtid_Set: 2be7b58d-ca0c-11f1-b1e6-6a97465e5805:1-11
```

I/O 线程已经收到了第 11 个事务（读到 1773），SQL 线程还停在 1481。注意 `Seconds_Behind_Source` 是 `NULL` 而不是一个很大的数：SQL 线程没在运行时，它根本算不出延迟。监控脚本如果只判断「这个值大于多少秒就报警」，`NULL` 会被漏掉，所以要同时检查两个 `Running` 字段。

`START REPLICA SQL_THREAD;` 之后，mouse 立刻出现在从库上。

大事务、从库机器配置差、从库上跑着重查询，都会拉大延迟。写完马上就要读的业务，有几种处理办法：

- **写后读走主库**：比如用户刚提交订单，跳转后的订单详情页从主库读
- **等从库追上指定的 GTID**：在主库上提交后取得 GTID，到从库上用 `WAIT_FOR_EXECUTED_GTID_SET` 等它执行完，第二个参数是超时秒数

```sql
-- 主库提交后
SELECT @@GLOBAL.gtid_executed;    -- 2be7b58d-ca0c-11f1-b1e6-6a97465e5805:1-17

-- 从库
SELECT WAIT_FOR_EXECUTED_GTID_SET('2be7b58d-ca0c-11f1-b1e6-6a97465e5805:1-17', 1);    -- 0：已经执行到了
SELECT WAIT_FOR_EXECUTED_GTID_SET('2be7b58d-ca0c-11f1-b1e6-6a97465e5805:1-99', 1);    -- 1：等了 1 秒还没到，超时
```

## 坑：从库被写入，复制停了

从库上没设只读时，有人（或者配错了数据源的程序）直接往从库里写了一行：

```sql
-- 从库
INSERT INTO shop.orders (id, item, amount) VALUES (3, 'oops', 1);

-- 主库：正常插入一行，自增出来的 id 恰好也是 3
INSERT INTO shop.orders (item, amount) VALUES ('monitor', 1299);
```

主库的这条插入同步到从库时，主键 3 已经被占了：

```text
           Replica_IO_Running: Yes
          Replica_SQL_Running: No
               Last_SQL_Errno: 1062
               Last_SQL_Error: Coordinator stopped because there were error(s) in the worker(s). The most recent failure being: Worker 1 failed executing transaction '2be7b58d-ca0c-11f1-b1e6-6a97465e5805:12' at source log binlog.000002, end_log_pos 2036. See error log and/or performance_schema.replication_applier_status_by_worker table for more details about this failure or others, if any.
```

SQL 线程停了。按提示去查具体原因：

```sql
SELECT WORKER_ID, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE
FROM performance_schema.replication_applier_status_by_worker
WHERE LAST_ERROR_NUMBER <> 0\G
```

```text
*************************** 1. row ***************************
         WORKER_ID: 1
 LAST_ERROR_NUMBER: 1062
LAST_ERROR_MESSAGE: Worker 1 failed executing transaction '2be7b58d-ca0c-11f1-b1e6-6a97465e5805:12' at source log binlog.000002, end_log_pos 2036; Could not execute Write_rows event on table shop.orders; Duplicate entry '3' for key 'orders.PRIMARY', Error_code: 1062; handler error HA_ERR_FOUND_DUPP_KEY; the event's source log binlog.000002, end_log_pos 2036
```

从这一刻起，主库上的所有修改都只会堆在 relay log 里，从库的数据停在出错之前。这里的修法是删掉从库上那条不该有的数据，再启动 SQL 线程：

```sql
DELETE FROM shop.orders WHERE id = 3;
START REPLICA SQL_THREAD;
```

主库的 monitor 随即同步过来。真实环境里冲突的数据往往不止一条，也未必能看出哪边是对的，修起来要麻烦得多。

所以从库一定要设只读，而且要用 `super_read_only`。只设 `read_only` 时，普通账号写不进来，但拥有 `CONNECTION_ADMIN`（或旧的 `SUPER`）权限的账号照样能写，root 就有这个权限：

```sql
SET GLOBAL read_only = ON;
SELECT @@read_only, @@super_read_only;    -- 1, 0
INSERT INTO shop.orders (id, item, amount) VALUES (100, 'ro-test', 1);    -- root 执行，成功了
```

换成 `super_read_only`（打开它会自动把 `read_only` 也打开），root 也写不进去了：

```sql
SET GLOBAL super_read_only = ON;
INSERT INTO shop.orders (item, amount) VALUES ('oops', 1);
```

```text
ERROR 1290 (HY000): The MySQL server is running with the --super-read-only option so it cannot execute this statement
```

只读不影响复制本身，主库新插入的数据照常同步到从库。

还有一层隐患：从库上自己执行过的事务，会以从库自己的 UUID 记进它的 GTID 集合，主库上并没有这些事务。哪天这台从库被提升成主库，其他从库会通过 GTID 自动定位把这些事务也拉过去执行。设了 `super_read_only`，这种情况就不会发生。

## 坑：两台机器 server_id 一样

忘了改 `server_id`，两台都用了同一个值，I/O 线程连上主库就会立刻停下：

```text
           Replica_IO_Running: No
                Last_IO_Errno: 13117
                Last_IO_Error: Fatal error: The replica I/O thread stops because source and replica have equal MySQL server ids; these ids must be different for replication to work (or the --replicate-same-server-id option must be used on replica but this does not always make sense; please check the manual before using it).
```

binlog 事件里带着产生它的服务器编号，复制靠它分辨事件来自哪台服务器。主从编号相同，MySQL 无法分辨，I/O 线程直接拒绝工作。给每台机器设一个不重复的值就好。

## 坑：漏了 GET_SOURCE_PUBLIC_KEY

`CHANGE REPLICATION SOURCE TO` 里不写 `GET_SOURCE_PUBLIC_KEY = 1`，连接也没开 SSL，I/O 线程会一直卡在 `Connecting`：

```text
           Replica_IO_Running: Connecting
                Last_IO_Errno: 2061
                Last_IO_Error: Error connecting to source 'repl@jn-source:3306'. This was attempt 1/10, with a delay of 60 seconds between attempts. Message: Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection.
```

这个错有时不会马上暴露。`caching_sha2_password` 会在服务器内存里缓存认证成功过的账号，缓存还在时不需要公钥也能连上；主库一重启或者执行 `FLUSH PRIVILEGES`，缓存清空，复制就断了（上面的报错就是在主库执行 `FLUSH PRIVILEGES` 之后复现的）。所以搭建时就把这一项写上，或者给复制连接配好 SSL。

## 异步和半同步

异步复制下，主库提交完就返回，不知道也不关心从库收没收到。主库如果在这时宕机，已经提交的事务可能一个从库都没收到，切到从库后这些数据就丢了。

**半同步复制**（semisynchronous replication）在这点上收紧了一步：主库提交事务后，要等至少一个从库确认「收到了」才返回给客户端。从库确认的时机是把事件写进 relay log 并刷盘之后，不用等到重放完成。所以半同步保证的是「至少有一个从库手里有这份数据」，不保证从库上已经能查到。

半同步以插件形式提供，主从两边各装一个：

```sql
-- 主库
INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';
SET GLOBAL rpl_semi_sync_source_enabled = ON;

-- 从库（如果开了 super_read_only，安装插件前要先临时关掉）
INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';
SET GLOBAL rpl_semi_sync_replica_enabled = ON;
STOP REPLICA IO_THREAD;
START REPLICA IO_THREAD;    -- 重连之后半同步才生效
```

在主库上确认：

```sql
SHOW STATUS LIKE 'Rpl_semi_sync_source_clients';    -- 1：有一个半同步从库连着
SHOW STATUS LIKE 'Rpl_semi_sync_source_status';     -- ON
```

等待有上限。从库迟迟不确认，超过 `rpl_semi_sync_source_timeout`（默认 10000 毫秒）后，主库自动退回异步复制。把从库的 I/O 线程停掉，主库插入一行：

```text
Query OK, 1 row affected (8.74 sec)
```

这条插入卡了 8 秒多才返回，之后半同步状态变成了 `OFF`：

```sql
SHOW STATUS LIKE 'Rpl_semi_sync_source_status';    -- OFF
```

从库重新连上并追上进度后，它会自动变回 `ON`。这意味着半同步在从库出问题时会悄悄退化成异步，要靠监控 `Rpl_semi_sync_source_status` 才能发现。

## 参考

- [MySQL 8.4 Reference Manual: Replication Threads](https://dev.mysql.com/doc/refman/8.4/en/replication-threads.html)
- [MySQL 8.4 Reference Manual: Semisynchronous Replication](https://dev.mysql.com/doc/refman/8.4/en/replication-semisync.html)
- [MySQL 8.4 Reference Manual: CHANGE REPLICATION SOURCE TO Statement](https://dev.mysql.com/doc/refman/8.4/en/change-replication-source-to.html)
- [MySQL 8.4 Reference Manual: Replication with Global Transaction Identifiers](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids.html)
