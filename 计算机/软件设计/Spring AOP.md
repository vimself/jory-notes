---
tags: [类型/概念, 技术/Java, 技术/Spring]
aliases: [AOP, 面向切面编程]
created: 2026-09-05
updated: 2026-09-05
---
> AOP 把「每个方法都要写一遍」的通用逻辑（日志、计时、权限、事务）抽出来单独放一处，再声明一个匹配规则说明它该插在哪些方法上。Spring 的实现方式是给 bean 套一层代理，所以它的能力边界和局限都由「代理」这两个字决定。

## 典型场景

产品说系统有点慢，让你查一下是哪个环节。你决定先给业务逻辑层的每个方法打上耗时日志：

```java
public void register(User user) {
    long begin = System.currentTimeMillis();      // ← 加的
    if (userMapper.findByName(user.getName()) != null) {
        throw new IllegalStateException("用户名已存在");
    }
    userMapper.insert(user);
    System.out.println("register 耗时 " +
        (System.currentTimeMillis() - begin) + "ms");   // ← 加的
}
```

一个方法两行，不算什么。问题是 Service 里有 40 个方法。

于是你复制粘贴了 40 遍，然后发现：

- **业务代码被淹了。** `register` 的正事只有 4 行，计时代码占了一半，读的人得先把噪音过滤掉
- **抛异常的方法统计不到。** 中间 `throw` 了，最后那行就跑不到——想修就得每个方法再包一层 `try/finally`，80 行变 160 行
- **改口径要改 40 处。** 老板说想输出到日志文件而不是控制台，你得再来一轮
- **上线前想关掉它**，还得再来一轮

这些代码的共同点是：**它和业务无关，但它横着穿过了所有业务方法。** 这种逻辑叫**横切关注点**（cross-cutting concern），AOP 就是专门收拾它的。

## 五个术语，先说清楚

这套词汇是从 AspectJ 借来的，第一次看容易糊，但都很朴素：

| 术语 | 英文 | 是什么 | 上面场景里对应 |
| --- | --- | --- | --- |
| **连接点** | join point | 程序里「可以被插入」的位置 | 每一个 Service 方法的执行 |
| **切入点** | pointcut | 一个匹配规则，从所有连接点里挑出你要的 | 「Service 包下所有方法」 |
| **通知** | advice | 真正要插进去的那段代码 | 计时那几行 |
| **切面** | aspect | 切入点 + 通知打包在一起 | 「计时切面」这个类 |
| **织入** | weaving | 把通知装到目标上的动作 | Spring 启动时生成代理 |

一句话串起来：**切面 = 在哪些地方（切入点）+ 干什么（通知），织入 = 把这件事真的落实。**

## 手把手：给 Service 加一圈耗时统计

### 第一步：打开 AOP 支持

在配置类上加一个注解：

```java
@Configuration
@ComponentScan("com.example")
@EnableAspectJAutoProxy
public class AppConfig {
}
```

`@EnableAspectJAutoProxy` 的意思是「启动时扫一遍所有 bean，凡是被某个切面匹配上的，自动替换成代理对象」。

### 第二步：写切面

```java
@Aspect
@Component
public class TimingAspect {

    @Pointcut("execution(* com.example.service.*.*(..))")
    public void serviceMethods() {}

    @Around("serviceMethods()")
    public Object timing(ProceedingJoinPoint pjp) throws Throwable {
        long begin = System.currentTimeMillis();
        try {
            return pjp.proceed();                       // ← 放行，执行原方法
        } finally {
            System.out.println(pjp.getSignature() + " 耗时 " +
                (System.currentTimeMillis() - begin) + "ms");
        }
    }
}
```

三处细节：

- **`@Aspect` 和 `@Component` 都要有。** `@Aspect` 说明「这是个切面」，`@Component` 让它先成为一个 bean——不进容器，切面就不会被发现
- **`@Pointcut` 挂在一个空方法上。** 这个方法体永远不会被执行，它纯粹是给切入点表达式起个名字，之后用 `serviceMethods()` 引用。表达式复用、改口径只改一处，靠的就是它
- **`finally` 里做统计**，异常路径也能测到——这正是手写版做不到、AOP 几乎白送的那件事

`@Aspect`、`@Pointcut`、`@Around` 这些注解来自 `org.aspectj.lang.annotation` 包。**Spring 只是借用了 AspectJ 的注解和表达式语法**，织入机制是它自己的（见下面「底层是动态代理」）。

### 第三步：什么都不用改

Service 一行不动，40 个方法一起有了耗时统计。想关掉就把 `@Component` 注掉，想换成写日志文件就改切面里那一行。开头列的四个问题一次解决。

## 切入点表达式

`execution` 是最主要的匹配器，完整语法是：

