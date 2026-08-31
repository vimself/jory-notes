---
tags: [类型/概念, 技术/MyBatis, 技术/Java]
aliases: [MyBatis 3, Mapper, Mapper 接口, 映射文件, SqlSession, SqlSessionFactory, mybatis-config.xml, resultMap, 参数传递, 半自动 ORM, 持久层框架]
created: 2026-08-31
updated: 2026-08-31
---
> MyBatis 让你只写 SQL 和一个 Java 接口，中间「拼参数、遍历结果集、塞进对象」的那几十行样板代码由它生成——SQL 仍然攥在你自己手里，这是它和全自动 ORM 最大的区别。

## 用原生 JDBC 查一条用户有多啰嗦

查一个用户，业务逻辑其实只有一句 SQL，但 JDBC 要求你这么写：

```java
Connection conn = DriverManager.getConnection(url, user, pwd);
PreparedStatement ps = conn.prepareStatement(
    "select id, user_name, age from tb_user where id = ?");
ps.setInt(1, 5);                          // 手动塞参数，位置不能错
ResultSet rs = ps.executeQuery();
User u = null;
if (rs.next()) {
    u = new User();
    u.setId(rs.getInt("id"));             // 手动一列一列搬
    u.setUserName(rs.getString("user_name"));
    u.setAge(rs.getInt("age"));
}
rs.close(); ps.close(); conn.close();     // 忘一个就漏连接
```

真正属于业务的只有那句 SQL 和 `id = 5`，其余全是仪式。而且这堆代码有三个反复咬人的地方：**参数按位置编号（加一个条件就要重排所有序号）、结果集一列一列手搬（表加一个字段就要改 Java 代码）、连接忘了关就泄漏**。

同一件事用 MyBatis 是这样：

```java
User u = session.getMapper(UserMapper.class).selectById(5);
```

SQL 你照样自己写，只是挪到了别的地方；样板代码消失了。

## 它做的和不做的

MyBatis 常被叫作「半自动 ORM」，这个「半」是关键：

| 这部分它接管 | 这部分仍归你 |
| --- | --- |
| 建连接、关连接 | 写 SQL |
| 把参数安全地塞进 `PreparedStatement` | 决定查哪些字段、怎么 join |
| 把 `ResultSet` 一行行映射成 Java 对象 | 索引、性能 |

全自动 ORM（比如 Hibernate）会替你生成 SQL，你基本看不见它。MyBatis 反过来：**SQL 是你写的，所以复杂查询和调优不会被框架挡住**，代价是你得自己写。

## 跑通第一个查询

分三个文件，走一遍就清楚了。

### 第 1 步：核心配置文件

`mybatis-config.xml` 告诉 MyBatis「连哪个库、事务怎么管、SQL 在哪」：

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE configuration
  PUBLIC "-//mybatis.org//DTD Config 3.0//EN"
  "https://mybatis.org/dtd/mybatis-3-config.dtd">
<configuration>
  <environments default="development">
    <environment id="development">
      <transactionManager type="JDBC"/>
      <dataSource type="POOLED">
        <property name="driver" value="${driver}"/>
        <property name="url" value="${url}"/>
        <property name="username" value="${username}"/>
        <property name="password" value="${password}"/>
      </dataSource>
    </environment>
  </environments>
  <mappers>
    <mapper resource="org/mybatis/example/BlogMapper.xml"/>
  </mappers>
</configuration>
```

几个元素的含义：

- **`<environments>`** 可以配多套环境（开发库、测试库），`default` 指定默认用哪套。想切换就在构建工厂时传环境 id
- **`transactionManager type="JDBC"`** 表示直接用 JDBC 自己的提交/回滚来管事务。另一个可选值是 `MANAGED`，意思是「我什么都不做，交给容器管」——用 Spring 时不用配这个，Spring 会覆盖掉
- **`dataSource type="POOLED"`** 表示用连接池，连接用完还回池里而不是真的关掉
- **`<mappers>`** 列出所有映射文件。**漏登记是初学最常见的报错来源**，现象是运行时抱怨找不到某个 statement

### 第 2 步：映射文件

SQL 写在这里：

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE mapper
  PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
  "https://mybatis.org/dtd/mybatis-3-mapper.dtd">
<mapper namespace="org.mybatis.example.BlogMapper">
  <select id="selectBlog" resultType="Blog">
    select * from Blog where id = #{id}
  </select>
</mapper>
```

