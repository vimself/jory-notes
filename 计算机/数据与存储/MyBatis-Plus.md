---
tags: [类型/实践, 技术/MyBatis, 技术/Spring Boot, 技术/Java]
aliases: [MyBatisPlus]
created: 2026-10-06
updated: 2026-10-06
---
> MyBatis-Plus 是在 [[MyBatis]] 上加的一层：Mapper 接口继承 `BaseMapper<实体>`，单表增删改查就不用再写 SQL；条件用 Java 链式调用拼（条件构造器），分页交给一个拦截器。MyBatis 原有的 XML 和注解写法照常能用，单表以外的复杂 SQL 还是自己写。

## 典型场景

[[Spring Boot]] 里迁移过来的图书管理接口，`BookDao` 有五个方法，每个方法上都挂着一句手写 SQL：

```java
@Mapper
public interface BookDao {
    @Insert("INSERT INTO tbl_book VALUES (null, #{type}, #{name}, #{description})")
    int save(Book book);

    @Update("UPDATE tbl_book SET type = #{type}, name = #{name}, description = #{description} WHERE id = #{id}")
    int update(Book book);

    @Delete("DELETE FROM tbl_book WHERE id = #{id}")
    int delete(Integer id);

    @Select("SELECT * FROM tbl_book WHERE id = #{id}")
    Book getById(Integer id);

    @Select("SELECT * FROM tbl_book")
    List<Book> getAll();
}
```

现在产品加了一个需求：列表页要能**按书名模糊搜索、按类型筛选，两个条件都可以不填，结果分页显示**。用原生 MyBatis 做，要写一段 XML 动态 SQL（每个条件包一层 `<if>`），再写一条 `COUNT` 查询算总数，然后自己算 `LIMIT` 的偏移量。表一多，这种「单表 + 几个可选条件 + 分页」的查询每张表都得写一遍，内容大同小异。

换成 MyBatis-Plus 之后，`BookDao` 变成这样：

```java
@Mapper
public interface BookDao extends BaseMapper<Book> {
}
```

一句 SQL 都没有，上面五个方法和那个分页搜索全都能做。

## 接入 Spring Boot

### 依赖：换掉 MyBatis 的 starter

MyBatis-Plus 按 Spring Boot 的大版本分了几个 starter，名字不一样，选错了启动不起来：

| Spring Boot | starter 的 artifactId |
| --- | --- |
| 2.x | `mybatis-plus-boot-starter` |
| 3.x | `mybatis-plus-spring-boot3-starter` |
| 4.x | `mybatis-plus-spring-boot4-starter`（3.5.13 起提供） |

图书案例用的是 Boot 4。把原来的 `mybatis-spring-boot-starter` **删掉**，换成：

```xml
<properties>
    <mybatis-plus.version>3.5.17</mybatis-plus.version>
</properties>

<dependencies>
    <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-spring-boot4-starter</artifactId>
        <version>${mybatis-plus.version}</version>
    </dependency>
    <!-- 分页插件在这个模块里，要用分页就必须加 -->
    <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-jsqlparser</artifactId>
        <version>${mybatis-plus.version}</version>
    </dependency>
    <!-- mysql-connector-j 等其余依赖不变 -->
</dependencies>
```

两个容易出错的地方：

- **不要和 MyBatis 的 starter 同时存在。** MyBatis-Plus 的 starter 已经带了它适配好的 MyBatis 和 MyBatis-Spring，官方文档明确要求不要再引入 `mybatis`、`mybatis-spring` 或 `mybatis-spring-boot-starter`，以免版本冲突
- **分页插件从 3.5.9 起拆了出去**，单独放在 `mybatis-plus-jsqlparser` 里。照着旧教程只加一个 starter，写分页配置时会找不到 `PaginationInnerInterceptor` 这个类。这个模块要求 JDK 11 以上；还在用 JDK 8 的项目改用 `mybatis-plus-jsqlparser-4.9`

### 配置：前缀从 mybatis 变成 mybatis-plus