```
execution(modifiers-pattern?
          ret-type-pattern
          declaring-type-pattern?
          name-pattern(param-pattern)
          throws-pattern?)
```

带 `?` 的可省略，也就是说**返回值类型、方法名、参数列表这三样是必填的**，访问修饰符、声明类型、异常声明可以不写。

### 两个通配符

- **`*`** 匹配**一个**组成部分：任意返回值、任意方法名、包路径里的一段
- **`..`** 匹配**零个或多个**：包路径里的任意层级，或者参数列表里的任意个参数

参数列表这几种写法要分清：

| 写法 | 匹配 |
| --- | --- |
| `()` | 无参方法 |
| `(..)` | 任意个参数（含零个） |
| `(*)` | 恰好一个参数，类型不限 |
| `(*,String)` | 两个参数，第一个任意类型，第二个必须是 `String` |

### 官方给的例子

```
execution(public * *(..))                        任意 public 方法
execution(* set*(..))                            方法名以 set 开头
execution(* com.xyz.service.AccountService.*(..))  AccountService 里定义的任意方法
execution(* com.xyz.service.*.*(..))             service 包下任意类的任意方法
execution(* com.xyz.service..*.*(..))            service 包及其子包下的任意方法
```

留意最后两行的区别：**`service.*` 只有这一层，`service..*` 连子包一起。** 分层项目里 Service 常常还有子包，写少一个点就会漏掉一半。

### 其他匹配器

`execution` 之外还有一批，各有各的用处：

| 匹配器 | 挑的是 |
| --- | --- |
| `within` | 在某些类型内部的连接点，例：`within(com.xyz.service..*)` |
| `this` | 代理对象是某个类型的实例 |
| `target` | 目标对象是某个类型的实例 |
| `args` | 运行时实参是某些类型，例：`args(java.io.Serializable)` |
| `@annotation` | **方法上有某个注解**，例：`@annotation(org.springframework.transaction.annotation.Transactional)` |
| `@within` / `@target` | 类上有某个注解 |
| `@args` | 实参的运行时类型上有某个注解 |
| `bean` | 按 bean 名字匹配，例：`bean(*Service)` —— 这个是 Spring 特有的 |

**`@annotation` 是实践中最好用的一个。** 与其靠包名和方法名去猜「哪些方法要加缓存」，不如自定义一个 `@Cached` 注解，让开发者显式标注，切入点写 `@annotation(com.example.Cached)`。这样一来匹配规则不再依赖代码摆放位置，重构挪包也不会失效。

## 五种通知类型

| 注解 | 什么时候跑 |
| --- | --- |
| `@Before` | 目标方法执行前 |
| `@AfterReturning` | 目标方法**正常返回**后 |
| `@AfterThrowing` | 目标方法**抛出异常**退出时 |
| `@After` | 目标方法退出时，**正常和异常都跑** |
| `@Around` | 包住整个执行过程，前后都能插手 |

`@After` 官方的定义是「after finally advice」——类比 `try-catch` 里的 `finally` 块，任何结局都会执行。所以**释放锁、关资源这类必须做的事放 `@After`**，而不是 `@AfterReturning`。

### 拿到返回值和异常

`@AfterReturning` 用 `returning` 属性绑定返回值，属性值必须和通知方法的参数名对上：

```java
@AfterReturning(
    pointcut = "execution(* com.xyz.dao.*.*(..))",
    returning = "retVal")
public void doAccessCheck(Object retVal) {
    // ...
}
```

`@AfterThrowing` 同理，用 `throwing`：

```java
@AfterThrowing(
    pointcut = "execution(* com.xyz.dao.*.*(..))",
    throwing = "ex")
public void doRecoveryActions(DataAccessException ex) {
    // ...
}
```

**参数类型还兼作过滤条件**：上面声明的是 `DataAccessException`，那么抛别的异常时这个通知不会被触发。

### @Around 的三条硬性要求

```java
@Around("execution(* com.xyz..service.*.*(..))")
public Object doBasicProfiling(ProceedingJoinPoint pjp) throws Throwable {
    // 开始计时
    Object retVal = pjp.proceed();
    // 停止计时
    return retVal;
}
```

1. 返回类型声明为 `Object`
2. **第一个参数必须是 `ProceedingJoinPoint`**
3. 方法体里**必须调用 `proceed()`**，否则目标方法根本不会执行

第 3 条是最容易翻车的地方：`@Around` 里忘了 `proceed()`，被它匹配到的所有方法会静悄悄地变成空方法，返回 `null`，不报任何错。查这种 bug 会查很久，因为业务代码本身没有任何问题。

反过来说，「能决定要不要放行」正是 `@Around` 独有的能力——权限校验不通过就直接不调 `proceed()`，缓存命中就直接返回缓存值。**五种通知里只有它能做到这件事，另外四种只能旁观。**

## 多个通知的执行顺序

