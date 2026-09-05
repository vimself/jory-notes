---
tags: [类型/概念, 技术/Java, 技术/Spring]
aliases: [控制反转, 依赖注入, IoC, DI]
created: 2026-09-05
updated: 2026-09-05
---
> 控制反转（IoC）是把「谁来创建对象」这个权力从你的代码里交出去；依赖注入（DI）是这个权力交出去之后，容器把对象送回给你的方式。落到代码上就一句话：把 `new` 删掉，改成声明「我需要一个这个类型的东西」。

## 典型场景

[[三层架构]] 那篇里的 `UserServiceImpl`，现在长这样：

```java
public class UserServiceImpl implements UserService {
    private UserMapper userMapper = new UserMapperImpl();   // ← 就是这一行

    public void register(User user) {
        if (userMapper.findByName(user.getName()) != null) {
            throw new IllegalStateException("用户名已存在");
        }
        userMapper.insert(user);
    }
}
```

分层是分了，但 Service 和 Dao 之间用 `new` 焊死了。三件事随之而来：

- 想给数据访问层换一个实现（比如从 MyBatis 换成 JDBC 手写），得**改 Service 的源码再重新编译**。这层「面向接口编程」白做了——接口在，可 `new` 的是实现类
- 想给 `register` 写单元测试、用一个假的 mapper 顶上，做不到。测试跑起来就真的去连数据库了
- `UserServiceImpl` 现在既要干业务，又要负责「造出它的协作对象」。类越多，这种造对象的代码在项目里散得越开

**这三件事的病根是同一个：对象的创建权在使用它的类手里。**

## 控制反转到底反转了什么

反转的是**创建和查找依赖对象的控制权**。

原来的流程：`UserServiceImpl` 需要 mapper → 它自己 `new` 一个 → 它掌握主动权。
反转之后：`UserServiceImpl` 需要 mapper → 它只是声明这件事 → 外部有个东西把 mapper 塞给它 → 主动权在外部。

那个「外部的东西」就是 **IoC 容器**。它在程序启动时把所有对象一次性造好、按依赖关系接上线，然后放在手里管着。这些被它管理的对象，Spring 里统称 **bean**。

`Spring bean` 和 `Java 对象` 的区别只在于**谁造的、谁管的**——bean 就是普通 Java 对象，只不过它的生命周期归容器管。

**依赖注入（DI）是控制反转的具体实现手法。** 两个词经常混着用，严格说：IoC 是「思想」（权力交出去），DI 是「做法」（通过构造器/setter 把依赖送进来）。日常交流里不用抠这个区别。

## 从 new 到容器：手把手走查

我们把上面那段代码改造一遍，每一步都看得见。

### 第一步：告诉容器有哪些类要管

在类上打一个**构造型注解**（stereotype annotation），容器扫描时就会把它收编成 bean：

```java
@Service                                 // 业务逻辑层
public class UserServiceImpl implements UserService { ... }

@Repository                              // 数据访问层
public class UserMapperImpl implements UserMapper { ... }
```

一共四个，语义上是一个通用的加三个特化的：

| 注解 | 用在 | 说明 |
| --- | --- | --- |
| `@Component` | 任何地方 | 通用标记，剩下三个都是它的特化 |
| `@Service` | 业务逻辑层 | 语义标记 |
| `@Repository` | 数据访问层（DAO） | 除语义外还会启用数据访问异常的自动转换 |
| `@Controller` | 表现层 | 语义标记 |

**功能上四个几乎等价**，选哪个主要是给人看的：一眼扫过去就知道这个类站在 [[三层架构]] 的哪一层。`@Repository` 是唯一有额外行为的那个。

被扫描到的类会拿到一个 bean 名字。**默认规则是「首字母小写的类名（不含包名）」**——`UserMapperImpl` 变成 `userMapperImpl`。想自己指定就写进注解的值里：`@Service("myUserService")`。

### 第二步：告诉容器去哪里扫

```java
@Configuration
@ComponentScan(basePackages = "com.example")
public class AppConfig {
}
```

`@ComponentScan` 指定扫描的起点包，Spring 会递归往下找所有带构造型注解的类。`basePackages` 支持 Ant 风格的通配，例如 `"com.example.**"`。

### 第三步：把 new 换成注入

```java
@Service
public class UserServiceImpl implements UserService {

    private final UserMapper userMapper;                    // final 了

    public UserServiceImpl(UserMapper userMapper) {         // 构造器接收
        this.userMapper = userMapper;
    }

    public void register(User user) { ... }
}
```

注意这里**没有任何 Spring 注解**。当一个类只有一个构造器时，`@Autowired` 可以省略——官方原话是，如果目标 bean 只定义了一个构造器，就不需要标注；只有在有多个构造器、且没有主构造器或默认构造器时，才必须用 `@Autowired` 指明用哪个。