原来 `application.yml` 里 `mybatis:` 开头的配置项，换了 starter 之后就不再被读取，要挪到 `mybatis-plus:` 下：

```yaml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/ssm_db
    username: root
    password: root

mybatis-plus:
  configuration:
    # 把执行的 SQL 打印到控制台，学习和排查时很有用
    log-impl: org.apache.ibatis.logging.stdout.StdOutImpl
  global-config:
    db-config:
      table-prefix: tbl_     # 实体 Book 对应表 tbl_book
      id-type: auto          # 主键用数据库自增，原因见下文
```

有一项不用配：**下划线转驼峰默认就是开的。** 在 [[MyBatis]] 里，列名 `user_name` 映射到属性 `userName` 需要手动打开 `mapUnderscoreToCamelCase`；MyBatis-Plus 把这个默认值改成了 `true`。

### Mapper：继承 BaseMapper

```java
@Mapper
public interface BookDao extends BaseMapper<Book> {
}
```

`BaseMapper<Book>` 里的泛型告诉 MyBatis-Plus「这个 Mapper 操作的是 `Book` 对应的那张表」。启动时它读取 `Book` 的类名和字段，为 `BaseMapper` 里的每个方法生成对应的 SQL，注册到 MyBatis 里，效果和你手写了一堆 `@Select`、`@Insert` 一样。

扫描方式和 MyBatis starter 一样：接口上加 `@Mapper`，或者在启动类上写 `@MapperScan("com.example.dao")`，二选一。

原来手写的方法可以留着。`BaseMapper` 只是多给了一批现成方法，接口里自己声明的方法、XML 映射文件都照常生效，复杂的多表查询继续手写。

## 实体怎么对上表

MyBatis-Plus 生成 SQL，靠的是从实体类推出表名、列名和主键。规则是约定优先，对不上的地方再用注解补。

| 推断什么 | 默认规则 | 对不上时 |
| --- | --- | --- |
| 表名 | 类名驼峰转下划线：`BookInfo` → `book_info`，再加上全局的 `table-prefix` | 类上加 `@TableName("表名")` |
| 列名 | 属性名驼峰转下划线：`createTime` → `create_time` | 属性上加 `@TableField("列名")` |
| 主键 | 名为 `id` 的属性 | 主键属性上加 `@TableId` |

图书表是 `tbl_book`，实体叫 `Book`。上面配了 `table-prefix: tbl_`，所以 `Book` 不用加任何注解。如果只有个别表有前缀，在类上写 `@TableName("tbl_book")` 也一样。

### 实体里有表中不存在的字段

比如给 `Book` 加一个页面展示用的 `coverUrl`，表里没有这一列。不处理的话，MyBatis-Plus 会把它当成一列拼进 SQL，执行时数据库报「未知列」。用 `exist = false` 告诉它跳过：

```java
public class Book {
    private Integer id;
    private String type;
    private String name;
    private String description;

    @TableField(exist = false)
    private String coverUrl;
    // getter / setter 省略
}
```

### 主键策略：默认不是自增

**MyBatis-Plus 全局默认的主键策略是 `ASSIGN_ID`**：插入前由它自己用雪花算法（一种分布式 ID 生成算法，生成的是一个按时间递增、很长的整数）算出一个 id 填进实体，**数据库的 `AUTO_INCREMENT` 根本用不上**。插完一看，新书的 id 是一个很长的数，而不是接着上一条的 6、7、8。

常用的几个值：

| `IdType` | 谁来生成 id |
| --- | --- |
| `AUTO` | 数据库自增 |
| `ASSIGN_ID` | MyBatis-Plus 用雪花算法生成，适用于 `Long`、`Integer`、`String` 类型的主键（全局默认） |
| `ASSIGN_UUID` | MyBatis-Plus 生成 UUID，适用于 `String` 主键 |
| `INPUT` | 插入前你自己 `setId` |

`tbl_book` 建表时用的是 `AUTO_INCREMENT`，所以上面的配置把全局策略改成了 `auto`。也可以只改一张表：在主键字段上写 `@TableId(type = IdType.AUTO)`。