**同一个切面类里**，命中同一个连接点的多个通知按类型定优先级，从高到低是：

```
@Around → @Before → @After → @AfterReturning → @AfterThrowing
```

**不同切面之间**，官方说得很直白：除非你显式指定，否则**执行顺序是未定义的**。要控制顺序，让切面类实现 `org.springframework.core.Ordered` 接口，或者打上 `@Order` 注解。

所以只要你有两个以上切面可能落在同一批方法上（比如「日志」和「事务」），就**明确写上 `@Order`**，别赌默认顺序——它在不同环境下可能不一样。

## 底层是动态代理

理解到这一层，你才能预判 AOP 什么时候会失效。

**Spring AOP 靠代理实现。** 容器发现某个 bean 被切面匹配上了，就不把原对象放进容器，而是生成一个**代理对象**顶替它。代理对象和原对象长得一样（同接口或同类型），但每个方法内部都被包了一层：先跑通知，再转调原对象。

### JDK 动态代理 vs CGLIB

Spring 有两套生成代理的手段，规则很简单：

| | 什么时候用 | 怎么实现的 |
| --- | --- | --- |
| **JDK 动态代理** | 目标对象**实现了至少一个接口**（默认选它） | 运行时生成一个实现了这些接口的类 |
| **CGLIB** | 目标对象**没实现任何接口** | 运行时生成目标类的**子类** |

JDK 动态代理会代理目标实现的所有接口。想强制一律用 CGLIB：

```java
@EnableAspectJAutoProxy(proxyTargetClass = true)
@EnableTransactionManagement(proxyTargetClass = true)
```

XML 配置里对应的是 `proxy-target-class="true"`：

```xml
<aop:aspectj-autoproxy proxy-target-class="true"/>
```

### CGLIB 靠继承，所以有这些限制

既然是「生成子类、重写方法」，凡是不能被继承和重写的东西就增强不了：

- **`final` 类没法代理**，因为不能被继承
- **`final` 方法没法增强**，因为不能被重写
- **`private` 方法没法增强**，同上
- **父类里的包级私有方法**，如果父类在另一个包，也没法增强——那种情况下它实际等同于私有

所以某个方法「AOP 就是不生效」时，先看它是不是 `final` 或 `private`。

## 自调用为什么会失效

这是 AOP 头号疑难杂症，也是 [[Spring 事务管理]] 那篇里 `@Transactional` 失效的同一个根因。

现象是这样的：

```java
@Service
public class OrderService {

    public void createOrder(Order o) {
        // ...
        this.audit(o);        // ← 内部调用
    }

    // 假设切面匹配到了这个方法
    public void audit(Order o) { ... }    // 通知不会跑
}
```

原因在于**容器交给外部的是代理对象，而目标对象内部的 `this` 是它自己**。

官方原话是：调用方拿到的是代理的引用，但一旦调用抵达目标对象，目标对象内部再发起的方法调用（比如 `this.bar()`）是打在 `this` 引用上的，**而不是代理上**。既然没走代理，那一层包装的通知自然被绕过去了。

画出来是这样：

```
外部调用 ──→ [代理对象] ──→ [目标对象.createOrder()]
              ↑ 通知在这             │
              │                      └─→ this.audit()   通知被绕过
              └──── 没有再经过这里 ←───┘
```

三种解法，推荐程度从高到低：

**一、重构，消除自调用。** 把 `audit` 挪到另一个 bean 里，通过依赖注入调过去，这样就是一次正常的外部调用。这也是官方推荐的做法，而且往往顺带改善了职责划分。

**二、注入自己。** 让 bean 持有一个指向自身代理的引用，用它来调。

**三、`AopContext.currentProxy()`。** 官方标注为「强烈不推荐」：

```java
public class SimplePojo implements Pojo {
    public void foo() {
        // 能用，但应尽量避免
        ((Pojo) AopContext.currentProxy()).bar();
    }

    public void bar() { ... }
}
```

它需要先开启 `exposeProxy`，而且官方的评价是它「把你的代码彻底绑死在 Spring AOP 上」，削弱了 AOP 本身的价值——业务类又认识框架了，回到了 Spring 当初想解决的问题上。

顺带一提：AspectJ 的编译期织入和加载期织入**没有这个问题**，因为它们直接改字节码、压根不生成代理。代价是要引入额外的编译或启动配置。

## 参考

- [Aspect Oriented Programming with Spring](https://docs.spring.io/spring-framework/reference/core/aop.html)
- [Declaring a Pointcut](https://docs.spring.io/spring-framework/reference/core/aop/ataspectj/pointcuts.html)
- [Declaring Advice](https://docs.spring.io/spring-framework/reference/core/aop/ataspectj/advice.html)
- [Proxying Mechanisms](https://docs.spring.io/spring-framework/reference/core/aop/proxying.html)