**`namespace` + `id` 合起来是这条 SQL 的全限定名**，这里就是 `org.mybatis.example.BlogMapper.selectBlog`。namespace 的作用是防重名：两个映射文件里都有 `selectAll` 也不会撞车。

### 第 3 步：拿到会话并执行

```java
String resource = "org/mybatis/example/mybatis-config.xml";
InputStream inputStream = Resources.getResourceAsStream(resource);
SqlSessionFactory sqlSessionFactory =
  new SqlSessionFactoryBuilder().build(inputStream);
```

`SqlSessionFactory` **建一次就够，全应用共用**——它要解析所有 XML，很重。而 `SqlSession` 代表一次会话，**用完必须关**，所以标准写法是 try-with-resources：

```java
try (SqlSession session = sqlSessionFactory.openSession()) {
  Blog blog = session.selectOne(
    "org.mybatis.example.BlogMapper.selectBlog", 101);
}
```

这样已经能跑了，但注意第一个参数——**SQL 的全限定名是个字符串**。写错了编译器不管你，运行时才炸；改了 XML 里的 id，所有调用处都得手动跟着改。这正是下一节要解决的问题。

## Mapper 接口代理

定义一个接口，让 MyBatis 在运行时生成它的实现：

```java
public interface BlogMapper {
  Blog selectBlog(int id);
}
```

```java
BlogMapper mapper = session.getMapper(BlogMapper.class);
Blog blog = mapper.selectBlog(101);
```

**你从来没写过这个接口的实现类。** `getMapper()` 返回的是 MyBatis 用动态代理现场生成的对象，它拦截你调的每个方法，换算成对应的 SQL 全限定名去执行。所以「代理开发」这个说法指的就是这件事。

好处是字符串消失了：方法名写错编译不过，返回类型不匹配编译不过，IDE 还能跳转和补全。

### 让代理对上号的规则

代理靠**约定**把方法和 SQL 对起来，四条都得满足：

| 要求 | 具体 |
| --- | --- |
| namespace | 必须等于接口的**全限定名**，`org.mybatis.example.BlogMapper` |
| 方法名 | 必须等于 statement 的 `id` |
| 参数 | 方法参数要能对上 SQL 里的占位符 |
| 返回类型 | 要和 `resultType` 对得上；查多条就用 `List<Blog>` |

**最常踩的是第一条**：namespace 写成了 `BlogMapper` 而不是全限定名，或者接口挪了包却忘了改 XML。现象是运行时报找不到 statement，而不是编译错误。

方法名相同的重载在这里也是坑——一个 `id` 只能对一个方法，接口里同名不同参的两个方法会撞车。

## 结果映射

### 列名和属性名一致时

直接用 `resultType`，MyBatis 按名字自动对应：

```xml
<select id="selectBlog" resultType="Blog">
  select id, title from Blog where id = #{id}
</select>
```

### 数据库用下划线、Java 用驼峰

数据库里叫 `user_name`，Java 属性叫 `userName`，自动映射就对不上了，查出来的对象那个字段是 `null`。**这是初学阶段第一个「查到了数据但字段是空的」的元凶。**

一行配置解决，写在核心配置文件里：

```xml
<settings>
  <setting name="mapUnderscoreToCamelCase" value="true"/>
</settings>
```

### 名字完全对不上时

用 `resultMap` 显式声明每一列对应哪个属性：

```xml
<resultMap id="userResultMap" type="User">
  <id property="id" column="user_id" />
  <result property="username" column="user_name"/>
  <result property="password" column="hashed_password"/>
</resultMap>
```

`<id>` 和 `<result>` 的区别：**`<id>` 标记主键**，MyBatis 用它判断两行是不是同一个对象，在处理关联查询时很关键。用了 `resultMap` 之后，select 上写 `resultMap="userResultMap"` 而不是 `resultType`。

## 增删改查

`<insert>`、`<update>`、`<delete>` 的写法和 `<select>` 对称：

```xml
<insert id="insertAuthor">
  insert into Author (username, password, email)
  values (#{username}, #{password}, #{email})
</insert>
```

接口方法的返回值写 `int`，拿到的是**受影响的行数**：

```java
int insertAuthor(Author author);
int updateAuthor(Author author);
int deleteAuthor(int id);
```