两种策略下，`insert` 之后都能直接从你传进去的对象上 `getId()` 拿到 id，不用像原生 MyBatis 那样配 `useGeneratedKeys`。

## BaseMapper 的 CRUD

继承之后，`BookDao` 就有了下面这些方法（列的是常用的，`T` 就是 `Book`）：

| 操作 | 方法 | 返回 |
| --- | --- | --- |
| 增 | `insert(T entity)` | 受影响行数 |
| 删 | `deleteById(id)`、`deleteByIds(Collection ids)`、`delete(Wrapper)` | 受影响行数 |
| 改 | `updateById(T entity)`、`update(Wrapper)`、`update(T entity, Wrapper)` | 受影响行数 |
| 查一条 | `selectById(id)`、`selectOne(Wrapper)` | 实体，查不到为 `null` |
| 查多条 | `selectByIds(Collection ids)`、`selectList(Wrapper)` | `List<T>` |
| 计数 | `selectCount(Wrapper)` | `Long` |
| 是否存在 | `exists(Wrapper)` | `boolean` |
| 分页 | `selectPage(Page, Wrapper)` | 传进去的那个 `Page` |

带 `Wrapper` 参数的方法，`Wrapper` 就是下一节的条件构造器，传 `null` 表示不加条件。批量方法以前叫 `deleteBatchIds`、`selectBatchIds`，新版本里已经标成过时，换成了 `deleteByIds`、`selectByIds`，看旧教程时注意。

### 用它重写图书 Dao 的五个方法

```java
@SpringBootTest
class BookDaoTest {

    @Autowired
    private BookDao bookDao;

    @Test
    void crud() {
        Book book = new Book();
        book.setType("计算机");
        book.setName("深入理解计算机系统");
        book.setDescription("CSAPP");
        bookDao.insert(book);
        System.out.println(book.getId());          // 自增 id 已经回填

        Book found = bookDao.selectById(book.getId());
        List<Book> all = bookDao.selectList(null);  // 不加条件，查全表

        found.setDescription("第 3 版");
        bookDao.updateById(found);

        bookDao.deleteById(book.getId());
    }
}
```

开了 `log-impl` 之后，控制台能看到每一步实际发出的 SQL。`selectById` 发出的是 `SELECT id,type,name,description FROM tbl_book WHERE id=?`，列名是从实体字段逐个列出来的，不是 `SELECT *`。

### updateById 会跳过 null 字段

`updateById` 生成的 `UPDATE` 语句，`SET` 里**只包含值不为 `null` 的字段**。全局的更新策略默认是 `NOT_NULL`，插入也一样。

这个设计在大多数时候是好事：前端只传了要改的那一个字段，其余字段在对象里是 `null`，不会把库里原来的值清空。上面 `found.setDescription("第 3 版")` 那次更新，因为 `found` 是先查出来的完整对象，所有字段都会出现在 `SET` 里；如果换成 `new Book()` 只 set 了 `id` 和 `description`，`SET` 里就只有 `description`。

反过来，**你真想把某一列改成 `NULL` 时，`updateById` 做不到**：`book.setDescription(null)` 之后调 `updateById`，这一列根本不会出现在 SQL 里，不报错，数据也没变。两种办法：

