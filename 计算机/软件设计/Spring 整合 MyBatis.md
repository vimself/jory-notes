---
tags: [类型/实践, 技术/Java, 技术/Spring, 技术/MyBatis, 技术/Maven]
aliases: [mybatis-spring]
created: 2026-09-05
updated: 2026-09-05
---
> 整合的实质是把 [[MyBatis]] 的三样东西交给 Spring 容器托管：`SqlSessionFactory` 变成一个 bean、Mapper 接口变成一批 bean、事务交给 [[Spring 事务管理]]。做完之后，手写的 `MyBatisUtil` 和满屏的 `openSession/commit/close` 会整个消失。

## 典型场景

[[Servlet 整合 MyBatis]] 那一套跑通之后，项目里留下了这些东西：

```java
public class MyBatisUtil {
    private static final SqlSessionFactory FACTORY;
    static { /* 读配置文件、建工厂、吞异常 */ }
    public static SqlSession openSession() { return FACTORY.openSession(); }
}
```

以及每个业务方法开头结尾的那一圈：

```java
try (SqlSession session = MyBatisUtil.openSession()) {
    UserMapper mapper = session.getMapper(UserMapper.class);
    // ... 两行业务 ...
    session.commit();
}
```

三个问题：

- **`MyBatisUtil` 是你自己维护的全局单例。** 它在静态块里读文件、建工厂、吞异常，出了问题栈里只有一句 `ExceptionInInitializerError`
- **每个方法都得自己拿 session、自己 `commit`。** 漏一次就是数据「执行了但查不到」
- **Service 认识 MyBatis。** `import org.apache.ibatis.session.SqlSession` 出现在业务逻辑层里，[[三层架构]] 想要的解耦并没有真正拿到

引入 Spring 之后，这三件事都由容器接管。**这也是 [[Spring IoC 与 DI]] 最直观的一次兑现**——你能亲眼看见一整个工具类被删掉。

## 加一个依赖

除了 Spring 和 MyBatis 各自的依赖，还需要**胶水包** `mybatis-spring`：

```xml
<dependency>
    <groupId>org.mybatis</groupId>
    <artifactId>mybatis-spring</artifactId>
    <version><!-- 查一下当前版本 --></version>
</dependency>
```

它由 MyBatis 团队维护（注意 groupId 是 `org.mybatis` 而不是 `org.springframework`），里面装着下面要用到的 `SqlSessionFactoryBean`、`MapperScannerConfigurer` 这些类。

版本选择上要留意它和 MyBatis、Spring 三方的兼容矩阵，具体对应关系去官网查——这种表格写进笔记就会过期。[[Maven]] 的依赖传递会帮你把 MyBatis 本体拖进来，但显式声明版本更可控。

## 整合前后对照

| | 整合前 | 整合后 |
| --- | --- | --- |
| `SqlSessionFactory` | 手写 `MyBatisUtil` 静态块 | 一个 `SqlSessionFactoryBean` |
| 拿 Mapper | `session.getMapper(X.class)` | `@Autowired` 直接注入 |
| 开关会话 | 每个方法 `openSession()` / `close()` | 容器管，代码里看不见 |
| 提交回滚 | 每个方法 `commit()` / `rollback()` | `@Transactional` |
| 数据源配置 | `mybatis-config.xml` 的 `<environments>` | Spring 的 `DataSource` bean |

## 第一步：把 SqlSessionFactory 变成 bean

`SqlSessionFactory` 在第三方 jar 里，你没法给它打 `@Component`，所以走 `@Bean` 那条路（这条分界见 [[Spring IoC 与 DI]]）。

```xml
<bean id="sqlSessionFactory" class="org.mybatis.spring.SqlSessionFactoryBean">
    <property name="dataSource" ref="dataSource" />
</bean>
```

Java 配置：

```java
@Configuration
public class MyBatisConfig {
    @Bean
    public SqlSessionFactory sqlSessionFactory() throws Exception {
        SqlSessionFactoryBean factoryBean = new SqlSessionFactoryBean();
        factoryBean.setDataSource(dataSource());
        return factoryBean.getObject();
    }
}
```

