---
tags: [类型/实践, 技术/Spring, 技术/MyBatis, 技术/Java, 技术/Maven]
aliases: [SSM, SSM 框架整合]
created: 2026-10-03
updated: 2026-10-03
---
> SSM 整合就是把 [[Spring MVC]]、[[Spring Framework]]、[[MyBatis]] 装进同一个 Web 工程：两个 Spring 容器按层分工，MyBatis 交给根容器托管。整合跑通只是第一步，要交付给前端还得补两件事：所有接口返回同一种格式（统一响应结果），所有异常在表现层集中处理（统一异常处理）。

## 典型场景

三个框架分开都会用了：[[Spring 整合 MyBatis]] 能在单元测试里查出数据，[[Spring MVC]] 能返回一个写死的 JSON。现在要做一个图书管理的增删改查接口给前端用，马上碰到三个问题：

1. **配置放哪**。数据源、`SqlSessionFactory`、事务管理器、Controller 扫描、JSON 转换，五六个配置类，哪个归根容器、哪个归 MVC 容器
2. **前端没法统一处理返回值**。新增返回 `true`，查询返回一个对象或者 `null`，查全部返回数组。前端每个接口都要写不同的判断，而且 `null` 到底是「没查到」还是「出错了」分不清
3. **一出错，前端收到一整页 HTML**。数据库连不上时，Tomcat 返回一个带完整 Java 堆栈的 500 错误页。前端拿到的不是 JSON，解析直接失败；堆栈里的类名、SQL 也暴露给了用户

## 整合思路：谁装进哪个容器

[[Spring MVC]] 那篇讲过父子容器，SSM 整合就是按那张分工表填空：

```text
Tomcat 启动
  │
  ▼
ServletContainerInitConfig（初始化类）
  │
  ├─ getRootConfigClasses ──▶ 根容器
  │                            SpringConfig
  │                              ├─ 扫描 service 包
  │                              ├─ 开启事务注解
  │                              └─ @Import
  │                                   ├─ JdbcConfig    → DataSource、事务管理器
  │                                   └─ MyBatisConfig → SqlSessionFactory、Mapper 扫描
  │
  └─ getServletConfigClasses ──▶ MVC 容器（子容器）
                                  SpringMvcConfig
                                    ├─ 扫描 controller 包
                                    ├─ @EnableWebMvc
                                    └─ 静态资源放行
```

一句话：**数据访问和业务的东西归根容器，Web 的东西归 MVC 容器**。扫描范围不能交叠，否则会出现 Controller 404、`@Transactional` 静默失效这类问题，原因见 [[Spring MVC]] 的父子容器一节。

## 工程结构

```text
ssm-demo
├── pom.xml                                  packaging 为 war
└── src
    ├── main
    │   ├── java/com/example
    │   │   ├── config
    │   │   │   ├── ServletContainerInitConfig.java
    │   │   │   ├── SpringConfig.java
    │   │   │   ├── JdbcConfig.java
    │   │   │   ├── MyBatisConfig.java
    │   │   │   └── SpringMvcConfig.java
    │   │   ├── controller
    │   │   │   ├── BookController.java
    │   │   │   ├── Result.java              统一响应结果
    │   │   │   ├── Code.java                状态码常量
    │   │   │   └── ProjectExceptionAdvice.java  统一异常处理
    │   │   ├── dao/BookDao.java
    │   │   ├── domain/Book.java
    │   │   ├── exception
    │   │   │   ├── BusinessException.java
    │   │   │   └── SystemException.java
    │   │   └── service
    │   │       ├── BookService.java
    │   │       └── impl/BookServiceImpl.java
    │   ├── resources/jdbc.properties
    │   └── webapp/                          静态页面、js、css
    └── test/java/com/example/service/BookServiceTest.java
```

`Result`、`Code`、异常处理器放在 `controller` 包下，是因为它们都属于表现层，而且这样它们会被 MVC 容器的扫描范围覆盖。