### 拿到自增主键

插入之后想知道数据库分配的 id，光靠返回值不行——返回的是行数。要用 `useGeneratedKeys` 和 `keyProperty`：

```xml
<insert id="insertAuthor" useGeneratedKeys="true" keyProperty="id">
  insert into Author (username, password, email, bio)
  values (#{username}, #{password}, #{email}, #{bio})
</insert>
```

**主键是回填到你传进去的那个对象上的**，不是通过返回值给你：

```java
Name name = new Name();
name.setName("Fred");

int rows = mapper.insertName(name);
System.out.println("rows inserted = " + rows);
System.out.println("generated key value = " + name.getId());  // 这里才有 id
```

### 别忘了提交事务

用 `openSession()` 拿到的会话需要你显式提交，否则增删改在数据库里不会生效：

```java
try (SqlSession session = sqlSessionFactory.openSession()) {
  session.getMapper(UserMapper.class).insertUser(user);
  session.commit();
}
```

想让它自动提交，用 `openSession(true)`。**「代码没报错、日志显示执行了、去数据库一查什么都没有」几乎都是漏了 `commit()`。**

## 参数传递

### `#{}` 和 `${}`

这是 MyBatis 里**最该分清的一对**，因为它直接关系到安全。

**`#{}` 会被编译成 JDBC 预编译语句里的 `?` 占位符**，值随后由驱动安全地填进去。SQL 结构和数据是分开传给数据库的，所以用户输入再离谱也变不成 SQL 语句。

**`${}` 是纯字符串拼接**，MyBatis 原样把内容拼进 SQL，不做任何转义。

```xml
<select id="generalSelect" parameterType="map">
  select * from ${table} where col1 = #{criteria}
</select>
```

这里 `${table}` 只能用拼接——**表名不能用 `?` 占位符**，这是 JDBC 预编译的限制，不是 MyBatis 的。同理，`order by ${columnName}` 里的列名也只能拼。

代价是注入风险：如果 `${}` 的内容来自用户输入，别人传一个 `x; drop table users` 进来就直接执行了。官方的态度很明确——**能用 `#{}` 就一定用 `#{}`**，`${}` 只在语法上不允许占位符的位置（表名、列名、排序方向）使用，且内容必须是你自己控制的白名单，绝不能是原始用户输入。

### 多个参数

方法只有一个参数时，`#{}` 里写什么名字都能对上。**一旦有两个参数就不行了**，默认只能用 `param1`、`param2` 这种位置名，可读性很差。

用 `@Param` 给参数起名：

```java
import org.apache.ibatis.annotations.Param;

public interface UserMapper {
   User selectUser(@Param("username") String username,
                   @Param("hashedPassword") String hashedPassword);
}
```

```xml
<select id="selectUser" resultType="User">
  select id, username, hashedPassword
  from some_table
  where username = #{username}
  and hashedPassword = #{hashedPassword}
</select>
```

参数是对象时不用 `@Param`，直接在 `#{}` 里写属性名，MyBatis 会调对应的 getter。参数是 Map 时写 key。

## 注解开发

简单 SQL 可以不写 XML，直接标在接口方法上：

```java
public interface UserMapper {
  @Select("select * from tb_user where id = #{id}")
  User selectById(int id);
}
```

`@Insert`、`@Update`、`@Delete` 同理。用注解时，映射文件就不需要了，但要在核心配置的 `<mappers>` 里改成登记接口类。

**怎么选：**

| 用注解 | 用 XML |
| --- | --- |
| 单表增删改查这种一行能写完的 | SQL 长、需要换行排版的 |
| 想少维护一个文件 | 需要动态 SQL（条件拼接、循环） |
| | 需要 `resultMap` 做复杂映射 |

注解写长 SQL 会变成难以阅读的字符串拼接，动态 SQL 更是几乎没法写。**两者可以在同一个项目里混用**：简单的用注解，复杂的落 XML。

## 参考
- [MyBatis Getting Started](https://mybatis.org/mybatis-3/getting-started.html)
- [Mapper XML Files](https://mybatis.org/mybatis-3/sqlmap-xml.html)
- [Java API](https://mybatis.org/mybatis-3/java-api.html)
- [MyBatis FAQ](https://github.com/mybatis/mybatis-3/wiki/FAQ)