### 它是个 FactoryBean，这点值得停一下

类名叫 `SqlSessionFactoryBean`，但**容器里最终存在的 bean 不是它自己**。

它实现了 Spring 的 `FactoryBean` 接口，官方说得很明确：Spring 创建的 bean 不是 `SqlSessionFactoryBean` 本身，而是**调用它的 `getObject()` 得到的返回值**——在这里就是一个 `SqlSessionFactory`。

`FactoryBean` 是 Spring 的一个通用机制：**当一个对象的构造过程很复杂、不是一句 `new` 能搞定时，就写一个工厂 bean 来负责造它。** 你往容器里注册工厂，容器给别人的是产品。上面 Java 配置里那句 `factoryBean.getObject()` 就是手动调了这个过程。

### 常用属性

| 属性 | 必需 | 作用 |
| --- | --- | --- |
| `dataSource` | 是 | 数据源，和普通 Spring 数据库连接一样配 |
| `mapperLocations` | 否 | Mapper XML 文件的位置，支持 Ant 风格通配 |
| `configLocation` | 否 | 指向 `mybatis-config.xml`，用于保留 `<settings>`、`<typeAliases>` 这些配置 |
| `configuration` | 否 | 直接给一个 `Configuration` 实例，不用 XML 配置文件 |

`mapperLocations` 的写法：

```xml
<property name="mapperLocations" value="classpath*:sample/config/mappers/**/*.xml" />
```

不用 XML 配置文件、直接给 `Configuration` 实例的写法：

```java
org.apache.ibatis.session.Configuration configuration = new org.apache.ibatis.session.Configuration();
configuration.setMapUnderscoreToCamelCase(true);
factoryBean.setConfiguration(configuration);
```

### mybatis-config.xml 里的数据源和事务配置会被忽略

这是整合时最容易困惑的一点：**`mybatis-config.xml` 还留着吗？**

答案是：可以留，但里面**只有 `<settings>`、`<typeAliases>` 这类纯配置还有效**。官方对 `configLocation` 的说明很直接——**任何 environments、数据源和 MyBatis 事务管理器都会被忽略。**

所以 [[MyBatis]] 那篇里的这一段：

```xml
<environments default="development">
  <environment id="development">
    <transactionManager type="JDBC"/>
    <dataSource type="POOLED"> ... </dataSource>
  </environment>
</environments>
```

整合之后**整块可以删掉**。数据源由 Spring 的 `DataSource` bean 提供，事务由 Spring 的事务管理器接管——它们本来就是在抢同一份工作，Spring 赢。

## 第二步：让 Mapper 接口变成 bean

`getMapper()` 要消失，Mapper 接口就得能被 `@Autowired` 注入。有三种做法，从笨到聪明：

### 一个一个注册（不推荐，但能说明原理）

```xml
<bean id="userMapper" class="org.mybatis.spring.mapper.MapperFactoryBean">
    <property name="mapperInterface" value="org.mybatis.spring.sample.mapper.UserMapper" />
    <property name="sqlSessionFactory" ref="sqlSessionFactory" />
</bean>
```

Java 配置：

```java
@Bean
public MapperFactoryBean<UserMapper> userMapper() throws Exception {
    MapperFactoryBean<UserMapper> factoryBean = new MapperFactoryBean<>(UserMapper.class);
    factoryBean.setSqlSessionFactory(sqlSessionFactory());
    return factoryBean;
}
```

`MapperFactoryBean` 同样是个 `FactoryBean`——注册进去的是工厂，容器给你的是那个由 MyBatis 动态代理生成的 Mapper 实现。属性有 `mapperInterface`、`sqlSessionFactory`、`sqlSessionTemplate`。

**接口有 20 个就得写 20 遍**，所以实际项目不这么干。理解它的价值在于：知道后面两种做法自动干的是这件事。

### 批量扫描（XML 配置）

```xml
<bean class="org.mybatis.spring.mapper.MapperScannerConfigurer">
    <property name="basePackage" value="org.mybatis.spring.sample.mapper" />
</bean>
```