## 依赖

```xml
<packaging>war</packaging>

<dependencies>
    <!-- Spring MVC（会传递引入 spring-context、spring-web） -->
    <dependency>
        <groupId>org.springframework</groupId>
        <artifactId>spring-webmvc</artifactId>
        <version>${spring.version}</version>
    </dependency>
    <!-- Spring JDBC：DataSourceTransactionManager 在这里 -->
    <dependency>
        <groupId>org.springframework</groupId>
        <artifactId>spring-jdbc</artifactId>
        <version>${spring.version}</version>
    </dependency>
    <dependency>
        <groupId>org.springframework</groupId>
        <artifactId>spring-test</artifactId>
        <version>${spring.version}</version>
        <scope>test</scope>
    </dependency>

    <!-- MyBatis 本体 + 和 Spring 的胶水包 -->
    <dependency>
        <groupId>org.mybatis</groupId>
        <artifactId>mybatis</artifactId>
        <version>${mybatis.version}</version>
    </dependency>
    <dependency>
        <groupId>org.mybatis</groupId>
        <artifactId>mybatis-spring</artifactId>
        <version>${mybatis-spring.version}</version>
    </dependency>

    <!-- 数据库驱动 + 连接池 -->
    <dependency>
        <groupId>com.mysql</groupId>
        <artifactId>mysql-connector-j</artifactId>
        <version>${mysql.version}</version>
    </dependency>
    <dependency>
        <groupId>com.alibaba</groupId>
        <artifactId>druid</artifactId>
        <version>${druid.version}</version>
    </dependency>

    <!-- JSON：Spring Framework 7 默认使用 Jackson 3 -->
    <dependency>
        <groupId>tools.jackson.core</groupId>
        <artifactId>jackson-databind</artifactId>
        <version>${jackson.version}</version>
    </dependency>

    <!-- Servlet API：Tomcat 自带，只在编译时用 -->
    <dependency>
        <groupId>jakarta.servlet</groupId>
        <artifactId>jakarta.servlet-api</artifactId>
        <version>${servlet.version}</version>
        <scope>provided</scope>
    </dependency>

    <dependency>
        <groupId>org.junit.jupiter</groupId>
        <artifactId>junit-jupiter</artifactId>
        <version>${junit.version}</version>
        <scope>test</scope>
    </dependency>
</dependencies>
```

版本统一放在 `<properties>` 里管理（写法见 [[Maven]]）。几组版本之间有硬性对应关系，选版本时要对着官网查，不要混搭：

- **Spring 和 Tomcat**：Spring Framework 7.0 以 Servlet 6.1 为基线，要求 Tomcat 11 及以上
- **mybatis-spring 和 Spring、MyBatis**：胶水包有自己的兼容矩阵，见 [[Spring 整合 MyBatis]]
- **Jackson**：Spring 7 优先找 Jackson 3（groupId 是 `tools.jackson.core`），Jackson 2（`com.fasterxml.jackson.core`）只作为后备，已标记弃用

## 配置类：逐个写

### jdbc.properties

```properties
jdbc.driver=com.mysql.cj.jdbc.Driver
jdbc.url=jdbc:mysql://localhost:3306/ssm_db
jdbc.username=root
jdbc.password=root
```

### JdbcConfig：数据源和事务管理器

```java
public class JdbcConfig {

    @Value("${jdbc.driver}")
    private String driver;
    @Value("${jdbc.url}")
    private String url;
    @Value("${jdbc.username}")
    private String username;
    @Value("${jdbc.password}")
    private String password;

    @Bean
    public DataSource dataSource() {
        DruidDataSource ds = new DruidDataSource();
        ds.setDriverClassName(driver);
        ds.setUrl(url);
        ds.setUsername(username);
        ds.setPassword(password);
        return ds;
    }

    @Bean
    public PlatformTransactionManager transactionManager(DataSource dataSource) {
        return new DataSourceTransactionManager(dataSource);
    }
}
```

