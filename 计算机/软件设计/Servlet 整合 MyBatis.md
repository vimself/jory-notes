---
tags: [类型/实践, 技术/Servlet, 技术/MyBatis, 技术/Java]
aliases: [Servlet 连接数据库, Servlet 调用 MyBatis]
created: 2026-09-01
updated: 2026-09-03
---
> 把 [[Servlet]] 和 [[MyBatis]] 接起来的一次完整走查：请求从浏览器进 Servlet，经 Mapper 接口换算成 SQL 落到 MySQL，再原路变成页面——每一层只做一件事，Servlet 里不出现 SQL，Mapper 里不出现 `HttpServletRequest`。

## 典型场景

你分别学完了 [[Servlet]] 和 [[MyBatis]]：一个知道怎么接住 HTTP 请求，一个知道怎么把查询结果变成 Java 对象。把它们摆到一起时，问题立刻冒出来——`SqlSessionFactory` 该建在哪？Servlet 是单例多线程的，`SqlSession` 能不能存成成员变量？表单提交完该转发还是重定向？中文为什么存进去就成了问号？

这些问题单看任何一篇都答不了，它们全长在接缝上。

下面用一个能跑通的用户管理功能把接缝走一遍：**浏览器访问 `/user/list` 看到用户列表，填表单提交能新增一条，数据真的进 MySQL。**


## 请求怎么流过这几层

一次「查列表」请求的完整路径：

```text
浏览器  GET /app/user/list
   │
   ▼
Tomcat  解析 HTTP，按 url-pattern 找到 UserListServlet
   │
   ▼
UserListServlet.doGet()          ← 只管 HTTP：读参数、写响应
   │  拿 SqlSession，getMapper(UserMapper.class)
   ▼
UserMapper.selectAll()           ← 接口，没有实现类
   │  MyBatis 动态代理换算成 SQL 全限定名
   ▼
UserMapper.xml 里的 <select>     ← 只管 SQL
   │
   ▼
MySQL   select id, user_name, age from tb_user
   │
   ▼
MyBatis 把 ResultSet 映射成 List<User>
   │
   ▼
UserListServlet  遍历 list 写 HTML
   │
   ▼
浏览器  HTTP/1.1 200 OK + 用户表格
```

**分层的意义在于每层只有一个理由被修改**：换页面样式只动 Servlet，调 SQL 只动 XML，两边互不影响。Servlet 里不出现一句 SQL，Mapper 里不出现一个 `HttpServletRequest`。

这个案例只有两层，业务规则直接写在 Servlet 里；把中间的业务逻辑层补出来的做法见 [[三层架构]]。

MyBatis 那一侧的配置语法、`#{}` 和 `${}`、`resultMap` 这些见 [[MyBatis]]，这里只讲怎么和 Servlet 接上。

## 建表

```sql
create table tb_user (
    id        int primary key auto_increment,
    user_name varchar(50) not null,
    age       int
);

insert into tb_user (user_name, age) values ('张三', 18), ('李四', 22);
```

## 目录结构

```text
user-demo/
├── pom.xml
└── src/main/
    ├── java/com/example/
    │   ├── pojo/User.java
    │   ├── mapper/UserMapper.java
    │   ├── util/MyBatisUtil.java
    │   └── web/
    │       ├── UserListServlet.java
    │       └── UserAddServlet.java
    ├── resources/
    │   ├── mybatis-config.xml
    │   └── com/example/mapper/UserMapper.xml
    └── webapp/
        └── add.html
```

**`UserMapper.xml` 的路径要和接口的包名对上**（`com/example/mapper/`），这是 MyBatis 找映射文件的约定，放错了运行时报找不到 statement。

## pom.xml

三个依赖就够：

```xml
<packaging>war</packaging>

<dependencies>
  <dependency>
    <groupId>jakarta.servlet</groupId>
    <artifactId>jakarta.servlet-api</artifactId>
    <version>在 Maven Central 上查到的版本号</version>
    <scope>provided</scope>          <!-- 容器自带，别打进 war -->
  </dependency>
  <dependency>
    <groupId>org.mybatis</groupId>
    <artifactId>mybatis</artifactId>
    <version>在 Maven Central 上查到的版本号</version>
  </dependency>
  <dependency>
    <groupId>com.mysql</groupId>
    <artifactId>mysql-connector-j</artifactId>
    <version>在 Maven Central 上查到的版本号</version>
    <scope>runtime</scope>           <!-- 代码里从不 import 它 -->
  </dependency>
</dependencies>
```