`basePackage` 指定要扫的包（多个包用逗号或分号隔开），包里的每个接口都会被自动注册成 bean。另有 `sqlSessionFactoryBeanName` 和 `sqlSessionTemplateBeanName` 两个属性，用于多数据源时指明用哪个工厂。

**注意这两个属性名的后缀是 `BeanName`，值是 bean 的名字字符串**，不是 `ref` 引用——照着 `sqlSessionFactory` 那样写会配不上。

### 批量扫描（注解，推荐）

```java
@Configuration
@MapperScan("org.mybatis.spring.sample.mapper")
public class AppConfig {
    // ...
}
```

`@MapperScan` 在 `org.mybatis.spring.annotation` 包下，是上面那个的注解版。可用属性：

| 属性 | 作用 |
| --- | --- |
| `value` / `basePackages` | 要扫描的包 |
| `basePackageClasses` | 给几个类，扫它们所在的包（重构改包名时不会失效） |
| `annotationClass` | 只注册带某个注解的接口 |
| `markerInterface` | 只注册继承了某个接口的接口 |
| `sqlSessionFactory` / `sqlSessionTemplate` | 多数据源时指定用哪个 |

`basePackageClasses` 比字符串包名更健壮——包名写成字符串，IDE 重构时不会跟着改，等到运行时才发现扫了个空。

扫完之后，Service 就可以这么写了：

```java
@Service
public class UserServiceImpl implements UserService {

    private final UserMapper userMapper;          // 直接注入接口

    public UserServiceImpl(UserMapper userMapper) {
        this.userMapper = userMapper;
    }

    public List<User> findAll() {
        return userMapper.selectAll();            // 没有 session，没有 getMapper
    }
}
```

**`import org.apache.ibatis.*` 从 Service 里彻底消失了。** 这才是解耦真正落地的样子。

## 第三步：事务交给 Spring

```java
@Bean
public PlatformTransactionManager txManager(DataSource dataSource) {
    return new DataSourceTransactionManager(dataSource);
}
```

**有一条硬性要求：给事务管理器的 `DataSource`，必须和创建 `SqlSessionFactoryBean` 时用的是同一个。**

道理很实在——事务是绑在连接上的。两个不同的 `DataSource` 就是两个连接池，Spring 在 A 池的连接上开了事务，MyBatis 却从 B 池拿连接去执行 SQL，那条 SQL 就跑在事务外面。**表现是「`@Transactional` 完全不起作用，但也不报任何错」**，排查起来很折磨。用 `@Bean` 方法参数注入同一个 `DataSource` bean，天然就避开了这个问题。

之后的用法见 [[Spring 事务管理]]，Service 上打 `@Transactional` 即可。

### 手动 commit 会抛异常

整合之后有一条铁律：**不要再对 Spring 托管的 `SqlSession` 调 `commit()`、`rollback()` 或 `close()`。**

官方的说法是，对一个 Spring 托管的 `SqlSession` 调这三个方法会**抛出 `UnsupportedOperationException`**。

这个设计是好事：它不是静默忽略，而是当场炸给你看，所以从旧代码迁移过来时漏删的 `session.commit()` 会在第一次运行就暴露，不会留成隐患。

### 没有事务时会自动提交

还有一条容易踩的规则：**在 Spring 事务之外执行 `SqlSession` 的数据方法或调用 mapper 方法，会被自动提交。**

也就是说，Service 方法上**忘了打 `@Transactional`**，里面两条 `update` 不会一起失败——它们各自提交，中间挂了就留下半条数据。这和「忘了 `commit()` 导致数据没写进去」正好相反：**这次是写进去了一半，而且没有任何报错。**

所以整合完成后，检查清单上必须有这一条：**凡是有两步以上写操作的 Service 方法，都要有 `@Transactional`。**

## 参考

- [MyBatis-Spring 官方文档](https://mybatis.org/spring/)
- [SqlSessionFactoryBean](https://mybatis.org/spring/factorybean.html)
- [注入映射器（Mapper）](https://mybatis.org/spring/mappers.html)
- [事务](https://mybatis.org/spring/transactions.html)