这个类没有加 `@Configuration`，它由 `SpringConfig` 通过 `@Import` 引入，效果一样。`@Value("${...}")` 读取的是 `SpringConfig` 上 `@PropertySource` 加载的属性文件。第三方类用 `@Bean` 进容器的写法见 [[Spring IoC 与 DI]]。

事务管理器的参数直接注入 `dataSource`，保证它和 MyBatis 用的是**同一个数据源**。两边各用一个数据源时 `@Transactional` 不生效，而且不报任何错，原因见 [[Spring 整合 MyBatis]]。

### MyBatisConfig：SqlSessionFactory

```java
public class MyBatisConfig {

    @Bean
    public SqlSessionFactory sqlSessionFactory(DataSource dataSource) throws Exception {
        SqlSessionFactoryBean factoryBean = new SqlSessionFactoryBean();
        factoryBean.setDataSource(dataSource);
        factoryBean.setTypeAliasesPackage("com.example.domain");
        return factoryBean.getObject();
    }
}
```

Mapper 接口的扫描用 `@MapperScan`，写在下面的 `SpringConfig` 上。这两样东西的原理（`FactoryBean`、Mapper 代理）都在 [[Spring 整合 MyBatis]] 里，这里只用结论。

### SpringConfig：根容器入口

```java
@Configuration
@ComponentScan("com.example.service")
@PropertySource("classpath:jdbc.properties")
@Import({JdbcConfig.class, MyBatisConfig.class})
@MapperScan("com.example.dao")
@EnableTransactionManagement
public class SpringConfig {
}
```

逐行看：只扫 `service` 包（Controller 不归这里管）；加载数据库配置文件；引入两个子配置；扫描 Mapper 接口；开启 `@Transactional` 注解支持（见 [[Spring 事务管理]]）。

### SpringMvcConfig：MVC 容器入口

```java
@Configuration
@ComponentScan("com.example.controller")
@EnableWebMvc
public class SpringMvcConfig implements WebMvcConfigurer {

    @Override
    public void configureDefaultServletHandling(DefaultServletHandlerConfigurer configurer) {
        configurer.enable();
    }
}
```

`configureDefaultServletHandling` 解决的是静态资源 404 的问题，下一节单独讲。

### ServletContainerInitConfig：替代 web.xml

```java
public class ServletContainerInitConfig extends AbstractAnnotationConfigDispatcherServletInitializer {

    @Override
    protected Class<?>[] getRootConfigClasses() {
        return new Class<?>[]{SpringConfig.class};
    }

    @Override
    protected Class<?>[] getServletConfigClasses() {
        return new Class<?>[]{SpringMvcConfig.class};
    }

    @Override
    protected String[] getServletMappings() {
        return new String[]{"/"};
    }

    @Override
    protected Filter[] getServletFilters() {
        CharacterEncodingFilter filter = new CharacterEncodingFilter();
        filter.setEncoding("UTF-8");
        return new Filter[]{filter};
    }
}
```

这个类怎么一步步从 `web.xml` 简化而来，见 [[Spring MVC]]。

## 静态资源放行

`DispatcherServlet` 映射在 `/`，等于顶替了 Tomcat 的默认 Servlet。默认 Servlet 原本负责返回 `webapp` 下的 `.html`、`.js`、`.css`，现在这些请求全部进了 `DispatcherServlet`。它到映射表里找 `/pages/books.html`，找不到就 404。

两种放行方式：

**方式一：转交回容器的默认 Servlet**（上面配置里用的就是这个）

```java
@Override
public void configureDefaultServletHandling(DefaultServletHandlerConfigurer configurer) {
    configurer.enable();
}
```

它注册了一个映射到 `/**`、**优先级最低**的处理器：所有 Controller 都认领不了的请求，最后转发给 Tomcat 的默认 Servlet 处理。优先级必须是最低，否则它会抢走本该由 Controller 处理的请求。