两个 scope 都不是随手写的，理由见 [[Maven]]：Servlet API 是 `provided` 因为 [[Tomcat]] 自己带了一份，重复会冲突；JDBC 驱动是 `runtime` 因为你的代码只写 `java.sql` 的接口，编译期根本不需要它。

## 实体类

```java
package com.example.pojo;

public class User {
    private Integer id;
    private String userName;
    private Integer age;

    // getter / setter 省略，MyBatis 靠它们塞值
}
```

数据库列名是 `user_name`，Java 属性是 `userName`，靠配置里的 `mapUnderscoreToCamelCase` 自动对上。

## Mapper 接口和映射文件

```java
package com.example.mapper;

import com.example.pojo.User;
import java.util.List;

public interface UserMapper {
    List<User> selectAll();
    int insert(User user);
}
```

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE mapper
  PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
  "https://mybatis.org/dtd/mybatis-3-mapper.dtd">
<mapper namespace="com.example.mapper.UserMapper">

  <select id="selectAll" resultType="com.example.pojo.User">
    select id, user_name, age from tb_user
  </select>

  <insert id="insert">
    insert into tb_user (user_name, age) values (#{userName}, #{age})
  </insert>

</mapper>
```

`namespace` 必须是接口的全限定名，`id` 必须等于方法名——这两条对不上就是运行时报找不到 statement。

## 核心配置

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE configuration
  PUBLIC "-//mybatis.org//DTD Config 3.0//EN"
  "https://mybatis.org/dtd/mybatis-3-config.dtd">
<configuration>
  <settings>
    <setting name="mapUnderscoreToCamelCase" value="true"/>
  </settings>

  <environments default="dev">
    <environment id="dev">
      <transactionManager type="JDBC"/>
      <dataSource type="POOLED">
        <property name="driver" value="com.mysql.cj.jdbc.Driver"/>
        <property name="url" value="jdbc:mysql://localhost:3306/demo?useUnicode=true&amp;characterEncoding=utf8"/>
        <property name="username" value="你的用户名"/>
        <property name="password" value="你的密码"/>
      </dataSource>
    </environment>
  </environments>

  <mappers>
    <mapper resource="com/example/mapper/UserMapper.xml"/>
  </mappers>
</configuration>
```

XML 里 `&` 必须写成 `&amp;`，所以连接串上那两个参数之间是 `&amp;` 而不是 `&`——直接粘贴一个裸 `&` 进去，启动时会报 XML 解析错误。

## 工具类：工厂只建一次

```java
package com.example.util;

import org.apache.ibatis.io.Resources;
import org.apache.ibatis.session.SqlSession;
import org.apache.ibatis.session.SqlSessionFactory;
import org.apache.ibatis.session.SqlSessionFactoryBuilder;

import java.io.IOException;
import java.io.InputStream;

public class MyBatisUtil {

    private static final SqlSessionFactory FACTORY;

    static {
        try (InputStream in = Resources.getResourceAsStream("mybatis-config.xml")) {
            FACTORY = new SqlSessionFactoryBuilder().build(in);
        } catch (IOException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    public static SqlSession openSession() {
        return FACTORY.openSession();
    }
}
```

**这个静态字段直接呼应 [[Servlet]] 的单例模型：** Servlet 全站只有一个实例、多线程并发进 `doGet`，所以每个请求绝不能各建一个 `SqlSessionFactory`（它要解析全部 XML，很重）。工厂做成静态的建一次，而 `SqlSession` **每个请求单独开、用完立刻关**——它不是线程安全的，绝不能存成 Servlet 的成员变量。

## 查列表的 Servlet

```java
package com.example.web;

import com.example.mapper.UserMapper;
import com.example.pojo.User;
import com.example.util.MyBatisUtil;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.*;
import org.apache.ibatis.session.SqlSession;

import java.io.IOException;
import java.io.PrintWriter;
import java.util.List;

@WebServlet("/user/list")
public class UserListServlet extends HttpServlet {

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
            throws IOException {

        List<User> users;
        try (SqlSession session = MyBatisUtil.openSession()) {   // 用完自动关
            users = session.getMapper(UserMapper.class).selectAll();
        }

        resp.setContentType("text/html;charset=UTF-8");          // 必须在 getWriter 之前
        PrintWriter out = resp.getWriter();
        out.write("<h2>用户列表</h2><table border='1'>");
        out.write("<tr><th>id</th><th>姓名</th><th>年龄</th></tr>");
        for (User u : users) {
            out.write("<tr><td>" + u.getId() + "</td><td>"
                    + u.getUserName() + "</td><td>" + u.getAge() + "</td></tr>");
        }
        out.write("</table><a href='" + req.getContextPath() + "/add.html'>新增</a>");
    }
}
```

链接里用 `req.getContextPath()` 拼前缀，不要写死 `/user-demo/`。**上下文路径是部署时才确定的**，写死了换个部署路径全站链接失效。

## 新增的 Servlet

```java
package com.example.web;

import com.example.mapper.UserMapper;
import com.example.pojo.User;
import com.example.util.MyBatisUtil;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.*;
import org.apache.ibatis.session.SqlSession;

import java.io.IOException;

@WebServlet("/user/add")
public class UserAddServlet extends HttpServlet {

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp)
            throws IOException {

        req.setCharacterEncoding("UTF-8");           // 必须在读参数之前

        User user = new User();
        user.setUserName(req.getParameter("userName"));
        user.setAge(Integer.valueOf(req.getParameter("age")));

        try (SqlSession session = MyBatisUtil.openSession()) {
            session.getMapper(UserMapper.class).insert(user);
            session.commit();                        // 不提交等于没写
        }

        resp.sendRedirect(req.getContextPath() + "/user/list");   // POST-重定向-GET
    }
}
```

这里三行注释各对应前面一个坑：

- `setCharacterEncoding` 写在 `getParameter` **之前**，否则中文名字存进去是乱码，而且不报错
- MyBatis 的 `openSession()` 不自动提交，漏了 `commit()` 的现象是「日志显示执行了、去数据库一查什么都没有」
- 结尾用**重定向**不是转发：写操作完成后让浏览器换个地址重新发 `GET`，这样用户刷新页面时刷的是列表页，不会重复提交表单再插一条

## 表单页

`src/main/webapp/add.html`：

```html
<!doctype html>
<html>
<head><meta charset="UTF-8"><title>新增用户</title></head>
<body>
  <form action="/user-demo/user/add" method="post">
    姓名：<input name="userName"><br>
    年龄：<input name="age"><br>
    <button type="submit">提交</button>
  </form>
</body>
</html>
```

`method="post"` 决定了请求进 `doPost`。**把它改成 `get` 或者删掉，提交后就是 405**——因为 `UserAddServlet` 只重写了 `doPost`。`action` 里的 `/user-demo` 是上下文路径，要和你实际部署的对上。

## 跑起来

代码用的是 `jakarta.servlet`，所以容器必须是 **Tomcat 10 或更高**，`tomcat7-maven-plugin` 跑不了这套包名，原因见 [[Tomcat]]。装一个 Tomcat 10+：

```bash
mvn clean package
```

把 `target/` 下的 war 丢进 Tomcat 的 `webapps/`，启动后访问 `http://localhost:8080/user-demo/user/list`。

## 这个案例踩到的坑

| 现象 | 原因 | 对应章节 |
| --- | --- | --- |
| 表单提交报 405 | 表单是 `post`，Servlet 只写了 `doGet` | [[Servlet]] · service 与 doGet/doPost |
| 页面中文是问号 | `setContentType` 漏了 `charset`，或写在 `getWriter` 之后 | [[Servlet]] · HttpServletResponse |
| 存进库的中文是乱码 | `setCharacterEncoding` 写在 `getParameter` 之后 | [[Servlet]] · HttpServletRequest |
| 代码跑完数据库没数据 | 漏了 `session.commit()` | [[MyBatis]] |
| 查出来 `userName` 是 null | 列名 `user_name` 没开驼峰映射 | [[MyBatis]] |
| 运行时报找不到 statement | `namespace` 不是接口全限定名，或映射文件没登记 | [[MyBatis]] |
| 换个部署路径全站链接 404 | 链接写死了上下文路径 | [[Servlet]] · HttpServletRequest |
| 启动报 XML 解析错误 | 连接串里的 `&` 没写成 `&amp;` | 本篇 |
## 参考
- [MyBatis Getting Started](https://mybatis.org/mybatis-3/getting-started.html)
- [Jakarta Servlet Specification](https://jakarta.ee/specifications/servlet/)