这就是 Spring 想要的样子：**业务类回到了普通 Java 类**，不实现框架接口、不继承框架基类，脱离 Spring 也能 `new UserServiceImpl(mockMapper)` 直接测。

### 第四步：启动容器

```java
public static void main(String[] args) {
    ApplicationContext ctx = new AnnotationConfigApplicationContext(AppConfig.class);
    UserService userService = ctx.getBean(UserService.class);
    userService.register(new User("张三"));
}
```

`ApplicationContext` 就是容器的接口，`AnnotationConfigApplicationContext` 是它基于注解配置的实现。

`getBean()` 在这里出现是因为**总得有人打第一枪**——总要有一个入口从容器外面把第一个对象捞出来。除了这个入口，**业务代码里不该再出现 `getBean()`**：一旦你在 Service 里调 `getBean()`，控制权又拿回自己手上了，等于绕过了整个机制。

## 三种注入方式，和该用哪种

### 构造器注入（推荐）

```java
private final UserMapper userMapper;

public UserServiceImpl(UserMapper userMapper) {
    this.userMapper = userMapper;
}
```

官方明确推荐这一种，理由是它让组件成为不可变对象、保证必需依赖不为 `null`，并且**对象交到调用方手上时一定是完全初始化好的状态**。

`final` 是关键收益：编译器逼着你在构造器里赋值，依赖漏了当场就编译不过，而不是等到运行时抛空指针。

### setter 注入

```java
private UserMapper userMapper;

@Autowired
public void setUserMapper(UserMapper userMapper) {
    this.userMapper = userMapper;
}
```

官方给的分工是：**构造器管必需依赖，setter 或其他配置方法管可选依赖。**

### 字段注入

```java
@Autowired
private UserMapper userMapper;
```

最短，也最常见于教程，但它有两个实打实的代价：**字段不能是 `final`**；**脱离 Spring 就没法给它赋值**——写单元测试时你既不能 `new` 出来传参，也没有 setter，只能上反射或者把测试也跑在 Spring 容器里。

一句话：**新代码写构造器注入**，字段注入认识就行。

### 依赖找不到时的三种松绑方式

默认情况下，注入点找不到匹配的 bean，**启动直接失败**。这是好事——问题暴露在启动阶段，而不是半夜某个请求打进来时。

确实是可选依赖的话，有三种写法：

```java
@Autowired(required = false)                    // 找不到就不注入
public void setMovieFinder(MovieFinder finder) { ... }

@Autowired
public void setMovieFinder(Optional<MovieFinder> finder) { ... }   // 包一层 Optional

@Autowired
public void setMovieFinder(@Nullable MovieFinder finder) { ... }   // 允许为 null
```

## 一个接口有多个实现时

这是最常撞上的一堵墙。`UserMapper` 有 `MyBatisUserMapper` 和 `JdbcUserMapper` 两个实现，两个都被扫成了 bean，容器按类型找的时候发现有两个候选，**启动时直接报错**，告诉你这个注入点无法决定用哪一个。

三种解法，按优先级从高到低：

**一、`@Primary` —— 指定默认人选。** 打在其中一个实现类上，没有其他指示时就用它。适合「有一个明显的主力实现，另一个是备用」的情况。

**二、`@Qualifier` —— 在注入点点名。**

```java
@Autowired
@Qualifier("main")
private MovieCatalog movieCatalog;
```

也可以打在参数上：

```java
@Autowired
public void prepare(@Qualifier("main") MovieCatalog movieCatalog,
        CustomerPreferenceDao customerPreferenceDao) { ... }
```

**三、按名字兜底。** 如果既没有 qualifier 也没有 primary 标记，Spring 会拿**注入点的名字**（字段名或参数名）去和候选 bean 的名字比，同名的那个胜出。

这条兜底规则很方便，但有个陷阱：**从 Spring 6.1 起，靠参数名匹配要求编译时带上 `-parameters` 编译器标志**，否则参数名在字节码里被擦成 `arg0`、`arg1`，匹配自然失败。字段名不受影响。所以别把「按名字匹配」当成可靠机制来设计，它是兜底，不是主力。

## 按类型批量注入

需要「所有实现」而不是「某一个实现」时，直接声明成数组、集合或 Map：

```java
@Autowired
private MovieCatalog[] movieCatalogs;         // 全部塞进数组

@Autowired
public void setMovieCatalogs(Set<MovieCatalog> movieCatalogs) { ... }

@Autowired
public void setMovieCatalogs(Map<String, MovieCatalog> movieCatalogs) { ... }
```

`Map` 那个尤其好用：**key 是 bean 名字，value 是 bean 实例**，等于白拿一张注册表。策略模式落地时经常这么写。

## 第三方类怎么进容器

`@Component` 要打在类上，可 `DataSource`、`SqlSessionFactory` 这些类在别人的 jar 包里，你改不了它们的源码。

解法是 `@Bean`：**在配置类里写一个方法，方法的返回值就是 bean，方法名就是 bean 名字。**