**方式二：自己指定资源目录**

```java
@Override
public void addResourceHandlers(ResourceHandlerRegistry registry) {
    registry.addResourceHandler("/pages/**").addResourceLocations("/pages/");
    registry.addResourceHandler("/js/**").addResourceLocations("/js/");
    registry.addResourceHandler("/css/**").addResourceLocations("/css/");
}
```

由 Spring MVC 自己读文件返回，可以按路径精确控制，还能顺带设置缓存头。方式一省事，方式二可控，二选一即可。

## 各层代码

### 表和实体

```sql
CREATE TABLE tbl_book (
    id          INT PRIMARY KEY AUTO_INCREMENT,
    type        VARCHAR(20),
    name        VARCHAR(50),
    description VARCHAR(255)
);
```

```java
public class Book {
    private Integer id;
    private String type;
    private String name;
    private String description;
    // getter / setter / toString 省略
}
```

### Dao：Mapper 接口

```java
public interface BookDao {

    @Insert("INSERT INTO tbl_book (type, name, description) VALUES (#{type}, #{name}, #{description})")
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

增删改的返回值 `int` 是受影响的行数。SQL 简单时用注解，复杂时换成 XML 映射文件，两种写法见 [[MyBatis]]。

### Service：业务层

```java
public interface BookService {
    boolean save(Book book);
    boolean update(Book book);
    boolean delete(Integer id);
    Book getById(Integer id);
    List<Book> getAll();
}
```

```java
@Service
@Transactional
public class BookServiceImpl implements BookService {

    private final BookDao bookDao;

    public BookServiceImpl(BookDao bookDao) {
        this.bookDao = bookDao;
    }

    public boolean save(Book book) {
        return bookDao.save(book) > 0;
    }

    public boolean update(Book book) {
        return bookDao.update(book) > 0;
    }

    public boolean delete(Integer id) {
        return bookDao.delete(id) > 0;
    }

    public Book getById(Integer id) {
        return bookDao.getById(id);
    }

    public List<Book> getAll() {
        return bookDao.getAll();
    }
}
```

`@Transactional` 打在类上，所有公共方法都带事务。Service 把「影响行数」翻译成 `boolean`，表现层不需要知道数据库的细节。

### 先测 Service，再写 Controller

Controller 一跑起来就要启动 Tomcat，出了问题很难分清是 Web 层还是数据层。所以先用 `spring-test` 单独测根容器：

```java
@SpringJUnitConfig(SpringConfig.class)
class BookServiceTest {

    @Autowired
    private BookService bookService;

    @Test
    void getById() {
        System.out.println(bookService.getById(1));
    }

    @Test
    void getAll() {
        System.out.println(bookService.getAll());
    }
}
```

`@SpringJUnitConfig` 把 Spring 的扩展注册到 JUnit 5，并用指定的配置类创建容器，测试类里就能直接注入 bean。这一步只加载 `SpringConfig`，不涉及任何 Web 组件。它通过了，说明数据源、MyBatis、Mapper 扫描、事务这一半没问题，后面再出错就只需要查 Web 层。

### Controller：表现层

```java
@RestController
@RequestMapping("/books")
public class BookController {

    private final BookService bookService;

    public BookController(BookService bookService) {
        this.bookService = bookService;
    }

    @PostMapping
    public boolean save(@RequestBody Book book) {
        return bookService.save(book);
    }

    @PutMapping
    public boolean update(@RequestBody Book book) {
        return bookService.update(book);
    }

    @DeleteMapping("/{id}")
    public boolean delete(@PathVariable Integer id) {
        return bookService.delete(id);
    }

    @GetMapping("/{id}")
    public Book getById(@PathVariable Integer id) {
        return bookService.getById(id);
    }