- 用更新构造器显式 `set`，见下文 [[#更新构造器]]
- 在这个字段上写 `@TableField(updateStrategy = FieldStrategy.ALWAYS)`，以后它不管是不是 `null` 都会进 `SET`。这样一来，用 `new Book()` 做局部更新时，这一列会被清空，用之前想清楚

### selectOne 查到多行会报错

`selectOne` 期望结果最多一行。条件写松了、查出两行以上时会抛异常，异常信息里会说期望一行但查到了几行。它适合用在「按唯一字段查」的地方，比如按 ISBN 查一本书。只想知道有没有，用 `exists`。

## 条件构造器

条件构造器（Wrapper）是用 Java 方法调用来拼 `WHERE` 子句的对象：每调一个方法，就往条件里加一段，最后交给 `selectList`、`delete`、`update` 这些方法去执行。

### 两种写法：字符串列名和 Lambda

```java
// 写法一：QueryWrapper，列名是字符串
QueryWrapper<Book> qw = new QueryWrapper<>();
qw.eq("type", "计算机").like("name", "Java");

// 写法二：LambdaQueryWrapper，列名用 getter 的方法引用
LambdaQueryWrapper<Book> lqw = new LambdaQueryWrapper<>();
lqw.eq(Book::getType, "计算机").like(Book::getName, "Java");

List<Book> books = bookDao.selectList(lqw);
```

两种写法生成的 SQL 一样：`WHERE (type = ? AND name LIKE ?)`，第二个参数是 `%Java%`。区别在于列名写错的时候：

- 字符串写法把 `"type"` 拼错成 `"tpye"`，编译照样通过，**运行到这一句才报 SQL 错**
- Lambda 写法把 `Book::getType` 写错，**编译就不过**；以后有人把字段 `type` 改名成 `category`，IDE 重构时这里会一起改掉，字符串写法则会悄悄留下一个错误的列名

所以平时优先用 Lambda。字符串写法留给 Lambda 表达不了的场合，比如 `count(*)` 这种不是实体字段的表达式（见下文「只查部分列」）。

`QueryWrapper` 也可以调 `.lambda()` 转成 Lambda 版本，效果和直接 `new LambdaQueryWrapper<>()` 一样。

### 常用条件方法

多个条件方法连着调，默认用 `AND` 连接。

| 方法 | SQL | 例子 |
| --- | --- | --- |
| `eq` / `ne` | `=` / `<>` | `eq(Book::getType, "计算机")` |
| `gt` / `ge` | `>` / `>=` | `ge(Book::getId, 10)` |
| `lt` / `le` | `<` / `<=` | `lt(Book::getId, 100)` |
| `between` | `BETWEEN a AND b` | `between(Book::getId, 10, 20)` |
| `like` | `LIKE '%值%'` | `like(Book::getName, "Java")` |
| `likeRight` | `LIKE '值%'` | `likeRight(Book::getName, "Java")`，以 Java 开头 |
| `likeLeft` | `LIKE '%值'` | `likeLeft(Book::getName, "指南")`，以「指南」结尾 |
| `in` | `IN (...)` | `in(Book::getId, 1, 2, 3)` |
| `isNull` / `isNotNull` | `IS NULL` / `IS NOT NULL` | `isNull(Book::getDescription)` |
| `orderByAsc` / `orderByDesc` | `ORDER BY ... ASC/DESC` | `orderByDesc(Book::getId)` |

`like` 的值不用自己加 `%`，它会替你加。`likeRight` 的「Right」指 `%` 在右边，即「以……开头」，这个命名方向和直觉容易反过来，记不住时打开 SQL 日志看一眼。

所有的值都会变成预编译参数 `?`，和 MyBatis 的 `#{}` 一样，不会有 SQL 注入问题。

### 可选条件：第一个参数传 boolean

回到典型场景：书名和类型两个搜索框都可以不填。直接这样写有问题：

```java
lqw.like(Book::getName, name).eq(Book::getType, type);
```

用户没填类型时 `type` 是 `null`，SQL 里会出现 `type = NULL`。在 SQL 里任何值和 `NULL` 比较都不成立，结果**一条都查不出来**。

每个条件方法都有一个重载版本，第一个参数是 `boolean condition`，为 `false` 时这个条件整个不加：

```java
LambdaQueryWrapper<Book> lqw = new LambdaQueryWrapper<>();
lqw.like(StringUtils.hasText(name), Book::getName, name)
   .eq(StringUtils.hasText(type), Book::getType, type);
```

`StringUtils.hasText` 是 Spring 自带的工具方法，字符串为 `null`、空串或只有空白时返回 `false`。现在两个框都不填就查全部，填哪个就按哪个筛选，作用和 XML 动态 SQL 里的 `<if test="name != null">` 一样，只是不用离开 Java 代码。

### OR 和括号

条件之间默认是 `AND`。要用 `OR`，在两个条件之间插一个 `.or()`：

```java
// WHERE (type = ? OR name LIKE ?)
lqw.eq(Book::getType, "计算机").or().like(Book::getName, "Java");
```

**`.or()` 只影响紧挨着它的下一个条件**，后面再接的条件又回到 `AND`。于是下面这句的结果往往和你想的不一样：

```java
// 想要：类型是计算机或小说，并且 id > 10
lqw.eq(Book::getType, "计算机").or().eq(Book::getType, "小说").gt(Book::getId, 10);
// 实际：WHERE (type = ? OR type = ? AND id > ?)
```

SQL 里 `AND` 的优先级比 `OR` 高，这句被理解成「计算机类的全部，加上 id > 10 的小说」。要加括号，用接收 Lambda 的 `and(...)` 或 `or(...)`，传进去的条件会被包在一对括号里：

```java
// WHERE ((type = ? OR type = ?) AND id > ?)
lqw.and(w -> w.eq(Book::getType, "计算机").or().eq(Book::getType, "小说"))
   .gt(Book::getId, 10);
```

这个例子其实用 `in(Book::getType, "计算机", "小说")` 更简单。`and(...)` 嵌套留给 `IN` 表达不了的组合，比如「类型是计算机，或者书名里有 Java」再和别的条件做 `AND`。

### 只查部分列

默认查出实体的全部字段。列表页只要 id 和书名时，用 `select` 指定：

```java
lqw.select(Book::getId, Book::getName);
List<Book> books = bookDao.selectList(lqw);   // 其余字段都是 null
```

要做统计，结果不是实体字段（比如每个类型有几本书），就用字符串写法的 `QueryWrapper`，配合 `selectMaps` 把每一行拿成一个 `Map`：

```java
QueryWrapper<Book> qw = new QueryWrapper<>();
qw.select("type", "count(*) AS cnt").groupBy("type");
List<Map<String, Object>> rows = bookDao.selectMaps(qw);
// 每个 Map 形如 {type=计算机, cnt=3}
```

### 更新构造器

`UpdateWrapper` / `LambdaUpdateWrapper` 除了能写 `WHERE` 条件，还能用 `set` 指定 `SET` 子句。它解决两类 `updateById` 做不了的事。

**一是把字段改成 `NULL`。** `set` 是你显式写的，不受「跳过 null 字段」那条规则影响：

```java
LambdaUpdateWrapper<Book> uw = new LambdaUpdateWrapper<>();
uw.set(Book::getDescription, null).eq(Book::getId, 1);
bookDao.update(uw);   // UPDATE tbl_book SET description=? WHERE (id = ?)，参数为 null
```

**二是按条件批量改**，不用先查出来再一条条 `updateById`：

```java
// 把所有「计算机」类的书改成「计算机科学」
uw.set(Book::getType, "计算机科学").eq(Book::getType, "计算机");
```

需要基于原值计算的更新（比如库存减一），用 `setSql` 直接写一段 `SET` 表达式：`uw.setSql("stock = stock - 1")`。这段字符串会原样拼进 SQL，和 MyBatis 的 `${}` 一样，**不能把用户输入拼进去**。

## 分页

### 配置分页插件

分页插件是一个 MyBatis 拦截器：它拦下你的查询，先发一条 `COUNT` 查询拿到总条数，再在原 SQL 末尾追加数据库对应的分页语法（MySQL 是 `LIMIT`）。要让它生效，必须注册成 bean：

```java
@Configuration
public class MybatisPlusConfig {

    @Bean
    public MybatisPlusInterceptor mybatisPlusInterceptor() {
        MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();
        interceptor.addInnerInterceptor(new PaginationInnerInterceptor(DbType.MYSQL));
        return interceptor;
    }
}
```

- `MybatisPlusInterceptor` 是一个总的拦截器，乐观锁、防全表更新等其他插件也是以 `addInnerInterceptor` 的方式挂在它上面。**挂多个插件时，分页要放在最后**
- 单数据源时指定 `DbType`，它决定生成哪种数据库的分页语法；多数据源、数据库类型不止一种时不填

**这个 bean 很容易漏配**：`selectPage` 照常执行，也不报错，但 SQL 里没有 `LIMIT`，查出来的是全部数据，`getTotal()` 是 0。分页「不生效」时，第一件事是打开 SQL 日志，看有没有那条 `COUNT` 查询。

### 查一页

```java
Page<Book> page = new Page<>(2, 5);            // 第 2 页，每页 5 条，页码从 1 开始
bookDao.selectPage(page, null);

page.getRecords();   // 这一页的 5 条数据
page.getTotal();     // 满足条件的总条数
page.getPages();     // 总页数
```

`selectPage` 把结果填回你传进去的 `page` 对象，同时也把它作为返回值返回，所以写成 `Page<Book> result = bookDao.selectPage(new Page<>(2, 5), null)` 也可以。第 2 页、每页 5 条，偏移量是 5，插件替你算好，不用自己写 `(page - 1) * size`。

### 回到典型场景：条件 + 分页

把可选条件和分页拼起来，就是开头那个需求的全部实现：

```java
public Page<Book> search(String name, String type, int current, int size) {
    LambdaQueryWrapper<Book> lqw = new LambdaQueryWrapper<>();
    lqw.like(StringUtils.hasText(name), Book::getName, name)
       .eq(StringUtils.hasText(type), Book::getType, type)
       .orderByDesc(Book::getId);
    return bookDao.selectPage(new Page<>(current, size), lqw);
}
```

`COUNT` 查询和分页查询带的是同一组条件，所以总数是「搜索结果的总数」，不是全表的总数。

`current`、`size` 通常直接来自前端参数。为了防止有人传一个 `size=100000` 把整张表拖出来，可以在 `PaginationInnerInterceptor` 上设置 `maxLimit`，限制单页条数的上限。

## Service 层：IService

Dao 层有了 `BaseMapper`，Service 层也有一套对应的：接口继承 `IService<Book>`，实现类继承 `ServiceImpl<BookDao, Book>`。

```java
public interface BookService extends IService<Book> {
    Page<Book> search(String name, String type, int current, int size);
}

@Service
public class BookServiceImpl extends ServiceImpl<BookDao, Book> implements BookService {

    @Override
    public Page<Book> search(String name, String type, int current, int size) {
        LambdaQueryWrapper<Book> lqw = new LambdaQueryWrapper<>();
        lqw.like(StringUtils.hasText(name), Book::getName, name)
           .eq(StringUtils.hasText(type), Book::getType, type)
           .orderByDesc(Book::getId);
        // baseMapper 是 ServiceImpl 里的字段，就是注入好的 BookDao
        return baseMapper.selectPage(new Page<>(current, size), lqw);
    }
}
```

`ServiceImpl` 的两个泛型分别是「用哪个 Mapper」和「操作哪个实体」，它会把对应的 Mapper 注入进来，再基于它实现一批现成方法：`save`、`removeById`、`updateById`、`getById`、`list`、`page`，增删改返回 `boolean`（是否成功），不再是行数。

这样 Controller 可以直接调 `bookService.getById(id)`，原来 Service 里那些只是转调一下 Dao 的方法都能删掉。但 **IService 不是必须的**：方法名和 `BaseMapper` 不一样（`save` 对 `insert`、`getById` 对 `selectById`），容易混；Service 里如果全是业务方法，只在 Dao 层用 `BaseMapper` 也完全够用。

## 参考

- [MyBatis-Plus 官方文档](https://baomidou.com/)
- [安装](https://baomidou.com/getting-started/install/)：各 Spring Boot 版本的 starter、`mybatis-plus-jsqlparser`
- [持久层接口](https://baomidou.com/guides/data-interface/)：`BaseMapper` 与 `IService` 的方法
- [条件构造器](https://baomidou.com/guides/wrapper/)
- [注解配置](https://baomidou.com/reference/annotation/)：`@TableName`、`@TableId`、`@TableField`
- [配置](https://baomidou.com/reference/)：`idType`、`tablePrefix`、字段策略等全局配置的默认值
- [分页插件](https://baomidou.com/plugins/pagination/)