```java
@Configuration
public class DataSourceConfig {

    @Bean
    public DataSource dataSource() {
        DruidDataSource ds = new DruidDataSource();
        ds.setUrl("jdbc:mysql://localhost:3306/demo");
        // ...
        return ds;
    }
}
```

`@Bean` 方法之间也能互相依赖，直接声明成方法参数即可，容器会把对应的 bean 传进来：

```java
@Configuration
public class ServiceConfig {

    @Bean
    public TransferService transferService(AccountRepository accountRepository) {
        return new TransferServiceImpl(accountRepository);
    }
}
```

配置类多了可以用 `@Import` 组装：

```java
@Configuration
@Import({ServiceConfig.class, RepositoryConfig.class})
public class SystemTestConfig {
    @Bean
    public DataSource dataSource() { ... }
}
```

**`@Component` 管自己写的类，`@Bean` 管别人写的类**——这条分界记住就够了。[[Spring 整合 MyBatis]] 全靠 `@Bean`，因为要装的三个东西全在第三方 jar 里。

## 作用域：这个 bean 有几份

默认情况下**容器里每个 bean 定义只对应一个实例**，所有注入点拿到的是同一个对象。这就是 `singleton` 作用域，也是默认值。

内置作用域一共六个：

| 作用域 | 字符串名 | 一个实例活多久 |
| --- | --- | --- |
| **单例**（默认） | `singleton` | 每个容器一个实例，全程共用 |
| **原型** | `prototype` | 每次取用都造一个新的 |
| 请求 | `request` | 一次 HTTP 请求 |
| 会话 | `session` | 一次 HTTP Session，见 [[会话跟踪]] |
| 应用 | `application` | 一个 `ServletContext` |
| WebSocket | `websocket` | 一个 WebSocket 连接 |

后四个**只在「web 感知」的 `ApplicationContext` 里有效**，普通命令行程序里用不了。Web 场景下有现成的组合注解可用：

```java
@RequestScope
@Component
public class LoginAction { }

@SessionScope
@Component
public class UserPreferences { }
```

**单例是默认值，这件事有个直接后果：bean 里不要放可变的实例状态。** Service 是单例的，所有请求线程共用同一个对象，你往字段里存了「当前用户」，两个并发请求就会互相踩。要存请求相关的数据，要么当方法参数传，要么改用 `request` 作用域。

## 生命周期回调

容器造好 bean、注入完依赖之后，可以让它执行一段初始化逻辑；容器关闭时，可以让它做清理：

```java
public class LifecycleBean {

    @PostConstruct
    public void init() {
        System.out.println("Bean initialized.");
    }

    @PreDestroy
    public void destroy() {
        System.out.println("Bean will be destroyed.");
    }
}
```

这两个注解**不在 Spring 自己的包里**，它们来自 Java 平台的通用注解规范，Spring 只是认得它们。

原型作用域这里有个反直觉的坑：**容器不会执行它的销毁回调。**

官方的说法是，Spring 并不管理原型 bean 的完整生命周期——初始化回调对所有作用域都会调用，但对原型 bean，**配置的销毁回调不会被调用**，客户端代码必须自己清理原型 bean 持有的昂贵资源。

道理不难懂：容器造完原型 bean 就把它交出去了，之后谁还持有它、什么时候不用了，容器一概不知道，自然也没法在合适的时机调 `@PreDestroy`。所以**别把数据库连接、文件句柄这类需要显式关闭的资源放进原型 bean**，那是内存泄漏的写法。

## 常见坑

**一、类没被扫到，启动就报找不到 bean。** 九成是 `@ComponentScan` 的 `basePackages` 没覆盖到那个类所在的包。检查包名拼写，以及类上到底有没有构造型注解。

**二、在 Service 里 `new` 另一个 Service。** `new` 出来的对象不是 bean，它身上的 `@Autowired` 不会被处理，字段全是 `null`；[[Spring 事务管理]] 里的 `@Transactional` 也一样不生效。**凡是要享受容器服务的对象，必须由容器创建。**

**三、把 `getBean()` 撒进业务代码。** 它是启动入口用的，不是给业务逻辑用的。业务代码里出现 `getBean()`，说明这个类没被容器管理，或者依赖关系没理清。

**四、单例 bean 里存请求状态。** 见上面「作用域」一节，这个 bug 在低并发下测不出来，上线才炸。

## 参考

- [The IoC Container](https://docs.spring.io/spring-framework/reference/core/beans.html)
- [Dependency Injection](https://docs.spring.io/spring-framework/reference/core/beans/dependencies/factory-collaborators.html)
- [Bean Scopes](https://docs.spring.io/spring-framework/reference/core/beans/factory-scopes.html)
- [Classpath Scanning and Managed Components](https://docs.spring.io/spring-framework/reference/core/beans/classpath-scanning.html)