    @GetMapping
    public List<Book> getAll() {
        return bookService.getAll();
    }
}
```

REST 风格的写法见 [[Spring MVC]]。部署到 Tomcat 后试一下：

```bash
curl http://localhost:8080/ssm/books/1
```

```text
{"id":1,"type":"计算机","name":"Spring 实战","description":"Spring 入门经典"}
```

```bash
curl -X DELETE http://localhost:8080/ssm/books/1
```

```text
true
```

到这里工程就跑通了。下面处理开头的第 2、3 个问题。

## 表现层与前端的数据协议：统一响应结果

### 问题：五个接口，四种返回格式

把上面五个接口的返回值放在一起：

```text
POST   /books      → true
PUT    /books      → true
DELETE /books/1    → true
GET    /books/1    → {"id":1,"type":"计算机",...}     查不到时是空响应
GET    /books      → [{"id":1,...},{"id":2,...}]
```

前端处理每个接口都要换一种写法：有的判断布尔值，有的判断对象是否为空，有的判断数组长度。更麻烦的是**信息不够**：

- `getById` 返回空，前端不知道是「没有这本书」还是「服务器出错了」
- `save` 返回 `false`，前端只能显示一句「失败」，给不出原因

### 做法：所有接口都返回同一个结构

前后端约定一个固定的外壳，真正的数据放在里面：

```json
{
  "code": 20000,
  "data": {"id": 1, "type": "计算机", "name": "Spring 实战"},
  "msg": null
}
```

三个字段各管一件事：

| 字段 | 含义 | 谁用 |
| --- | --- | --- |
| `code` | 这次操作的结果：成功、业务失败、系统异常 | 前端用来判断走哪个分支 |
| `data` | 真正的数据：对象、数组、布尔值，都可以 | 成功时用来渲染页面 |
| `msg` | 给用户看的提示信息 | 失败时直接弹出来 |

这个结构在业界没有统一标准，字段名叫 `code/data/msg` 还是 `status/result/message`、成功码用 `0` 还是 `200` 还是 `20000`，都是**团队内部约定**。重要的是全项目统一，写进接口文档。

### Result 类

```java
public class Result {

    private Integer code;
    private Object data;
    private String msg;

    public Result() {
    }

    public Result(Integer code, Object data) {
        this.code = code;
        this.data = data;
    }

    public Result(Integer code, Object data, String msg) {
        this.code = code;
        this.data = data;
        this.msg = msg;
    }

    // getter / setter 省略
}
```

一定要有 getter：Jackson 序列化时靠 getter 读字段，只有私有字段、没有 getter 的话，`code` 和 `msg` 不会出现在 JSON 里（Jackson 对 POJO 的要求见 [[JSON]]）。

### 状态码常量

```java
public class Code {
    public static final Integer SUCCESS        = 20000;   // 操作成功
    public static final Integer FAIL           = 20001;   // 操作执行了但没成功，比如删除的 id 不存在

    public static final Integer BUSINESS_ERR   = 40000;   // 业务异常：用户的操作不合规
    public static final Integer SYSTEM_ERR     = 50000;   // 系统异常：数据库连不上、超时
    public static final Integer UNKNOWN_ERR    = 59999;   // 未预料到的异常
}
```

这是本篇采用的一种约定，按「结果类别」分段：`2xxxx` 表示请求被正常处理了，`4xxxx` 表示用户这边的问题，`5xxxx` 表示服务器这边的问题，分段方式借鉴了 [[HTTP]] 状态码的分类。常量写在一个类里，前后端对照着同一份表，不要在代码里直接写魔法数字。

### Controller 改造

```java
@RestController
@RequestMapping("/books")
public class BookController {

    private final BookService bookService;

    public BookController(BookService bookService) {
        this.bookService = bookService;
    }

    @PostMapping
    public Result save(@RequestBody Book book) {
        boolean ok = bookService.save(book);
        return new Result(ok ? Code.SUCCESS : Code.FAIL, ok);
    }

    @PutMapping
    public Result update(@RequestBody Book book) {
        boolean ok = bookService.update(book);
        return new Result(ok ? Code.SUCCESS : Code.FAIL, ok);
    }

    @DeleteMapping("/{id}")
    public Result delete(@PathVariable Integer id) {
        boolean ok = bookService.delete(id);
        return new Result(ok ? Code.SUCCESS : Code.FAIL, ok);
    }

    @GetMapping("/{id}")
    public Result getById(@PathVariable Integer id) {
        Book book = bookService.getById(id);
        Integer code = book != null ? Code.SUCCESS : Code.FAIL;
        String msg = book != null ? "" : "数据查询失败，请重试";
        return new Result(code, book, msg);
    }

    @GetMapping
    public Result getAll() {
        List<Book> books = bookService.getAll();
        return new Result(Code.SUCCESS, books);
    }
}
```

现在所有接口的响应都是同一个形状：

```bash
curl http://localhost:8080/ssm/books/999
```

```text
{"code":20001,"data":null,"msg":"数据查询失败，请重试"}
```

### 前端怎么用

前端可以在一个地方统一判断，不用每个接口单独处理（[[AJAX]] 里讲过 Axios 的基本用法）：

```javascript
axios.get("/ssm/books/1").then(res => {
    const result = res.data;
    if (result.code === 20000) {
        this.book = result.data;          // 成功：取数据渲染
    } else {
        this.$message.error(result.msg);  // 失败：直接把后端给的提示弹出来
    }
});
```

`msg` 由后端决定，前端只负责显示，提示文案改了也不用改前端代码。

### HTTP 状态码和业务码的关系

HTTP 本身有状态码，JSON 里仍要放 `code`，因为两层状态码表达的东西不一样。HTTP 状态码描述**这一次 HTTP 交互**：`404` 是路径不存在，`405` 是方法不对，网关、浏览器、监控系统都看得懂它。`code` 描述**业务结果**：「图书名称重复」「库存不足」这种业务层面的失败，HTTP 层面可能完全正常。

常见的两种做法：

- **HTTP 一律 200，结果全看 `code`**：前端处理最简单，所有响应都走 `then`。代价是监控系统看所有请求都是 200，统计不出错误率
- **HTTP 状态码表达大类，`code` 表达细节**：业务失败返回 400 系列、系统异常返回 500，`code` 再细分原因。语义更准确，前端需要在 `catch` 分支里也解析一次响应体

本篇示例用第一种，因为前端处理最简单。项目里选哪种都可以，前后端约定一致就行。

## 统一异常处理

### 问题：异常会从各层冒出来

统一响应结果解决了「正常返回」的格式问题，异常却还不受控制。各层都可能抛异常：

| 来源 | 举例 |
| --- | --- |
| 框架内部 | 前端传的 JSON 格式错误，Jackson 解析失败 |
| 数据层 | 数据库连不上、SQL 写错、唯一键冲突 |
| 业务层 | 业务规则不满足，比如借书时库存为 0 |
| 表现层 | 参数校验不通过 |
| 工具类 | 空指针、除零、数组越界 |

异常一路抛到 `DispatcherServlet` 也没人处理时，会交给 Tomcat，前端收到的就是那页带堆栈的 HTML。

### 原始写法：每个方法里 try-catch

```java
@GetMapping("/{id}")
public Result getById(@PathVariable Integer id) {
    try {
        Book book = bookService.getById(id);
        return new Result(Code.SUCCESS, book);
    } catch (Exception e) {
        return new Result(Code.SYSTEM_ERR, null, "系统繁忙，请稍后再试");
    }
}
```

问题和 [[Servlet 过滤器]] 开头那个场景一样：同一段代码复制到每个方法里，代码量翻倍；新加的接口忘了写，那个接口就退回到返回 HTML 错误页的状态。

正确的方向是：**各层不处理异常，全部往上抛，抛到表现层后统一处理**。异常处理和请求的编码设置、登录检查一样，是横切所有接口的公共逻辑（「横切」的概念见 [[Spring AOP]]）。

### 工程写法：@RestControllerAdvice + @ExceptionHandler

```java
@RestControllerAdvice
public class ProjectExceptionAdvice {

    @ExceptionHandler(Exception.class)
    public Result doException(Exception ex) {
        return new Result(Code.UNKNOWN_ERR, null, "系统繁忙，请稍后再试");
    }
}
```

两个注解：

- **`@RestControllerAdvice`**：`@ControllerAdvice` + `@ResponseBody`。`@ControllerAdvice` 标记的类里定义的 `@ExceptionHandler` 方法，**默认对所有 Controller 生效**；加上 `@ResponseBody` 后，处理方法的返回值和普通接口一样转成 JSON
- **`@ExceptionHandler(Exception.class)`**：这个方法处理哪种异常。参数里声明异常类型，就能拿到异常对象

现在 Controller 里一行 try-catch 都不用写，任何异常都会变成：

```text
{"code":59999,"data":null,"msg":"系统繁忙，请稍后再试"}
```

它在原理上是 [[Spring MVC]] 处理流程的最后一环：请求处理过程中抛出的异常，交给 `HandlerExceptionResolver`，其中负责 `@ExceptionHandler` 的那个解析器会找到这里的方法来处理。

想缩小生效范围，可以在注解上指定包或类型，比如 `@RestControllerAdvice("com.example.controller")` 只管这个包下的 Controller。

### 异常分类：不同的异常，不同的处理

只有一个兜底方法时，所有错误对用户都显示「系统繁忙」。但「图书名称不能为空」这种错误应该原样告诉用户，「数据库连不上」则不该让用户看到细节，同时要通知开发人员。所以要先给异常分类：

| 类别 | 是什么 | 举例 | 怎么处理 |
| --- | --- | --- | --- |
| **业务异常** | 用户的操作不符合业务规则，用户自己能改 | 参数不合法、库存不足、重复提交 | 把具体原因发给用户，提醒他怎么改 |
| **系统异常** | 项目运行时可预见但无法避免的问题，用户改不了 | 数据库宕机、服务器磁盘满、调用第三方超时 | 给用户一句安抚提示；记录日志；通知运维和开发 |
| **其他异常** | 开发时没预料到的异常 | 某处漏判空导致的空指针 | 同系统异常，另外要记下来，作为待修复的 bug |

### 自定义异常

为前两类各写一个异常类，带上状态码：

```java
public class BusinessException extends RuntimeException {

    private final Integer code;

    public BusinessException(Integer code, String message) {
        super(message);
        this.code = code;
    }

    public BusinessException(Integer code, String message, Throwable cause) {
        super(message, cause);
        this.code = code;
    }

    public Integer getCode() {
        return code;
    }
}
```

```java
public class SystemException extends RuntimeException {

    private final Integer code;

    public SystemException(Integer code, String message, Throwable cause) {
        super(message, cause);
        this.code = code;
    }

    public Integer getCode() {
        return code;
    }
}
```

继承 `RuntimeException` 而不是 `Exception`，是为了不用在每一层的方法签名上写 `throws`，异常可以一路自然往上抛。

`SystemException` 的构造方法要求传 `cause`（原始异常）。把底层异常包装成系统异常时，原始异常要留着，日志里才看得到真正的原因，否则排查时只能看到一句「系统繁忙」。

### 在业务代码里抛出

```java
public Book getById(Integer id) {
    // 业务异常：用户传的参数不合规
    if (id == null || id <= 0) {
        throw new BusinessException(Code.BUSINESS_ERR, "请输入正确的图书编号");
    }

    // 系统异常：把底层异常包装成系统异常，保留原始原因
    try {
        return bookDao.getById(id);
    } catch (DataAccessException e) {
        throw new SystemException(Code.SYSTEM_ERR, "数据库访问超时，请稍后再试", e);
    }
}
```

`DataAccessException` 是 Spring 对各种数据访问异常的统一父类，MyBatis 整合进 Spring 之后，数据库层面的异常会被转换成它的子类抛出。

这里的 `try-catch` 和前面反对的那种不一样：前面是**在表现层把异常吞掉、自己拼响应**，这里是**在知道异常含义的地方给它分类，然后继续往上抛**。处理仍然集中在异常处理器里。

### 分类处理

```java
@RestControllerAdvice
public class ProjectExceptionAdvice {

    @ExceptionHandler(BusinessException.class)
    public Result doBusinessException(BusinessException ex) {
        return new Result(ex.getCode(), null, ex.getMessage());
    }

    @ExceptionHandler(SystemException.class)
    public Result doSystemException(SystemException ex) {
        // 记录日志（含 ex.getCause() 的完整堆栈）
        // 通知运维、开发（发消息、发邮件等）
        return new Result(ex.getCode(), null, ex.getMessage());
    }

    @ExceptionHandler(Exception.class)
    public Result doException(Exception ex) {
        // 记录日志、通知开发：这是一个没预料到的 bug
        return new Result(Code.UNKNOWN_ERR, null, "系统繁忙，请稍后再试");
    }
}
```

一个 `BusinessException` 同时匹配 `BusinessException.class` 和 `Exception.class` 两个方法，选哪个？官方文档的规则是：多个方法都匹配时，**按「抛出的异常类型」和「声明的异常类型」在继承树上的距离排序，最近的优先**。`BusinessException` 离自己距离为 0，离 `Exception` 隔了两层，所以走第一个方法。兜底的 `Exception` 方法只会接住前两类以外的异常。

试一下：

```bash
curl http://localhost:8080/ssm/books/0
```

```text
{"code":40000,"data":null,"msg":"请输入正确的图书编号"}
```

### 两个容易忽略的边界

**兜底方法会接住框架自己的异常。** 前端传的 JSON 格式错误、缺少必传参数时，Spring MVC 原本会返回 400，告诉调用方「是你的请求有问题」。但处理 `@ExceptionHandler` 的解析器排在框架默认解析器之前，`@ExceptionHandler(Exception.class)` 会先把这些异常截走，统一变成「系统繁忙」。前端调试时看到的就是「系统繁忙」，而真实原因是自己的请求格式写错了。需要区分的话，就为这类框架异常单独写处理方法，或者在兜底方法里按类型判断。

**过滤器里抛的异常不归它管。** `@ExceptionHandler` 只处理 `DispatcherServlet` 内部、请求处理过程中抛出的异常。[[Servlet 过滤器]] 在 `DispatcherServlet` 外面执行，它抛的异常走的是 Tomcat 的错误处理。[[Spring MVC 拦截器]] 在 `DispatcherServlet` 内部，它抛的异常能被处理到。

## 在 Spring Boot 里

上面的五个配置类、依赖版本对齐、Tomcat 部署，在 [[Spring Boot]] 里基本都由自动配置完成：数据源和 MyBatis 写在配置文件里，`@MapperScan` 和 Controller 照写，`Result`、自定义异常、`@RestControllerAdvice` 这一套原样保留，本篇后半部分在 Boot 里无需改动。

## 参考

- [Spring MVC：Context Hierarchy](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-servlet/context-hierarchy.html)
- [Spring MVC：Default Servlet](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-config/default-servlet-handler.html)、[Static Resources](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-config/static-resources.html)
- [Spring MVC：Exceptions（@ExceptionHandler）](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-exceptionhandler.html)
- [Spring MVC：Controller Advice](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-advice.html)
- [Spring TestContext：@SpringJUnitConfig](https://docs.spring.io/spring-framework/reference/testing/annotations/integration-junit-jupiter.html)
- [MyBatis-Spring 官方文档](https://mybatis.org/spring/)
